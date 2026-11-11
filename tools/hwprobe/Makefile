TOOLS := gfxbenc2 egcplane gfxbench idelat ideprobe ioprobe irqwd opnapro pegcwatch probe2 sndtest memmap a20map d8bank integ crt31k crt24k pegcrd grcgpace gdcfig txtmode fdmode dmaroute rboot xe10cfg ym29 fdwrite selfmod stamp gvdump risky gtimer rstdtr rwipe

# Build the DOS .COM probe binaries from their assembly sources.
#
# A .COM is linked at 0x100 and objcopy emits .text with no padding. The
# binaries are NOT committed: `make` builds them, `make clean` removes them.
#
# Each tool lives in its own folder: <tool>/<tool>.s (the source), plus the
# optional <tool>_decode.py (a capture decoder) and RUN*.BAT (a DOS batch that
# runs the .COM on the machine). See README.md for what each probe measures.

# A DOS .COM is loaded at 0x100 in a 64 KiB segment, so its image must be at most
# 0x10000 - 0x100 = 65280 bytes. The toolchain does NOT catch an overflow: a padded
# probe2.s links and objcopy's to a 68074-byte "COM" with no error, and DOS simply
# refuses to load it - which would be discovered on the machine, after the trip.
# probe2 is the file several investigations append to and it has ~1.3 KiB of headroom, so the
# limit is enforced here, once, for every tool.
COM_MAX := 65280

# THE DOS-LEGAL NAME OF EACH TOOL'S .COM, where it differs from the tool's own name. DOS 8.3 gives
# a filename stem EIGHT characters, and PEGCWATCH is nine - so a DOS filesystem cannot hold
# `PEGCWATCH.COM` at all, which meant the probe could not be copied to the machine, let alone
# loaded. The tool's DIRECTORY stays `pegcwatch/` so the decoder's path
# (`tools/hwprobe/pegcwatch/pegcwatch_decode.py`) and every citation of it stay valid; only the
# built file is renamed. Nothing else changes: the rows the probe PRINTS still begin `PEGCWATCH`,
# and the decoder parses those, not the filename.
COM_NAME_pegcwatch := pegcw

com_name = $(if $(COM_NAME_$(1)),$(COM_NAME_$(1)),$(1))

.DEFAULT_GOAL := all
.PHONY: all clean

all: $(foreach t,$(TOOLS),$(t)/$(call com_name,$(t)).com) cpusuite tcrpm/tcrpm.com sdshmoo/sdshmoo.com xe10t/xe10t.com xe10t/xe10u.com mputest/mputest.com speed/speed.com

# CPUSUITE is NASM, not GNU as: it runs z486's own test programs (src/z486/tests/programs, NASM
# sources), and its pack is GENERATED from them by gen_cpusuite.py, so a change to the suite
# reaches the pack on the next make. Both outputs are git-ignored (cpusuite/build/).
.PHONY: cpusuite
cpusuite: cpusuite/cpusuite.com cpusuite/build/CPUSUITE.BIN

cpusuite/cpusuite.com: cpusuite/cpusuite.asm
	nasm -f bin -o $@ $<
	@if [ `wc -c < $@` -gt $(COM_MAX) ]; then echo "ERROR: $@ is over the DOS .COM limit"; rm -f $@; exit 1; fi
	@echo "built $@"

# TCRPM is NASM too: it switches to 32-bit protected mode and back (README).
tcrpm/tcrpm.com: tcrpm/tcrpm.asm
	nasm -f bin -o $@ $<
	@if [ `wc -c < $@` -gt $(COM_MAX) ]; then echo "ERROR: $@ is over the DOS .COM limit"; rm -f $@; exit 1; fi
	@echo "built $@"

# SDSHMOO is NASM too: the SDRAM_CLK phase shmoo, 32-bit protected mode run from GVRAM (README).
sdshmoo/sdshmoo.com: sdshmoo/sdshmoo.asm
	nasm -f bin -o $@ $<
	@if [ `wc -c < $@` -gt $(COM_MAX) ]; then echo "ERROR: $@ is over the DOS .COM limit"; rm -f $@; exit 1; fi
	@echo "built $@"

CPUSUITE_DEPS := $(wildcard ../../src/z486/tests/programs/*.asm ../../src/z486/tests/programs/*.json) \
                 ../../src/z486/tests/test_protected_mode.py cpusuite/prelude.inc cpusuite/gen_cpusuite.py
cpusuite/build/CPUSUITE.BIN: $(CPUSUITE_DEPS)
	python3 cpusuite/gen_cpusuite.py --out cpusuite/build

# One .COM per tool: as -> ld -> objcopy.
define build_com
$(1)/$(call com_name,$(1)).com: $(1)/$(1).s
	as --32 -o $(1)/$(1).o $$<
	ld -m elf_i386 -Ttext 0x100 -e 0x100 -o $(1)/$(1).elf $(1)/$(1).o
	objcopy -O binary -j .text $(1)/$(1).elf $$@
	@if [ `wc -c < $$@` -gt $(COM_MAX) ]; then \
	  echo "ERROR: $$@ is `wc -c < $$@` bytes - over the $(COM_MAX)-byte DOS .COM limit"; \
	  echo "       (a .COM loads at 0x100 in a 64 KiB segment; split the tool or move data out)"; \
	  rm -f $$@; exit 1; fi
	rm -f $(1)/$(1).o $(1)/$(1).elf
	@echo "built $$@"
endef

$(foreach t,$(TOOLS),$(eval $(call build_com,$(t))))

# Include files of single-source tools.
xe10cfg/xe10cfg.com: xe10cfg/xe10cfg_ext.inc
txtmode/txtmode.com: txtmode/txtmode_d.inc

# XE10T, the unified timing probe: several include files, a tighter size limit (its
# buffers live above 0xC000 in its own segment, so the image must end below it: 48896
# bytes), a forward-.equ guard (GAS reads a not-yet-defined symbol in an Intel-syntax
# immediate as a memory operand) and the identity stamp (sha-256 prefix + CRC-32 of the
# image, written in place by the decoder; the probe prints both and its own run-time CRC).
XE10T_MAX := 48896
XE10T_SRC := xe10t/xe10t.s $(wildcard xe10t/*.inc)
xe10t/xe10t.com: $(XE10T_SRC) xe10t/xe10t_decode.py
	python3 -I xe10t/xe10t_decode.py --check-source xe10t/xe10t.s
	as --32 -I xe10t -o xe10t/xe10t.o xe10t/xe10t.s
	ld -m elf_i386 -Ttext 0x100 -e 0x100 -o xe10t/xe10t.elf xe10t/xe10t.o
	objcopy -O binary -j .text xe10t/xe10t.elf $@
	@if [ `wc -c < $@` -gt $(XE10T_MAX) ]; then \
	  echo "ERROR: $@ is `wc -c < $@` bytes - over XE10T's $(XE10T_MAX)-byte limit (buffers at 0xC000)"; \
	  rm -f $@; exit 1; fi
	python3 -I xe10t/xe10t_decode.py --stamp $@
	rm -f xe10t/xe10t.o xe10t/xe10t.elf
	@echo "built $@"

# XE10U.COM: the same harness assembled with XE10U defined - without the IDE/FDC/CD/RASTER/FDC2
# sections, with /OPNA4 and /AUDIT2 - so XE10T.COM stays the binary the kit-1 /FDC2 captures
# compare against (the decoder compares only captures of one binary).
xe10t/xe10u.com: $(XE10T_SRC) xe10t/xe10t_decode.py
	python3 -I xe10t/xe10t_decode.py --check-source xe10t/xe10t.s
	as --32 --defsym XE10U=1 -I xe10t -o xe10t/xe10u.o xe10t/xe10t.s
	ld -m elf_i386 -Ttext 0x100 -e 0x100 -o xe10t/xe10u.elf xe10t/xe10u.o
	objcopy -O binary -j .text xe10t/xe10u.elf $@
	@if [ `wc -c < $@` -gt $(XE10T_MAX) ]; then \
	  echo "ERROR: $@ is `wc -c < $@` bytes - over the $(XE10T_MAX)-byte limit (buffers at 0xC000)"; \
	  rm -f $@; exit 1; fi
	python3 -I xe10t/xe10t_decode.py --stamp $@
	rm -f xe10t/xe10u.o xe10t/xe10u.elf
	@echo "built $@"

# SPEED: the speed reference (NASM loader + the gate's own Dhrystone). The Dhrystone objects are
# built by the gate's Makefile itself (its CFLAGS, -O2), at two DHRY_ITERS, into speed/build/;
# speed/spd_start.S replaces the gate's port-signalling startup.S and speed/mkblob.py turns the
# two MARK writes into INT 40h (see both). speed/build/ is removed after the link.
SPEED_DHRY := ../../src/z486/tests/dhrystone
SPEED_OBJS := dhrystone_main.o dhry_1.o dhry_2.o support.o
speed/speed.com: speed/speed.asm speed/spd_start.S speed/mkblob.py $(wildcard $(SPEED_DHRY)/*.c $(SPEED_DHRY)/*.h) $(SPEED_DHRY)/dhrystone.ld $(SPEED_DHRY)/Makefile
	rm -rf speed/build
	set -e; for n in 10000 100000; do \
	  b=$(abspath speed/build)/d$$n; mkdir -p $$b; \
	  $(MAKE) -s -C $(SPEED_DHRY) BUILD_DIR=$$b DHRY_ITERS=$$n $(addprefix $$b/,$(SPEED_OBJS)); \
	  gcc -m32 -c speed/spd_start.S -o $$b/st.o; \
	  gcc -m32 -nostdlib -static -no-pie -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-T,$(SPEED_DHRY)/dhrystone.ld \
	    $$b/st.o $(addprefix $$b/,$(SPEED_OBJS)) -o $$b/d.elf; \
	  python3 -I speed/mkblob.py $$b/d.elf speed/build/d$$n.bin; done
	nasm -f bin -o $@ speed/speed.asm
	@if [ `wc -c < $@` -gt $(COM_MAX) ]; then echo "ERROR: $@ is over the DOS .COM limit"; rm -f $@; exit 1; fi
	rm -rf speed/build
	@echo "built $@ (`wc -c < $@` bytes)"

# MPUTEST, the MIDI-card probe: its op tables are GENERATED (mputest_decode.py --gen writes
# mputest_tables.inc and the bench's tests/pc9821/mputest_bytes.svh from one source), so the
# build first refuses a stale include, then assembles with the tool's folder on the include path.
mputest/mputest.com: mputest/mputest.s mputest/mputest_tables.inc mputest/mputest_decode.py
	python3 -I mputest/mputest_decode.py --check
	as --32 -I mputest -o mputest/mputest.o mputest/mputest.s
	ld -m elf_i386 -Ttext 0x100 -e 0x100 -o mputest/mputest.elf mputest/mputest.o
	objcopy -O binary -j .text mputest/mputest.elf $@
	@if [ `wc -c < $@` -gt $(COM_MAX) ]; then echo "ERROR: $@ is over the DOS .COM limit"; rm -f $@; exit 1; fi
	rm -f mputest/mputest.o mputest/mputest.elf
	@echo "built $@"

# THE XE10 KIT: one folder per disk for a session at the real machine (xe10kit/RUNLIST.TXT).
# `make kit` (KIT_DIR, default the repository's .build/xe10-kit) copies the built probes under
# their DOS names beside the kit's own batches; W95/PATTERN.BIN is generated (byte n = n mod 251,
# 300000 bytes, as W95/TEST720.TXT says). The kit is build output: it is not committed.
KIT_DIR ?= ../../.build/xe10-kit
KIT_COMS := xe10cfg/xe10cfg.com rboot/rboot.com fdmode/fdmode.com probe2/probe2.com \
            mputest/mputest.com sndtest/sndtest.com
.PHONY: kit
kit: $(KIT_COMS)
	rm -rf $(KIT_DIR)
	mkdir -p $(KIT_DIR)/A $(KIT_DIR)/W95
	for c in $(KIT_COMS); do b=`basename $$c .com`; \
	  cp $$c $(KIT_DIR)/A/`echo $$b | tr a-z A-Z`.COM; done
	cp xe10kit/A/*.BAT mputest/RUNMPU.BAT $(KIT_DIR)/A/
	cp xe10kit/W95/TEST720.TXT $(KIT_DIR)/W95/
	python3 -c "import sys; sys.stdout.buffer.write(bytes(i % 251 for i in range(300000)))" \
	  > $(KIT_DIR)/W95/PATTERN.BIN
	cp xe10kit/RUNLIST.TXT $(KIT_DIR)/
	(cd $(KIT_DIR) && find . -type f ! -name SHA256SUMS.TXT | sort | xargs sha256sum > SHA256SUMS.TXT)
	@echo "kit in $(KIT_DIR)"

clean:
	rm -f $(foreach t,$(TOOLS),$(t)/$(t).com $(t)/$(call com_name,$(t)).com $(t)/$(t).o $(t)/$(t).elf)
	rm -f cpusuite/cpusuite.com tcrpm/tcrpm.com sdshmoo/sdshmoo.com xe10t/xe10t.com xe10t/xe10t.o xe10t/xe10t.elf xe10t/xe10u.com xe10t/xe10u.o xe10t/xe10u.elf
	rm -f mputest/mputest.com mputest/mputest.o mputest/mputest.elf
	rm -rf cpusuite/build
