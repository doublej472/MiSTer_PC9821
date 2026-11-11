#!/usr/bin/env python3
"""check_memmap_addr_equiv.py -- prove pc9821_memory_map's spliced `mem_addr` equals the
pre-rewrite 32-bit-adder form for every input the system can present, and (A4/A3)
that its 12-bit slice RAM-bound compares and constant low EMS page half
equal the 32-bit forms.

The rewrite builds each window arm of `mem_addr` as {base[31:20], 20-bit
sum} instead of a 32-bit add. That is exact only under the invariants the system guarantees:

  * pack_base is one of the eight whole-MiB RAM-size constants (1 .. 96 MiB), so its low 20
    bits are zero;
  * ems_page_base / fw_shadow_base / peg_base are pack_base + 1 MiB + 0x48000 / 0x58000 /
    0x80000 (pc9821_memory_subsystem, PACK_BYTES = 1 MiB) -- so ems_page_base's low 20 bits
    are the constant 0x48000 and the EMS page arm is a splice, not an add;
  * guest_ram_bytes is one of the same eight whole-MiB sizes (pc9821_system's size_code_bytes,
    selected by the 3-bit OSD ram_size_sel), so its low 20 bits are zero and each
    `A >= guest_ram_bytes` bound compare is exactly `A[31:20] >= guest_ram_bytes[31:20]`;
  * peg_window is only asserted for an address in 0xF00000-0xF7FFFF (the subsystem decodes
    it on the same post-window-0 address the map calls d_addr);
  * win0_sel_moved == (win0_sel != 8'h08): pc9821_iobus registers the flag with win0_sel
    (tools/check_win0_moved_inv.py proves it in every reachable cycle).

The wrapper therefore drives guest_ram_bytes from the same eight-value table (ram_sel free,
so every reachable size is covered and no unreachable one is), and pack_base from the eight
values; `PREMISES` re-reads the two RTL tables this file mirrors, so a change to either side
fails the proof instead of silently weakening it.

It also proves every other output of the map equal (the window decodes, the ready/response
outputs), which covers the late-muxed region decode (`region_dec`) and the RAM-bound
`addr_ge_ram` compare.

The map's address is pc9821_memory_subsystem's eff_addr, and the current map also takes the
untranslated address with eff_addr's arm (cpu_addr_raw / xl_low20 / xl_peg, P0-d). The wrapper
therefore drives the RAW address and sys16m_en free and forms eff_addr and the two selects
exactly as the subsystem does; every 32-bit eff_addr is reachable that way (an untranslated
address is its own raw form), so the old module still sees every input it ever could. An `--old`
revision that predates P0-d takes `cpu_addr` instead and gets no raw-arm connections.

ONE DELIBERATE CHANGE IS CARVED OUT, and proved on its own terms instead: window 0 at 0x0A
(`win0_sel == 8'h0A`, a moved address) is RAM on the machine, not the VRAM windows
(docs/probes/DMAROUTE-XE10.TXT cases W1/W2; pc9821_memory_map's win0_ram_page). There the new
map must decode no window at all (no plane, packed, register, not-connected, EMS, absent or
shadow arm), issue the backend request whenever the CPU presents one, and name d_addr itself.
Every other input is compared with the old revision as before.

A THIRD CARVE-OUT: window 0 below page 8 (`win0_sel[7:3] == 0`, a moved address) is a hole on
the machine (docs/probes/KIT2-XE10-RISKY-461.TXT:5-17; pc9821_memory_map's win0_hole_page). There
the new map must assert absent_area, issue no backend request and decode no window (no plane,
packed, register, not-connected, EMS or shadow arm).

A SECOND CARVE-OUT: the E plane is an analog-mode window. With `mode2_16color` clear (the
digital mode; docs/probes/DMAROUTE-XE10.TXT case P4 view V1, docs/probes/VRAM2.TXT's E000 row)
and the PEGC view off, 0xE0000-0xE7FFF of the first MiB must decode no plane window and assert
`e_plane_nc`; everywhere else `e_plane_nc` must stay low and every output is compared with the
old revision. `mode2_16color` is free, so the analog mode is proved equal to the old map too.

The proof wraps the OLD module (from `--old REV`, renamed) and the CURRENT file under those
invariants, with every other input free, and asks yosys's SAT engine whether anything can
differ. `--plant` mutates the current text and the run must then FAIL; `--selftest` runs the
clean proof and each plant.

  python3 tools/check_memmap_addr_equiv.py --old ac2538dc     # the area-core splice
  python3 tools/check_memmap_addr_equiv.py --old 89a68d43     # the A4/A3 memmap cut
  python3 tools/check_memmap_addr_equiv.py --selftest
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP = "src/pc9821/core/pc9821_memory_map.sv"
SYSTEM = "src/pc9821/core/pc9821_system.sv"
SUBSYSTEM = "src/pc9821/core/pc9821_memory_subsystem.sv"
DEFAULT_OLD = "ac2538dc"

# The eight OSD RAM sizes, in the order of pc9821_system's size_code_bytes codes 0..7.
SIZES = ["32'h0010_0000", "32'h0020_0000", "32'h0040_0000", "32'h0080_0000",
         "32'h0100_0000", "32'h0200_0000", "32'h0400_0000", "32'h0600_0000"]

PLANTS = {
    # a wrong constant in one arm
    "sound_rom_const": ("20'hC6800", "20'hC6000"),
    # bios_lower offset without the half-block flip
    "bios_flip": ("1'b1, ~d_addr[15]", "1'b1, d_addr[15]"),
    # the PEGC window's bit 19 (peg_base's 0x80000)
    "peg_bit19": ("{peg_hi, peg_base[19], d_addr[18:0]}", "{peg_hi, 1'b0, d_addr[18:0]}"),
    # the late-muxed region decode: the moved arm's sound-ROM window one bit off
    "region_sound": ("first && (a[19:16] == 4'hC) && a[15] && a[14],", "first && (a[19:16] == 4'hC) && a[15],"),
    # C7-head: the registered window-0 flag read inverted
    "win0_flag": ("win0_moved = win0_in_window && win0_sel_moved;", "win0_moved = win0_in_window && !win0_sel_moved;"),
    # the late-muxed region decode: the arms swapped
    "region_swap": ("win0_moved ? dv_mv :", "win0_moved ? dv_raw :"),
    # P0-d: the low-20 translation arm decoded on the untranslated address
    "xl_low20_arm": ("xl_low20 ? dv_l20 :", "xl_low20 ? dv_raw :"),
    # P0-d: the PEGC alias arm's RAM-bound compare on the untranslated address
    "xl_peg_ge": ("xl_peg ? ge_peg : ge_raw;", "xl_peg ? ge_raw : ge_raw;"),
    # A4/A3 harness self-check, CONTRIVED ON PURPOSE: out_of_range masks `addr_ge_ram` wherever
    # peg_window is set, so this is the one plant that changes ONLY the addr_ge_ram output. It
    # exists to prove the wrapper compares that output at all (the subsystem consumes it in its
    # open_select, where fw_high/peg_window masking does not apply).
    "ge_ge_ram_output": ("assign addr_ge_ram = win0_moved ? ge_mv : xl_low20 ? ge_l20 : xl_peg ? ge_peg : ge_raw;",
                         "assign addr_ge_ram = (win0_moved ? ge_mv : xl_low20 ? ge_l20 : xl_peg ? ge_peg : ge_raw) | peg_window;"),
    # A4: the raw arm's slice compare off by one at the bound (the boundary itself)
    "ge_raw_margin": ("wire ge_raw = (cpu_addr_raw[31:20] >= ram_mib_hi);",
                      "wire ge_raw = (cpu_addr_raw[31:20] > ram_mib_hi);"),
    # A4: the low-20 alias arm is below every legal bound; claiming another way
    "ge_l20_zero": ("wire ge_l20 = 1'b0;", "wire ge_l20 = 1'b1;"),
    # A4: the PEGC arm's slice drops address bit 20
    "ge_peg_slice": ("({8'd0, cpu_addr_raw[23:20]} >= ram_mib_hi)",
                     "({8'd0, cpu_addr_raw[23:21]} >= ram_mib_hi)"),
    # A4: the window-0 arm's slice drops win0_hi[4]
    "ge_mv_slice": ("({7'd0, win0_hi[8:4]} >= ram_mib_hi)", "({8'd0, win0_hi[8:5]} >= ram_mib_hi)"),
    # A3: the EMS page's low 20 bits are the constant 0x48000 - the wrong constant
    "ems_const": ("{3'b010, gvram_low[15], ~gvram_low[15], gvram_low[14:0]}",
                  "{3'b100, gvram_low[15], ~gvram_low[15], gvram_low[14:0]}"),
    # window 0 at 0x0A: the B-block EMS/plane decode left on the RAM page
    "win0_ram_mask": ("dv_mv_dec & ~17'h00074", "dv_mv_dec & ~17'h00070"),
    # the E plane decoded in the digital mode too (the gate dropped)
    "e_plane_gate": ("wire        gvram_inten  = dv[3] && mode2_16color;",
                     "wire        gvram_inten  = dv[3];"),
    # the digital-mode E slot claimed in the 256-colour view too (the register file's slot)
    "e_plane_pegc": ("assign      e_plane_nc   = dv[3] && dv[16] && !pegc_256 && !mode2_16color;",
                     "assign      e_plane_nc   = dv[3] && dv[16] && !mode2_16color;"),
    # window 0 below page 8: the hole stops one page short (page 06 aliases RAM again)
    "win0_hole_page": ("(win0_sel[7:3] == 5'd0)", "(win0_sel[7:2] == 6'd0)"),
    # window 0 at 0x0A: the RAM page test off by one page value
    "win0_ram_page": ("(win0_sel == 8'h0A)", "(win0_sel == 8'h0C)"),
    # A3: the EMS splice's bit-15 carry term not inverted (the whole concat, so the
    # anchor cannot land in the comment above it)
    "ems_bit15": ("{3'b010, gvram_low[15], ~gvram_low[15], gvram_low[14:0]}",
                  "{3'b010, gvram_low[15], gvram_low[15], gvram_low[14:0]}"),
}

# Plants that can only be refuted when the old revision has the addr_ge_ram output.
GE_OUTPUT_PLANTS = {"ge_ge_ram_output"}

WRAP = r"""
module wrap(
  input [2:0] sel,
  input [2:0] ram_sel,
  input [3:0] top_bank, input ide_rom_enable, input [1:0] d8_bank, input ide_ram_gate,
  input bios_ram_gate, input top_shadow_en, input fw_shadow_dirty, input [1:0] ems_state,
  input [7:0] win0_sel, input peg_window_i, input pegc_256, input pegc_plane,
  input [3:0] pegc_bank_a, input [3:0] pegc_bank_b, input mode2_16color,
  input [31:0] cpu_addr_raw, input sys16m_en, input [31:0] cpu_din, input [3:0] cpu_be, input [7:0] cpu_burstcount,
  input cpu_line_read, input cpu_valid, input cpu_write,
  output mismatch);
  // guest_ram_bytes: pc9821_system's size_code_bytes(ram_size_sel), the reachable set
  // (PREMISES below keeps this table equal to that function's).
  reg [31:0] guest_ram_bytes;
  always @* case (ram_sel)
    3'd0: guest_ram_bytes = 32'h0010_0000; 3'd1: guest_ram_bytes = 32'h0020_0000;
    3'd2: guest_ram_bytes = 32'h0040_0000; 3'd3: guest_ram_bytes = 32'h0080_0000;
    3'd4: guest_ram_bytes = 32'h0100_0000; 3'd5: guest_ram_bytes = 32'h0200_0000;
    3'd6: guest_ram_bytes = 32'h0400_0000; default: guest_ram_bytes = 32'h0600_0000;
  endcase
  reg [31:0] pack_base;
  always @* case (sel)
    3'd0: pack_base = 32'h0010_0000; 3'd1: pack_base = 32'h0020_0000;
    3'd2: pack_base = 32'h0040_0000; 3'd3: pack_base = 32'h0080_0000;
    3'd4: pack_base = 32'h0100_0000; 3'd5: pack_base = 32'h0200_0000;
    3'd6: pack_base = 32'h0400_0000; default: pack_base = 32'h0600_0000;
  endcase
  wire [31:0] ems_page_base  = pack_base + 32'h0010_0000 + 32'h0004_8000;
  wire [31:0] fw_shadow_base = pack_base + 32'h0010_0000 + 32'h0005_8000;
  wire [31:0] peg_base       = pack_base + 32'h0010_0000 + 32'h0008_0000;
  // pc9821_memory_subsystem's translation (sys16m_mirror / peg_high / bios_top -> eff_addr)
  wire sys16m_mirror = sys16m_en && !(|cpu_addr_raw[31:24]) && (cpu_addr_raw[23:16] >= 8'hFA);
  wire peg_high = (&cpu_addr_raw[31:24]) && (cpu_addr_raw[23:20] == 4'hF) && !cpu_addr_raw[19];
  wire bios_top = (&cpu_addr_raw[31:21]) && (cpu_addr_raw[19:15] >= 5'b11101);
  wire [31:0] cpu_addr = sys16m_mirror ? {12'd0, cpu_addr_raw[19:0]} :
                         peg_high      ? {8'd0,  cpu_addr_raw[23:0]} :
                         bios_top      ? {12'd0, cpu_addr_raw[19:0]} : cpu_addr_raw;
  // the window-0 translation exactly as pc9821_memory_map computes d_addr
  wire win0_in = !(|cpu_addr[31:20]) && (cpu_addr[19:17] == 3'b100);
  wire win0_mv = win0_in && (win0_sel != 8'h08);
  wire [8:0] win0_hi = {1'b0, win0_sel} + {8'd0, cpu_addr[16]};
  wire [31:0] d_addr = win0_mv ? {7'd0, win0_hi, cpu_addr[15:0]} : cpu_addr;
  wire peg_window = peg_window_i && (d_addr[31:19] == 13'h01E);
  wire [31:0] a_old, a_new;
  wire o1,o2,o3,o4,o5,o6,o7,o8,o9,o10,o11;
  wire [1:0] p1,p2; wire [14:0] q1; wire [31:0] c1,c2,c3,c4,c5,c6,c7;
  wire [3:0] be1; wire [7:0] bc1; wire v1,w1;
  wire cr1,cv1, cr2,cv2;
  wire [31:0] x1, x2; wire [3:0] be2; wire [7:0] bc2; wire v2,w2;
  wire a1,e1,s1, a2,e2,s2, ga1, ga2, gb1, gb2, gc1, gc2, gv1, gv2; wire [1:0] gp1, gp2; wire [14:0] go1, go2;
  wire gar1, gar2, en2;
  wire [31:0] do1, do2;
  pc9821_memory_map_old u_old(.top_bank(top_bank), .ide_rom_enable(ide_rom_enable), .d8_bank(d8_bank),
    .ide_ram_gate(ide_ram_gate), .bios_ram_gate(bios_ram_gate), .top_shadow_en(top_shadow_en),
    .fw_shadow_dirty(fw_shadow_dirty), .fw_shadow_base(fw_shadow_base), .ems_state(ems_state),
    .ems_page_base(ems_page_base), .win0_sel(win0_sel),%%OLD_EXTRA%% .pack_base(pack_base),
    .guest_ram_bytes(guest_ram_bytes), .peg_window(peg_window), .peg_base(peg_base),
    .pegc_256(pegc_256), .pegc_plane(pegc_plane), .pegc_bank_a(pegc_bank_a), .pegc_bank_b(pegc_bank_b),
    .pegc_packed(ga1), .pegc_reg_win(gb1), .pegc_nc(gc1),
    .gvram_window(gv1), .gvram_win_plane(gp1), .gvram_win_offset(go1),
    .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_dout(do1), .cpu_be(cpu_be),
    .cpu_burstcount(cpu_burstcount), .cpu_line_read(cpu_line_read), .cpu_valid(cpu_valid),
    .cpu_write(cpu_write), .cpu_ready(cr1), .cpu_resp_valid(cv1),
    .absent_area(a1),%%OLD_GE%% .ems_open_bus(e1), .fw_shadow_store(s1),
    .mem_addr(a_old), .mem_din(x1), .mem_dout(32'd0), .mem_be(be1), .mem_burstcount(bc1),
    .mem_valid(v1), .mem_write(w1), .mem_ready(1'b0), .mem_resp_valid(1'b0));
  pc9821_memory_map u_new(.top_bank(top_bank), .ide_rom_enable(ide_rom_enable), .d8_bank(d8_bank),
    .ide_ram_gate(ide_ram_gate), .bios_ram_gate(bios_ram_gate), .top_shadow_en(top_shadow_en),
    .fw_shadow_dirty(fw_shadow_dirty), .fw_shadow_base(fw_shadow_base), .ems_state(ems_state),
    .ems_page_base(ems_page_base), .win0_sel(win0_sel),
    .win0_sel_moved(win0_sel != 8'h08), .pack_base(pack_base),
    .guest_ram_bytes(guest_ram_bytes), .peg_window(peg_window), .peg_base(peg_base),
    .pegc_256(pegc_256), .pegc_plane(pegc_plane), .pegc_bank_a(pegc_bank_a), .pegc_bank_b(pegc_bank_b),
    .pegc_packed(ga2), .pegc_reg_win(gb2), .pegc_nc(gc2),
    .mode2_16color(mode2_16color), .e_plane_nc(en2),
    .gvram_window(gv2), .gvram_win_plane(gp2), .gvram_win_offset(go2),
    .cpu_addr(cpu_addr), .cpu_addr_raw(cpu_addr_raw), .xl_low20(sys16m_mirror || bios_top),
    .xl_peg(peg_high), .cpu_din(cpu_din), .cpu_dout(do2), .cpu_be(cpu_be),
    .cpu_burstcount(cpu_burstcount), .cpu_line_read(cpu_line_read), .cpu_valid(cpu_valid),
    .cpu_write(cpu_write), .cpu_ready(cr2), .cpu_resp_valid(cv2),
    .absent_area(a2), .addr_ge_ram(gar2), .ems_open_bus(e2), .fw_shadow_store(s2),
    .mem_addr(a_new), .mem_din(x2), .mem_dout(32'd0), .mem_be(be2), .mem_burstcount(bc2),
    .mem_valid(v2), .mem_write(w2), .mem_ready(1'b0), .mem_resp_valid(1'b0));
  // The map's line-response ports (cpu_line_dout / cpu_line_resp_valid) are NOT compared: P3
  // deleted them end to end, so a revision that still has them simply leaves the outputs open,
  // and one that does not has nothing to compare. Leaving the connections in would make those
  // nets undriven, and yosys's SAT treats an undriven wire as a free variable (that is how this
  // proof was failing against post-P3 revisions - the model was a dangling net, not a defect).
  // mem_addr is a don't-care wherever mem_valid is low (no backend request is issued)
  assign mismatch = v1 && (a_old != a_new);
  // the carved-out change: window 0 at 0x0A is plain RAM at d_addr (see the docstring)
  wire w0ram = win0_mv && (win0_sel == 8'h0A);
  wire w0ram_bad = gv2 || ga2 || gb2 || gc2 || en2 || e2 || a2 || s2 || (v2 != cpu_valid) ||
                   (v2 && (a_new != d_addr));
  // the third carve-out: window 0 below page 8 is a hole (absent, no request, no window)
  wire w0hole = win0_mv && (win0_sel[7:3] == 5'd0);
  wire w0hole_bad = !a2 || v2 || gv2 || ga2 || gb2 || gc2 || en2 || e2 || s2;
  // the second carve-out: the digital-mode E slot is no plane window and is e_plane_nc
  wire e_dig = !mode2_16color && !pegc_256 && !(|d_addr[31:20]) && (d_addr[19:15] == 5'b11100);
  wire gv_bad = e_dig ? gv2 : (gv1 != gv2);
  // and every other output must be untouched
  wire others = (v1 != v2) || (a1 != a2) || (e1 != e2) || (s1 != s2) || (ga1 != ga2) ||
                %%GE_TERM%%
                (en2 != e_dig) ||
                (gb1 != gb2) || (gc1 != gc2) || gv_bad || (gp1 != gp2) || (go1 != go2) ||
                (cr1 != cr2) || (cv1 != cv2) || (do1 != do2);
  wire unused = o1;
endmodule
"""

# The raw-address arm's connections, for an old revision that has them (P0-d and later).
OLD_EXTRA_RAW = "\n    .cpu_addr_raw(cpu_addr_raw), .xl_low20(sys16m_mirror || bios_top), .xl_peg(peg_high),\n    .win0_sel_moved(win0_sel != 8'h08),"
# addr_ge_ram arrived with P0-c; the pre-P0-c revision has no such port, and then it is not
# compared (there is nothing on the old side to compare with).
OLD_GE = " .addr_ge_ram(gar1),"
GE_TERM = "(gar1 != gar2) ||"


def git_show(rev):
    out = subprocess.run(["git", "show", "%s:%s" % (rev, MAP)], cwd=REPO,
                         capture_output=True, text=True)
    if out.returncode:
        sys.exit("git show failed: " + out.stderr)
    return out.stdout


def premises():
    """The invariants this proof mirrors, re-read from the RTL that will be built.

    A proof is only as good as its premises: these two tables ARE the premises, so a drift on
    either side must fail loudly here rather than pass a proof of a design nobody builds.
    """
    failures = []
    sys_text = open(os.path.join(REPO, SYSTEM)).read()
    found = re.findall(r"size_code_bytes\s*=\s*(32'h[0-9A-Fa-f_]+)", sys_text)
    if found[:8] != SIZES:
        failures.append("pc9821_system size_code_bytes is %r, expected %r" % (found[:8], SIZES))
    sub_text = open(os.path.join(REPO, SUBSYSTEM)).read()
    if "parameter [26:0] PACK_BYTES = 27'h010_0000" not in sub_text:
        failures.append("pc9821_memory_subsystem PACK_BYTES is not 27'h010_0000")
    if "wire [31:0] ems_page_base = pack_base + PACK_BYTES + 32'h0004_8000;" not in sub_text:
        failures.append("pc9821_memory_subsystem ems_page_base is not pack_base + PACK_BYTES + 32'h0004_8000")
    if "wire [31:0] fw_shadow_base = pack_base + PACK_BYTES + 32'h0005_8000;" not in sub_text:
        failures.append("pc9821_memory_subsystem fw_shadow_base is not pack_base + PACK_BYTES + 32'h0005_8000")
    if "wire [31:0] peg_base = pack_base + PACK_BYTES + 32'h0008_0000;" not in sub_text:
        failures.append("pc9821_memory_subsystem peg_base is not pack_base + PACK_BYTES + 32'h0008_0000")
    return failures


def prove(old_rev, plant=None):
    old = git_show(old_rev).replace("module pc9821_memory_map", "module pc9821_memory_map_old")
    new = open(os.path.join(REPO, MAP)).read()
    if plant:
        a, b = PLANTS[plant]
        if new.count(a) != 1:
            sys.exit("plant %s: anchor text found %d times, expected exactly 1 (a plant that "
                     "lands in a comment proves nothing)" % (plant, new.count(a)))
        new = new.replace(a, b, 1)
    wrap = WRAP.replace("%%OLD_EXTRA%%", OLD_EXTRA_RAW if "cpu_addr_raw" in old else "")
    wrap = wrap.replace("%%OLD_GE%%", OLD_GE if "addr_ge_ram" in old else "")
    wrap = wrap.replace("%%GE_TERM%%", GE_TERM if "addr_ge_ram" in old else "")
    wrap = wrap.replace("wire unused = o1;", "").replace("wire o1,o2,o3,o4,o5,o6,o7,o8,o9,o10,o11;", "")
    wrap = wrap.replace("  assign mismatch = v1 && (a_old != a_new);",
                        "  assign mismatch = w0ram ? w0ram_bad : w0hole ? w0hole_bad :"
                        " ((v1 && (a_old != a_new)) || others);")
    with tempfile.TemporaryDirectory() as tmp:
        open(os.path.join(tmp, "old.sv"), "w").write(old)
        open(os.path.join(tmp, "new.sv"), "w").write(new)
        open(os.path.join(tmp, "wrap.sv"), "w").write(wrap)
        script = ("read_verilog -sv old.sv new.sv wrap.sv; hierarchy -top wrap; proc; flatten; memory_map; "
                  "opt_clean; sat -prove mismatch 0 -verify -show-inputs")
        r = subprocess.run(["yosys", "-p", script], cwd=tmp, capture_output=True, text=True)
    proved = r.returncode == 0 and "SUCCESS!" in r.stdout
    return proved, r.stdout[-3000:] + r.stderr[-1500:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", default=DEFAULT_OLD)
    ap.add_argument("--plant", choices=sorted(PLANTS))
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--skip-premises", action="store_true",
                    help="prove the outputs only (premise drift is then unchecked)")
    a = ap.parse_args()
    if not a.skip_premises:
        bad = premises()
        if bad:
            for b in bad:
                print("PREMISE CHANGED: " + b)
            sys.exit("check_memmap_addr_equiv: the proof's premises no longer hold (fix the map or "
                     "this proof's model)")
        print("premises: eight MiB sizes, PACK_BYTES 1 MiB, ems/shadow/peg base constants - OK")
    if a.selftest:
        ok, log = prove(a.old)
        if not ok:
            print(log)
            sys.exit("selftest: the clean proof failed")
        old_has_ge = "addr_ge_ram" in git_show(a.old)
        skipped = 0
        for p in sorted(PLANTS):
            if p in GE_OUTPUT_PLANTS and not old_has_ge:
                # the old revision has no addr_ge_ram output to compare against
                skipped += 1
                continue
            ok, _ = prove(a.old, p)
            if ok:
                sys.exit("selftest: plant %s was NOT caught" % p)
        print("check_memmap_addr_equiv: selftest PASS (clean proven, %d plants caught%s)"
              % (len(PLANTS) - skipped, ", %d skipped: old has no addr_ge_ram" % skipped if skipped else ""))
        return
    ok, log = prove(a.old, a.plant)
    if a.plant:
        print("plant %s: %s" % (a.plant, "NOT caught" if ok else "caught (as required)"))
        sys.exit(1 if ok else 0)
    print(log if not ok else "check_memmap_addr_equiv: PROVEN (mem_addr and every other output equal, the late-muxed region decode, the RAM-bound slice compares and the EMS splice included)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
