#!/usr/bin/env python3
"""check_iobus_lane_inv.py -- prove pc9821_iobus's lane select cut exact on the working tree
(docs/timing.md, the I/O FSM lane select).

The I/O FSM used to hold the device-read lane in its own register across S_DEVWAIT:

    S_BYTE entering S_DEVWAIT:  dev_lane <= lane;
    lane = (state == S_DEVWAIT) ? dev_lane : first_lane(pending_be)

The cut reads `lane = first_lane(pending_be)` in every state and drops `dev_lane`. That is exact
iff the held copy would always agree, i.e. in every reachable S_DEVWAIT cycle the lane equals the
one S_BYTE presented: S_BYTE enters S_DEVWAIT without clearing its enable, nothing writes
`pending_be` while S_DEVWAIT holds, and only S_DEVWAIT's exit clears it.

The tool re-creates the held copy as a shadow register in a COPY of the module (the tree is never
edited), loaded from `lane` in every S_BYTE cycle (S_DEVWAIT is entered only from S_BYTE, so in
an S_DEVWAIT cycle it holds exactly what `dev_lane` held), and proves by induction from a reset
(yosys `sat -tempinduct`) that `lane == shadow` in every S_DEVWAIT cycle. Every device the module
instantiates is a stub built from its own port list (tools/iobus_formal.py), so their outputs -
`device_rd_hold` among them - are free, and every top-level input, the reset included, is free.

A second property proves the lane walk's one-step-ahead registers exact (THE LANE WALK in the
module, the th05 Music Room timing cut): `port_addr = {base_addr[15:2], lane}` equals the sum
`base_addr[15:0] + lane` it replaced (base_addr[1:0] is always 0), the registered `lane` equals
first_lane(pending_be) in every cycle, and the registered chip selects were decoded from the port
the cycle presents (the decode's address one cycle earlier, port_addr_nx, equals port_addr).

(When the cut landed, the pre-cut module was also proven equivalent to the cut one as a whole; that
comparison needs the pre-cut revision and is not repeated here. This proof is the invariant that
makes the cut exact, checked against the current module.)

--selftest plants defects that must each make the proof FAIL.

  python3 tools/check_iobus_lane_inv.py [--selftest]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iobus_formal  # noqa: E402

PROP = r"""
  // ---- check_iobus_lane_inv.py (pasted into a copy; never in the tree) ----
  reg [1:0] lane_chk_held;   // the dropped dev_lane: the lane S_BYTE presented
  always @(posedge clk) if (state == S_BYTE) lane_chk_held <= lane;
  always @* if (!reset && state == S_DEVWAIT) assert (lane == lane_chk_held);
"""

PROP_PORT = r"""
  // ---- check_iobus_lane_inv.py, the lane port (pasted into a copy; never in the tree) ----
  always @* if (!reset) assert (port_addr == base_addr[15:0] + {14'd0, lane});
  // the lane walk one step ahead: the registered lane is the combinational one it replaced, and
  // the registered selects were decoded from the port this cycle presents
  always @* if (!reset) assert (lane == first_lane(pending_be));
  reg [15:0] lane_chk_dec;
  reg        lane_chk_up;
  always @(posedge clk) begin lane_chk_dec <= port_addr_nx; lane_chk_up <= !reset; end
  always @* if (!reset && lane_chk_up) assert (lane_chk_dec == port_addr);
"""
BASE_LOAD = "            base_addr <= {cpu_addr[31:2], 2'b00};\n"
LANE_ADV = "                           || ((state == S_DEVWAIT) && !device_rd_hold);\n"
PORT_PLANTS = [
    # the dword base keeps the CPU address's low bits (the concatenation would drop a carry)
    (BASE_LOAD, "            base_addr <= cpu_addr;\n"),
    # the one-step-ahead lane misses S_DEVWAIT's lane clear
    (LANE_ADV, "                           ;\n"),
    # the one-step-ahead lane ignores a held S_DEVWAIT (device_rd_hold)
    (LANE_ADV, "                           || (state == S_DEVWAIT);\n"),
]

DEVWAIT_ENTRY = "            state <= S_DEVWAIT;\n"
DEVWAIT_CAPTURE = ("          if (!device_rd_hold) begin\n"
                   "            read_data[{lane, 3'b000} +: 8] <= lane_rdata;\n")
FLUSH_EXIT = ("        S_FLUSH: if (flush_done)\n"
              "          state <= last_lane ? S_REPLY : S_BYTE;\n")

PLANTS = [
    # S_BYTE clears its enable on the way into S_DEVWAIT (the lane moves under the wait)
    (DEVWAIT_ENTRY, "            pending_be <= pending_be & ~lane_mask;\n" + DEVWAIT_ENTRY),
    # a held S_DEVWAIT cycle (device_rd_hold) clears the enable before the capture
    (DEVWAIT_CAPTURE, "          if (device_rd_hold) pending_be <= pending_be & ~lane_mask;\n"
                      + DEVWAIT_CAPTURE),
    # S_DEVWAIT entered from somewhere other than S_BYTE (the flush exit, whose S_BYTE cleared
    # its enable)
    (FLUSH_EXIT, "        S_FLUSH: if (flush_done)\n"
                 "          state <= last_lane ? S_REPLY : S_DEVWAIT;\n"),
]


def prove(plant=None, prop=PROP):
    return iobus_formal.prove_property(prop, [plant] if plant else [])


def main():
    ok, log = prove()
    print("iobus S_DEVWAIT -> first_lane(pending_be) == the lane S_BYTE presented: %s"
          % ("PROVEN" if ok else "FAILED"))
    bad = 0 if ok else 1
    if not ok:
        print(log[-3000:])
    pok, plog = prove(prop=PROP_PORT)
    print("iobus lane walk one step ahead (lane, port_addr, selects) == the combinational form: %s"
          % ("PROVEN" if pok else "FAILED"))
    if not pok:
        bad += 1
        print(plog[-3000:])
    if "--selftest" in sys.argv:
        for a, b in PLANTS:
            pok, _ = prove((a, b))
            first = next(ln for ln, ref in zip(b.splitlines(), a.splitlines() + [""] * 9)
                         if ln != ref)
            print("  plant %s: %s" % ("NOT caught" if pok else "caught", first.strip()[:64]))
            bad += pok
        for a, b in PORT_PLANTS:
            pok, _ = prove((a, b), PROP_PORT)
            print("  plant %s: %s" % ("NOT caught" if pok else "caught", b.strip()[:64]))
            bad += pok
        print("check_iobus_lane_inv: selftest %s" % ("FAIL" if bad else "PASS"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
