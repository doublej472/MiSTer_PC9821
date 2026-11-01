TOOLS := gfxbenc2 egcplane gfxbench idelat ideprobe ioprobe irqwd opnapro pegcwatch probe2 sndtest memmap a20map d8bank integ crt31k crt24k pegcrd grcgpace gdcfig txtmode fdmode

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

all: $(foreach t,$(TOOLS),$(t)/$(call com_name,$(t)).com) cpusuite tcrpm/tcrpm.com sdshmoo/sdshmoo.com

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

clean:
	rm -f $(foreach t,$(TOOLS),$(t)/$(t).com $(t)/$(call com_name,$(t)).com $(t)/$(t).o $(t)/$(t).elf)
	rm -f cpusuite/cpusuite.com tcrpm/tcrpm.com sdshmoo/sdshmoo.com
	rm -rf cpusuite/build
