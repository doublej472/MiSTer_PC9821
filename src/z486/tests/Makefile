# Makefile for z486 testing
#
# Builds and runs single-instruction tests for the z486 core

# Paths
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
Z486_DIR := ..
VERILATOR := verilator
JOBS ?= 8

# Source files
# Note: muldiv.sv and bus_prefetch.sv are standalone modules that can optionally
# replace the inline mul/div and bus/prefetch code in z486.sv.
# Currently z486.sv uses inline code; uncomment modules below when integrating.
X87_DIR := $(Z486_DIR)/x87
X87_REF_DIR := x87_reference
X87_UCODE_GEN := $(X87_DIR)/x87_ucode.svh \
			$(X87_DIR)/x87_ucode.mif \
			$(X87_DIR)/x87_ucode.mem \
			$(X87_DIR)/x87_entries.svh
X87_COMMAND_GEN := $(X87_DIR)/x87_command_decode.svh \
			$(X87_DIR)/x87_command_decode.mif
X87_LOGEXP_GEN := $(X87_DIR)/x87_logexp_tables.svh \
			$(X87_DIR)/x87_logexp_tables.mif
X87_GEN := $(X87_UCODE_GEN) $(X87_COMMAND_GEN) $(X87_LOGEXP_GEN)
X87_RTL := $(X87_DIR)/x87_pkg.sv \
			$(X87_DIR)/x87_ucode_pkg.sv \
			$(X87_DIR)/x87_bridge.sv \
			$(X87_DIR)/x87_cordic_rom.sv \
			$(X87_DIR)/x87_cordic_scratch.sv \
			$(X87_DIR)/x87_ucode_rom.sv \
			$(X87_DIR)/x87_sequencer.sv \
			$(X87_DIR)/x87_executor.sv \
			$(X87_DIR)/x87_transfer_fifo.sv \
			$(X87_DIR)/x87_stack_mem.sv \
			$(X87_DIR)/x87_command_rom.sv \
			$(X87_DIR)/x87_control.sv \
			$(X87_DIR)/x87_unit.sv

RTL_SRCS := $(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/z486_cache_map_pkg.sv $(X87_DIR)/x87_pkg.sv \
			$(X87_DIR)/x87_ucode_pkg.sv $(Z486_DIR)/z486.sv \
			$(Z486_DIR)/cpu_throttle.sv $(Z486_DIR)/interrupt_controller.sv \
			$(Z486_DIR)/ucode_rom.sv $(Z486_DIR)/microsequencer.sv $(Z486_DIR)/event_control.sv $(Z486_DIR)/hardwired_control.sv $(Z486_DIR)/data_access.sv \
			$(Z486_DIR)/data_unit.sv $(Z486_DIR)/gpr_write_merge.sv $(Z486_DIR)/address_unit.sv \
			$(Z486_DIR)/shifter.sv $(Z486_DIR)/mul_div.sv \
			$(Z486_DIR)/decoder.sv \
			$(Z486_DIR)/alu.sv $(Z486_DIR)/prefetch.sv \
			$(Z486_DIR)/paging_unit.sv $(Z486_DIR)/paging_tlb.sv $(Z486_DIR)/paging_walker.sv \
			$(Z486_DIR)/memory.sv $(Z486_DIR)/bus_unit.sv $(Z486_DIR)/cache_unit.sv $(Z486_DIR)/l1_cache.sv $(Z486_DIR)/l1_icache.sv \
			$(filter-out $(X87_DIR)/x87_pkg.sv $(X87_DIR)/x87_ucode_pkg.sv,$(X87_RTL)) \
			$(Z486_DIR)/dsp_mul.sv $(Z486_DIR)/protection.sv $(Z486_DIR)/segmentation_unit.sv
RTL_DEPS := $(Z486_DIR)/ucode_recipes.svh $(Z486_DIR)/pb_b1_class.svh \
            $(Z486_DIR)/z486_platform.svh \
            $(Z486_DIR)/z486_pc98_preset.svh $(Z486_DIR)/pla_entry.svh \
            $(Z486_DIR)/pla_control.svh $(Z486_DIR)/length_table.svh \
            $(Z486_DIR)/ucode.hex $(Z486_DIR)/pla_entry_rom.hex \
            $(Z486_DIR)/pla_group_entry.hex $(X87_GEN) \
			$(X87_DIR)/x87_logexp_rom.sv
# Optional modules (not yet integrated):
# RTL_SRCS += $(Z486_DIR)/muldiv.sv $(Z486_DIR)/bus_prefetch.sv
TB_SRCS := tb_z486.sv
CPP_SRCS := sim_main.cpp

# Verilator flags (common, no --top-module — set per target)
VFLAGS_BASE := --timing
VFLAGS_BASE += -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-SYNCASYNCNET
VFLAGS_BASE += -cc --exe
VFLAGS_BASE += -O3
VFLAGS_BASE += --build
VFLAGS_BASE += -j $(JOBS)
VFLAGS_BASE += -I$(Z486_DIR)
VFLAGS_BASE += -I$(X87_DIR)
VFLAGS_BASE += -I$(X87_REF_DIR)
VFLAGS_BASE += -CFLAGS "-std=c++14 -O3"

# With VCD trace support (singlestep tests — short runs, need waveforms)
VFLAGS := $(VFLAGS_BASE) --trace --trace-structs
# With FST trace (test386/test186 — millions of cycles, FST is compact)
VFLAGS_FST := $(VFLAGS_BASE) --trace-fst
# Without trace (default test386/test186 build)
VFLAGS_NOTRACE := $(VFLAGS_BASE)

# test386 testbench sources
TB386_SRCS := tb_test386.sv
CPP386_SRCS := sim_main_test386.cpp

# test186 testbench sources (80186 test suite)
TB186_SRCS := tb_test186.sv
CPP186_SRCS := sim_main_test186.cpp

# protected mode testbench sources
TB_PROT_SRCS := tb_protected_mode.sv
TB_PROT_DEPS := m0_profile.svh   # included by the testbench: prerequisite only
CPP_PROT_SRCS := sim_main_protected_mode.cpp
CPP_QUAKE_SNAPSHOT_SRCS := sim_main_quake_snapshot.cpp

# L1 cache unit test
TB_L1_SRCS := tb_l1_cache.sv
CPP_L1_SRCS := sim_main_l1_cache.cpp
TB_L1I_SRCS := tb_l1_icache.sv
CPP_L1I_SRCS := sim_main_l1_icache.cpp
TB_MEMORY_ORDER_SRCS := tb_memory_order.sv
CPP_MEMORY_ORDER_SRCS := sim_main_memory_order.cpp
TB_CACHE_COHERENCE_SRCS := tb_cache_coherence.sv
CPP_CACHE_COHERENCE_SRCS := sim_main_cache_coherence.cpp
TB_LOAD_WAW_SRCS := tb_load_waw.sv
CPP_LOAD_WAW_SRCS := sim_main_load_waw.cpp
TB_GPR_HAZARD_SRCS := tb_gpr_hazard.sv
CPP_GPR_HAZARD_SRCS := sim_main_gpr_hazard.cpp
TB_GPR_MERGE_SRCS := tb_gpr_write_merge.sv
CPP_GPR_MERGE_SRCS := sim_main_gpr_write_merge.cpp
# data_unit plus its sub-units; the bench drives the deferred GPR write ports
# directly and needs no cache, bus or sequencer.
LOAD_WAW_RTL := $(Z486_DIR)/data_unit.sv $(Z486_DIR)/gpr_write_merge.sv $(Z486_DIR)/alu.sv $(Z486_DIR)/shifter.sv \
			$(Z486_DIR)/mul_div.sv $(Z486_DIR)/dsp_mul.sv
TB_MEMMAP_SRCS := tb_memmap_template.sv
CPP_MEMMAP_SRCS := sim_main_memmap_template.cpp
TB_INTERRUPT_NMI_SRCS := tb_interrupt_nmi.sv
TB_PAGING_WALKER_SRCS := tb_paging_walker.sv
TB_PAGING_TLB_SRCS := tb_paging_tlb_lru.sv
TB_MEM_RESP_SRCS := tb_mem_resp.sv
TB_CACHE_FLUSH_SRCS := tb_cache_flush.sv
TB_ADDR_UNIT_RELOC_SRCS := tb_addr_unit_reloc_equiv.sv
TB_RESET_SWEEP_SRCS := tb_reset_sweep.sv
CPP_RESET_SWEEP_SRCS := sim_main_reset_sweep.cpp
TB_PC98_MAP_SRCS := tb_pc98_map.sv
CPP_PC98_MAP_SRCS := sim_main_pc98_map.cpp
TB_X87_BRIDGE_SRCS := tb_x87_bridge.sv
CPP_X87_BRIDGE_SRCS := sim_main_x87_bridge.cpp
TB_X87_SEQ_SRCS := tb_x87_sequencer.sv
CPP_X87_SEQ_SRCS := sim_main_x87_sequencer.cpp
TB_X87_EXECUTOR_SRCS := tb_x87_executor.sv
CPP_X87_EXECUTOR_SRCS := sim_main_x87_executor.cpp
TB_X87_TESTFLOAT_SRCS := tb_x87_testfloat.sv
CPP_X87_TESTFLOAT_SRCS := sim_main_x87_testfloat.cpp
TB_X87_CORE_SRCS := tb_x87_core.sv
CPP_X87_CORE_SRCS := sim_main_x87_core.cpp
TB_X87_FIFO_SRCS := tb_x87_transfer_fifo.sv
CPP_X87_FIFO_SRCS := sim_main_x87_transfer_fifo.cpp

# PLA4 verification testbench sources
TB_PLA4_SRCS := tb_protection_pla4.sv
CPP_PLA4_SRCS := sim_main_pla4.cpp
PLA4_RTL := $(Z486_DIR)/protection.sv

# Targets
.PHONY: all build test-simple test-full test-386 test-186 test-protected test-pla4 test-l1-cache test-l1-icache test-memory-order test-cache-coherence test-load-waw test-gpr-hazard test-gpr-merge test-memmap-template check-reset-lists check-pragmas check-rom-columns check-shift-ucode test-interrupt-nmi test-paging-walker test-paging-tlb test-cache-flush test-x87-bridge test-x87-sequencer test-x87-executor test-x87-testfloat test-x87-fifo test-x87-core test-x87-integration test-x87-integer dhrystone clean help

.PHONY: check-equiv test-release test-pc98-map test-fuzz-pc98 dhrystone-pc98 test-protected-narrow check-generators test-data-access check-runner test-l1-tags-wide test-reset-restart test-reset-dtr test-fuzz
.PHONY: test-bigmem test-addr-unit-reloc test-reset-sweep test-pc98-map-bus test-mem-resp test-protected-throttled
.PHONY: test-protected-zero-wait test-fuzz-zero-wait
.PHONY: test-throttle-rate test-throttle-invariance test-fuzz-throttle test-throttle-sweep

all: build

# The local release gate is deliberately serial: several Verilator targets
# share obj_dir and compile common support objects with different trace flags.
# External SingleStepTests/test386 and vendor timing are separate requirements.
test-release:
	$(MAKE) -j1 check-reset-lists check-pragmas check-rom-columns check-shift-ucode check-generators check-runner check-equiv
	$(MAKE) -j1 test-l1-cache test-l1-icache test-memory-order test-mem-resp test-load-waw test-gpr-merge test-gpr-hazard test-data-access test-memmap-template test-interrupt-nmi test-paging-walker test-paging-tlb test-cache-flush test-cache-coherence test-reset-restart test-reset-dtr
	$(MAKE) -j1 test-addr-unit-reloc test-reset-sweep test-pc98-map-bus
	$(MAKE) -j1 test-protected test-protected-narrow test-protected-zero-wait test-protected-throttled test-throttle-rate test-throttle-invariance test-fuzz-throttle test-fuzz-zero-wait test-simple test-pc98-map test-fuzz-pc98 test-bigmem test-l1-tags-wide test-fuzz
	$(MAKE) -j1 obj_dir_x87/Vtb_protected_mode
	Z486_ENABLE_X87=1 Z486_TESTBENCH=$(CURDIR)/obj_dir_x87/Vtb_protected_mode ./test_protected_mode.py --strict
	$(MAKE) -j1 dhrystone dhrystone-pc98

check-runner:
	python3 test_runner_contract.py

# Combinational SAT proofs for zero-cycle rewrites (tests/equiv/), each with a
# planted mutant that must be refuted.  Needs yosys.
check-equiv:
	python3 check_equiv.py

# Seeded differential stress of the integer pipeline (self-checking programs,
# three memory latencies each).  FUZZ_COUNT=200 for a longer soak.
FUZZ_COUNT ?= 12
test-fuzz: obj_dir/Vtb_protected_mode
	python3 ./fuzz_gpr_pipeline.py --count $(FUZZ_COUNT)

check-generators:
	python3 $(Z486_DIR)/scripts/ucode_optimize.py --check
	VERILATOR=$(VERILATOR) JOBS=$(JOBS) python3 check_pla_image.py

# Build all testbenches
build: obj_dir/Vtb_z486 obj_dir/Vtb_protected_mode

obj_dir/Vtb_z486: $(RTL_SRCS) $(RTL_DEPS) $(TB_SRCS) $(CPP_SRCS)
	@echo "Building z486 testbench with Verilator..."
	cp -f ../*.hex .
	$(VERILATOR) $(VFLAGS) --top-module tb_z486 $(TB_SRCS) $(RTL_SRCS) $(CPP_SRCS)
	@echo "Build complete: obj_dir/Vtb_z486"

obj_dir/Vtb_protected_mode: $(RTL_SRCS) $(RTL_DEPS) $(TB_PROT_SRCS) $(TB_PROT_DEPS) $(CPP_PROT_SRCS)
	@echo "Building protected mode testbench with Verilator..."
	cp -f ../*.hex .
	$(VERILATOR) $(VFLAGS) --top-module tb_protected_mode $(TB_PROT_SRCS) $(RTL_SRCS) $(CPP_PROT_SRCS)
	@echo "Build complete: obj_dir/Vtb_protected_mode"

obj_dir_pc98/Vtb_protected_mode: $(RTL_SRCS) $(RTL_DEPS) $(TB_PROT_SRCS) $(TB_PROT_DEPS) $(CPP_PROT_SRCS)
	cp -f ../*.hex .
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_pc98 -GPC98_MAP=1 -GMEM_SIZE=1048576 --top-module tb_protected_mode \
		$(TB_PROT_SRCS) $(RTL_SRCS) $(CPP_PROT_SRCS)

# 4 MiB of bench memory, so a line above 1 MiB has its own backing and an A20
# change is visible in the data (the 512 KiB benches wrap 0x100000 onto 0).
obj_dir_bigmem/Vtb_protected_mode: $(RTL_SRCS) $(RTL_DEPS) $(TB_PROT_SRCS) $(TB_PROT_DEPS) $(CPP_PROT_SRCS)
	cp -f ../*.hex .
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_bigmem -GMEM_SIZE=4194304 --top-module tb_protected_mode \
		$(TB_PROT_SRCS) $(RTL_SRCS) $(CPP_PROT_SRCS)

obj_dir_x87/Vtb_protected_mode: $(RTL_SRCS) $(RTL_DEPS) $(TB_PROT_SRCS) $(TB_PROT_DEPS) $(CPP_PROT_SRCS)
	@echo "Building x87-enabled protected mode testbench with Verilator..."
	cp -f ../*.hex .
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_x87 -GENABLE_X87=1 --top-module tb_protected_mode \
		$(TB_PROT_SRCS) $(RTL_SRCS) $(CPP_PROT_SRCS)
	@echo "Build complete: obj_dir_x87/Vtb_protected_mode"

obj_dir_quake/Vtb_protected_mode: $(RTL_SRCS) $(RTL_DEPS) $(TB_PROT_SRCS) $(TB_PROT_DEPS) $(CPP_QUAKE_SNAPSHOT_SRCS)
	@echo "Building 64MB workload snapshot replay..."
	cp -f ../*.hex .
	$(VERILATOR) $(VFLAGS_NOTRACE) --Mdir obj_dir_quake \
		-GENABLE_X87=1 -GMEM_SIZE=67108864 --top-module tb_protected_mode \
		$(TB_PROT_SRCS) $(RTL_SRCS) $(CPP_QUAKE_SNAPSHOT_SRCS)
	@echo "Build complete: obj_dir_quake/Vtb_protected_mode"

obj_dir_quake_trace/Vtb_protected_mode: $(RTL_SRCS) $(RTL_DEPS) $(TB_PROT_SRCS) $(TB_PROT_DEPS) $(CPP_QUAKE_SNAPSHOT_SRCS)
	@echo "Building trace-enabled 64MB workload snapshot replay..."
	cp -f ../*.hex .
	$(VERILATOR) $(VFLAGS_FST) --Mdir obj_dir_quake_trace \
		-GENABLE_X87=1 -GMEM_SIZE=67108864 --top-module tb_protected_mode \
		$(TB_PROT_SRCS) $(RTL_SRCS) $(CPP_QUAKE_SNAPSHOT_SRCS)
	@echo "Build complete: obj_dir_quake_trace/Vtb_protected_mode"

obj_dir_x87_int/Vtb_z486: $(RTL_SRCS) $(RTL_DEPS) $(TB_SRCS) $(CPP_SRCS)
	@echo "Building x87-enabled integer testbench with Verilator..."
	cp -f ../*.hex .
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_x87_int -GENABLE_X87=1 --top-module tb_z486 \
		$(TB_SRCS) $(RTL_SRCS) $(CPP_SRCS)
	@echo "Build complete: obj_dir_x87_int/Vtb_z486"

obj_dir/Vtb_test386: $(RTL_SRCS) $(RTL_DEPS) $(TB386_SRCS) $(CPP386_SRCS)
	@echo "Building test386 testbench with Verilator..."
	cp -f ../*.hex .
	$(VERILATOR) $(VFLAGS_FST) --top-module tb_test386 $(TB386_SRCS) $(RTL_SRCS) $(CPP386_SRCS)
	@echo "Build complete: obj_dir/Vtb_test386"

obj_dir/Vtb_l1_cache: $(Z486_DIR)/z486_platform.svh $(Z486_DIR)/l1_cache.sv $(TB_L1_SRCS) $(CPP_L1_SRCS)
	@echo "Building L1 cache unit test with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --top-module tb_l1_cache $(TB_L1_SRCS) $(Z486_DIR)/l1_cache.sv $(CPP_L1_SRCS)
	@echo "Build complete: obj_dir/Vtb_l1_cache"

obj_dir/Vtb_l1_icache: $(Z486_DIR)/z486_platform.svh $(Z486_DIR)/l1_icache.sv $(TB_L1I_SRCS) $(CPP_L1I_SRCS)
	@echo "Building L1 instruction cache unit test with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --top-module tb_l1_icache $(TB_L1I_SRCS) $(Z486_DIR)/l1_icache.sv $(CPP_L1I_SRCS)
	@echo "Build complete: obj_dir/Vtb_l1_icache"

obj_dir_tags32/Vtb_l1_cache: $(Z486_DIR)/l1_cache.sv $(Z486_DIR)/z486_platform.svh $(TB_L1_SRCS) $(CPP_L1_SRCS)
	$(VERILATOR) $(VFLAGS_NOTRACE) -DZ486_L1_PHYS_ADDR_BITS=32 --Mdir obj_dir_tags32 --top-module tb_l1_cache \
		$(TB_L1_SRCS) $(Z486_DIR)/l1_cache.sv $(CPP_L1_SRCS)

obj_dir_tags32/Vtb_l1_icache: $(Z486_DIR)/l1_icache.sv $(Z486_DIR)/z486_platform.svh $(TB_L1I_SRCS) $(CPP_L1I_SRCS)
	$(VERILATOR) $(VFLAGS_NOTRACE) -DZ486_L1_PHYS_ADDR_BITS=32 --Mdir obj_dir_tags32 --top-module tb_l1_icache \
		$(TB_L1I_SRCS) $(Z486_DIR)/l1_icache.sv $(CPP_L1I_SRCS)

test-l1-tags-wide: obj_dir_tags32/Vtb_l1_cache obj_dir_tags32/Vtb_l1_icache
	./obj_dir_tags32/Vtb_l1_cache
	./obj_dir_tags32/Vtb_l1_icache

obj_dir/Vtb_memory_order: $(Z486_DIR)/z486_cache_map_pkg.sv $(Z486_DIR)/z486_pkg.sv $(RTL_DEPS) $(Z486_DIR)/memory.sv $(Z486_DIR)/bus_unit.sv $(Z486_DIR)/cache_unit.sv $(Z486_DIR)/l1_cache.sv $(Z486_DIR)/l1_icache.sv $(TB_MEMORY_ORDER_SRCS) $(CPP_MEMORY_ORDER_SRCS)
	@echo "Building memory ordering unit test with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --top-module tb_memory_order $(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/z486_cache_map_pkg.sv $(TB_MEMORY_ORDER_SRCS) \
		$(Z486_DIR)/memory.sv $(Z486_DIR)/bus_unit.sv $(Z486_DIR)/cache_unit.sv $(Z486_DIR)/l1_cache.sv $(Z486_DIR)/l1_icache.sv $(CPP_MEMORY_ORDER_SRCS)
	@echo "Build complete: obj_dir/Vtb_memory_order"

obj_dir/Vtb_cache_coherence: $(Z486_DIR)/z486_cache_map_pkg.sv $(Z486_DIR)/z486_pkg.sv $(RTL_DEPS) $(Z486_DIR)/memory.sv $(Z486_DIR)/bus_unit.sv $(Z486_DIR)/cache_unit.sv $(Z486_DIR)/l1_cache.sv $(Z486_DIR)/l1_icache.sv $(TB_CACHE_COHERENCE_SRCS) $(CPP_CACHE_COHERENCE_SRCS)
	@echo "Building I-cache store/DMA coherence bench with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --top-module tb_cache_coherence $(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/z486_cache_map_pkg.sv $(TB_CACHE_COHERENCE_SRCS) \
		$(Z486_DIR)/memory.sv $(Z486_DIR)/bus_unit.sv $(Z486_DIR)/cache_unit.sv $(Z486_DIR)/l1_cache.sv $(Z486_DIR)/l1_icache.sv $(CPP_CACHE_COHERENCE_SRCS)
	@echo "Build complete: obj_dir/Vtb_cache_coherence"

obj_dir/Vtb_load_waw: $(Z486_DIR)/z486_pkg.sv $(LOAD_WAW_RTL) $(TB_LOAD_WAW_SRCS) $(CPP_LOAD_WAW_SRCS)
	@echo "Building same-cycle load write-arbitration unit test with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --top-module tb_load_waw $(TB_LOAD_WAW_SRCS) \
		$(Z486_DIR)/z486_pkg.sv $(LOAD_WAW_RTL) $(CPP_LOAD_WAW_SRCS)
	@echo "Build complete: obj_dir/Vtb_load_waw"

obj_dir/Vtb_gpr_hazard: $(Z486_DIR)/z486_pkg.sv $(LOAD_WAW_RTL) $(TB_GPR_HAZARD_SRCS) $(CPP_GPR_HAZARD_SRCS)
	@echo "Building GPR hazard survey bench with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --top-module tb_gpr_hazard $(TB_GPR_HAZARD_SRCS) \
		$(Z486_DIR)/z486_pkg.sv $(LOAD_WAW_RTL) $(CPP_GPR_HAZARD_SRCS)
	@echo "Build complete: obj_dir/Vtb_gpr_hazard"

obj_dir/Vtb_gpr_write_merge: $(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/gpr_write_merge.sv $(TB_GPR_MERGE_SRCS) $(CPP_GPR_MERGE_SRCS)
	@echo "Building GPR write-merge unit bench with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --top-module tb_gpr_write_merge $(TB_GPR_MERGE_SRCS) \
		$(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/gpr_write_merge.sv $(CPP_GPR_MERGE_SRCS)
	@echo "Build complete: obj_dir/Vtb_gpr_write_merge"

obj_dir/Vtb_memmap_template: $(Z486_DIR)/z486_cache_map_pkg.sv $(Z486_DIR)/z486_pc98_preset.svh $(TB_MEMMAP_SRCS) $(CPP_MEMMAP_SRCS)
	@echo "Building memory-map template unit test with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --top-module tb_memmap_template \
		$(Z486_DIR)/z486_cache_map_pkg.sv $(TB_MEMMAP_SRCS) $(CPP_MEMMAP_SRCS)
	@echo "Build complete: obj_dir/Vtb_memmap_template"

obj_dir/Vtb_interrupt_nmi: $(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/interrupt_controller.sv $(TB_INTERRUPT_NMI_SRCS)
	@echo "Building interrupt-controller NMI bench with Verilator..."
	$(VERILATOR) --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-SYNCASYNCNET \
		--binary -O3 -j $(JOBS) -I$(Z486_DIR) \
		-CFLAGS "-std=c++14 -O3" --top-module tb_interrupt_nmi \
		$(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/interrupt_controller.sv \
		$(TB_INTERRUPT_NMI_SRCS)
	@echo "Build complete: obj_dir/Vtb_interrupt_nmi"

obj_dir/Vtb_paging_tlb_lru: $(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/z486_cache_map_pkg.sv $(Z486_DIR)/paging_tlb.sv $(TB_PAGING_TLB_SRCS)
	@echo "Building paging TLB replacement bench with Verilator..."
	$(VERILATOR) --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-SYNCASYNCNET \
		--binary -O3 -j $(JOBS) -I$(Z486_DIR) \
		-CFLAGS "-std=c++14 -O3" --top-module tb_paging_tlb_lru \
		$(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/z486_cache_map_pkg.sv $(Z486_DIR)/paging_tlb.sv \
		$(TB_PAGING_TLB_SRCS)
	@echo "Build complete: obj_dir/Vtb_paging_tlb_lru"

obj_dir/Vtb_mem_resp: $(Z486_DIR)/z486_cache_map_pkg.sv $(Z486_DIR)/z486_pkg.sv $(RTL_DEPS) $(Z486_DIR)/memory.sv $(Z486_DIR)/bus_unit.sv $(Z486_DIR)/cache_unit.sv $(Z486_DIR)/l1_cache.sv $(Z486_DIR)/l1_icache.sv $(TB_MEM_RESP_SRCS)
	@echo "Building external-bus response-timing bench with Verilator..."
	$(VERILATOR) --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-SYNCASYNCNET \
		--binary -O3 -j $(JOBS) -I$(Z486_DIR) \
		-CFLAGS "-std=c++14 -O3" --top-module tb_mem_resp \
		$(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/z486_cache_map_pkg.sv $(TB_MEM_RESP_SRCS) \
		$(Z486_DIR)/memory.sv $(Z486_DIR)/bus_unit.sv $(Z486_DIR)/cache_unit.sv $(Z486_DIR)/l1_cache.sv $(Z486_DIR)/l1_icache.sv
	@echo "Build complete: obj_dir/Vtb_mem_resp"

obj_dir/Vtb_paging_walker: $(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/paging_walker.sv $(TB_PAGING_WALKER_SRCS)
	@echo "Building page-walker A/D write-back bench with Verilator..."
	$(VERILATOR) --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-SYNCASYNCNET \
		--binary -O3 -j $(JOBS) -I$(Z486_DIR) \
		-CFLAGS "-std=c++14 -O3" --top-module tb_paging_walker \
		$(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/paging_walker.sv \
		$(TB_PAGING_WALKER_SRCS)
	@echo "Build complete: obj_dir/Vtb_paging_walker"

obj_dir/Vtb_cache_flush: $(RTL_SRCS) $(RTL_DEPS) $(TB_CACHE_FLUSH_SRCS)
	@echo "Building cache-flush controller bench with Verilator..."
	$(VERILATOR) --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-SYNCASYNCNET \
		--binary -O3 -j $(JOBS) -I$(Z486_DIR) -I$(X87_DIR) -I$(X87_REF_DIR) \
		-CFLAGS "-std=c++14 -O3" --top-module tb_cache_flush \
		$(RTL_SRCS) $(TB_CACHE_FLUSH_SRCS)
	@echo "Build complete: obj_dir/Vtb_cache_flush"

obj_dir/Vtb_reset_restart: $(RTL_SRCS) $(RTL_DEPS) tb_reset_restart.sv
	cp -f ../*.hex .
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-UNOPTFLAT -j $(JOBS) -I$(Z486_DIR) -I$(X87_DIR) \
		--top-module tb_reset_restart $(RTL_SRCS) tb_reset_restart.sv

test-reset-restart: obj_dir/Vtb_reset_restart
	./obj_dir/Vtb_reset_restart

# SIDT/SGDT as the first instructions after reset: the reset IDTR and GDTR.
obj_dir/Vtb_reset_dtr: $(RTL_SRCS) $(RTL_DEPS) tb_reset_dtr.sv
	cp -f ../*.hex .
	$(VERILATOR) --binary --timing -Wno-fatal -Wno-UNOPTFLAT -j $(JOBS) -I$(Z486_DIR) -I$(X87_DIR) \
		--top-module tb_reset_dtr $(RTL_SRCS) tb_reset_dtr.sv

test-reset-dtr: obj_dir/Vtb_reset_dtr
	./obj_dir/Vtb_reset_dtr

# address_unit's relocation outputs and captures against independent arithmetic
# (random stimulus, the 16-bit offset wraps included).
obj_dir/Vtb_addr_unit_reloc_equiv: $(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/address_unit.sv $(TB_ADDR_UNIT_RELOC_SRCS)
	@echo "Building address_unit relocation equivalence bench with Verilator..."
	$(VERILATOR) --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-SYNCASYNCNET \
		--binary -O3 -j $(JOBS) -I$(Z486_DIR) \
		-CFLAGS "-std=c++14 -O3" --top-module tb_addr_unit_reloc_equiv \
		$(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/address_unit.sv \
		$(TB_ADDR_UNIT_RELOC_SRCS)
	@echo "Build complete: obj_dir/Vtb_addr_unit_reloc_equiv"

test-addr-unit-reloc: obj_dir/Vtb_addr_unit_reloc_equiv
	@echo "Running address_unit relocation equivalence bench..."
	@./obj_dir/Vtb_addr_unit_reloc_equiv | tee obj_dir/z486_addr_unit_reloc_equiv.out \
		| grep -q "TB_ADDR_UNIT_RELOC_EQUIV: PASS" \
		|| (echo "address_unit relocation equivalence bench FAIL"; exit 1)

# A one-cycle reset at every offset through a short program must restart from
# the reset vector and reach the same result.  A private --Mdir keeps this
# bench's -DVL_USER_STOP/-DVL_USER_FATAL verilated.o (mid-reset sim-check trips
# are tolerated; the sweep's own verdict decides) out of the shared obj_dir.
obj_dir_reset_sweep/Vtb_reset_sweep: $(RTL_SRCS) $(RTL_DEPS) $(TB_RESET_SWEEP_SRCS) $(CPP_RESET_SWEEP_SRCS)
	@echo "Building reset-at-cycle sweep bench with Verilator..."
	cp -f ../*.hex .
	$(VERILATOR) --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-SYNCASYNCNET \
		-O3 -j $(JOBS) -I$(Z486_DIR) -I$(X87_DIR) -I$(X87_REF_DIR) \
		--Mdir obj_dir_reset_sweep --top-module tb_reset_sweep --cc --exe --build \
		-CFLAGS "-std=c++14 -O3 -DVL_USER_STOP -DVL_USER_FATAL" \
		$(TB_RESET_SWEEP_SRCS) $(CPP_RESET_SWEEP_SRCS) $(RTL_SRCS)
	@echo "Build complete: obj_dir_reset_sweep/Vtb_reset_sweep"

test-reset-sweep: obj_dir_reset_sweep/Vtb_reset_sweep
	@echo "Running reset-at-cycle sweep bench..."
	@./obj_dir_reset_sweep/Vtb_reset_sweep > obj_dir_reset_sweep/z486_reset_sweep.out 2>&1 || true
	@grep -v -e '%Fatal' -e 'Verilog $$stop' -e '%Warning: ignoring' \
		obj_dir_reset_sweep/z486_reset_sweep.out
	@grep -q "TB_RESET_SWEEP: PASS" obj_dir_reset_sweep/z486_reset_sweep.out \
		|| (echo "reset-at-cycle sweep FAIL"; exit 1)

# Full-core PC-98 map at the external port: each window's line-fill vs
# single-beat shape, DIRECT-write I$ invalidation (launch pulse, snoop
# collision slot) and DIRECT SMC, with immediate and delayed write acceptance.
obj_dir/Vtb_pc98_map: $(RTL_SRCS) $(RTL_DEPS) $(Z486_DIR)/z486_pc98_preset.svh $(TB_PC98_MAP_SRCS) $(CPP_PC98_MAP_SRCS)
	@echo "Building full-core PC-98 memory-map port bench with Verilator..."
	cp -f ../*.hex .
	$(VERILATOR) $(VFLAGS_NOTRACE) --top-module tb_pc98_map \
		$(TB_PC98_MAP_SRCS) $(RTL_SRCS) $(CPP_PC98_MAP_SRCS)
	@echo "Build complete: obj_dir/Vtb_pc98_map"

test-pc98-map-bus: obj_dir/Vtb_pc98_map
	@echo "Running PC-98 map port bench (immediate, then five-cycle-delayed write accept)..."
	@./obj_dir/Vtb_pc98_map > obj_dir/z486_pc98_map.out 2>&1 \
		&& grep -q "PC98 MAP TEST PASS" obj_dir/z486_pc98_map.out \
		|| (tail -n 30 obj_dir/z486_pc98_map.out; exit 1)
	@./obj_dir/Vtb_pc98_map +write_wait=5 > obj_dir/z486_pc98_map_wait.out 2>&1 \
		&& grep -q "PC98 MAP TEST PASS" obj_dir/z486_pc98_map_wait.out \
		|| (tail -n 30 obj_dir/z486_pc98_map_wait.out; exit 1)

obj_dir/Vtb_x87_bridge: $(X87_DIR)/x87_bridge.sv $(TB_X87_BRIDGE_SRCS) $(CPP_X87_BRIDGE_SRCS)
	@echo "Building x87 bridge unit test with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --top-module tb_x87_bridge $(TB_X87_BRIDGE_SRCS) $(X87_DIR)/x87_bridge.sv $(CPP_X87_BRIDGE_SRCS)
	@echo "Build complete: obj_dir/Vtb_x87_bridge"

$(X87_UCODE_GEN): $(X87_DIR)/build_x87_microcode.py
	cd $(X87_DIR) && ./build_x87_microcode.py

$(X87_COMMAND_GEN): $(X87_DIR)/build_x87_command_decode.py
	cd $(X87_DIR) && ./build_x87_command_decode.py

$(X87_LOGEXP_GEN): $(X87_DIR)/build_x87_logexp_tables.py
	cd $(X87_DIR) && ./build_x87_logexp_tables.py

obj_dir/Vtb_x87_sequencer: $(X87_DIR)/x87_ucode.svh $(X87_DIR)/x87_entries.svh \
		$(X87_DIR)/x87_ucode_pkg.sv $(X87_DIR)/x87_ucode_rom.sv \
		$(X87_DIR)/x87_sequencer.sv $(TB_X87_SEQ_SRCS) $(CPP_X87_SEQ_SRCS)
	@echo "Building x87 sequencer unit test with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --top-module tb_x87_sequencer \
		$(X87_DIR)/x87_ucode_pkg.sv $(TB_X87_SEQ_SRCS) \
		$(X87_DIR)/x87_ucode_rom.sv $(X87_DIR)/x87_sequencer.sv \
		$(CPP_X87_SEQ_SRCS)
	@echo "Build complete: obj_dir/Vtb_x87_sequencer"

obj_dir/Vtb_x87_executor: $(X87_DIR)/x87_ucode.svh $(X87_DIR)/x87_entries.svh \
		$(X87_DIR)/x87_pkg.sv $(X87_REF_DIR)/x87_roundint.sv \
		$(X87_REF_DIR)/x87_addsub.sv $(X87_REF_DIR)/x87_mul.sv \
		$(X87_REF_DIR)/x87_divsqrt.sv $(X87_DIR)/x87_cordic_rom.sv \
		$(X87_REF_DIR)/x87_cordic_atan_q80.svh \
		$(X87_REF_DIR)/x87_trans.sv \
		$(X87_DIR)/x87_ucode_pkg.sv $(X87_DIR)/x87_ucode_rom.sv \
		$(X87_DIR)/x87_sequencer.sv $(X87_DIR)/x87_executor.sv \
		$(X87_DIR)/x87_cordic_scratch.sv \
		$(TB_X87_EXECUTOR_SRCS) $(CPP_X87_EXECUTOR_SRCS)
	@echo "Building x87 executor unit test with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --top-module tb_x87_executor \
		$(X87_DIR)/x87_pkg.sv $(X87_DIR)/x87_ucode_pkg.sv \
		$(TB_X87_EXECUTOR_SRCS) $(X87_REF_DIR)/x87_roundint.sv \
		$(X87_REF_DIR)/x87_addsub.sv $(X87_REF_DIR)/x87_mul.sv \
		$(X87_REF_DIR)/x87_divsqrt.sv $(X87_DIR)/x87_cordic_rom.sv \
		$(X87_DIR)/x87_cordic_scratch.sv \
		$(X87_REF_DIR)/x87_trans.sv \
		$(X87_DIR)/x87_ucode_rom.sv $(X87_DIR)/x87_sequencer.sv \
		$(X87_DIR)/x87_executor.sv $(CPP_X87_EXECUTOR_SRCS)
	@echo "Build complete: obj_dir/Vtb_x87_executor"

obj_dir_x87_testfloat/Vtb_x87_testfloat: \
		$(X87_DIR)/x87_ucode.svh $(X87_DIR)/x87_entries.svh \
		$(X87_DIR)/x87_pkg.sv $(X87_DIR)/x87_cordic_rom.sv \
		$(X87_DIR)/x87_cordic_scratch.sv \
		$(X87_DIR)/x87_ucode_pkg.sv $(X87_DIR)/x87_ucode_rom.sv \
		$(X87_DIR)/x87_sequencer.sv $(X87_DIR)/x87_executor.sv \
		$(TB_X87_TESTFLOAT_SRCS) $(CPP_X87_TESTFLOAT_SRCS)
	@echo "Building x87 TestFloat testbench with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --Mdir obj_dir_x87_testfloat \
		--top-module tb_x87_testfloat \
		$(X87_DIR)/x87_pkg.sv $(X87_DIR)/x87_ucode_pkg.sv \
		$(TB_X87_TESTFLOAT_SRCS) $(X87_DIR)/x87_cordic_rom.sv \
		$(X87_DIR)/x87_cordic_scratch.sv \
		$(X87_DIR)/x87_ucode_rom.sv $(X87_DIR)/x87_sequencer.sv \
		$(X87_DIR)/x87_executor.sv $(CPP_X87_TESTFLOAT_SRCS)
	@echo "Build complete: obj_dir_x87_testfloat/Vtb_x87_testfloat"

obj_dir_x87_core/Vtb_x87_core: $(X87_DIR)/x87_ucode.svh \
		$(X87_DIR)/x87_entries.svh $(X87_DIR)/x87_pkg.sv \
		$(X87_DIR)/x87_cordic_rom.sv \
		$(X87_DIR)/x87_cordic_scratch.sv $(X87_DIR)/x87_ucode_pkg.sv \
		$(X87_DIR)/x87_ucode_rom.sv $(X87_DIR)/x87_sequencer.sv \
		$(X87_DIR)/x87_executor.sv \
		$(X87_DIR)/x87_transfer_fifo.sv \
		$(X87_DIR)/x87_stack_mem.sv \
		$(X87_DIR)/x87_command_rom.sv \
		$(X87_DIR)/x87_logexp_rom.sv \
		$(X87_DIR)/x87_control.sv $(TB_X87_CORE_SRCS) \
		$(CPP_X87_CORE_SRCS)
	@echo "Building x87 core unit test with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --Mdir obj_dir_x87_core \
		--top-module tb_x87_core $(TB_X87_CORE_SRCS) \
		$(X87_DIR)/x87_pkg.sv $(X87_DIR)/x87_cordic_rom.sv \
		$(X87_DIR)/x87_cordic_scratch.sv \
		$(X87_DIR)/x87_ucode_pkg.sv $(X87_DIR)/x87_ucode_rom.sv \
		$(X87_DIR)/x87_sequencer.sv $(X87_DIR)/x87_executor.sv \
		$(X87_DIR)/x87_transfer_fifo.sv \
		$(X87_DIR)/x87_stack_mem.sv $(X87_DIR)/x87_command_rom.sv \
		$(X87_DIR)/x87_control.sv \
		$(CPP_X87_CORE_SRCS)
	@echo "Build complete: obj_dir_x87_core/Vtb_x87_core"

obj_dir_x87_fifo/Vtb_x87_transfer_fifo: \
		$(X87_DIR)/x87_transfer_fifo.sv $(TB_X87_FIFO_SRCS) \
		$(CPP_X87_FIFO_SRCS)
	@echo "Building x87 transfer FIFO unit test with Verilator..."
	$(VERILATOR) $(VFLAGS_NOTRACE) --Mdir obj_dir_x87_fifo \
		--top-module tb_x87_transfer_fifo $(TB_X87_FIFO_SRCS) \
		$(X87_DIR)/x87_transfer_fifo.sv $(CPP_X87_FIFO_SRCS)
	@echo "Build complete: obj_dir_x87_fifo/Vtb_x87_transfer_fifo"

test: test-simple

# Run tests
test-simple: build
	@echo "Running z486 simple instruction tests..."
	./test_simple.py

test-full: build
	@echo "Running external single-step reference tests (prepare.sh installs datasets)..."
	./test_singlestep_real.py --limit 0 --no-color
	./test_singlestep_protected.py -n 0 -nt

test-protected: obj_dir/Vtb_protected_mode
	@echo "Running protected mode tests..."
	./test_protected_mode.py --strict

test-protected-narrow: obj_dir/Vtb_protected_mode
	SIM_PLUSARGS=+no_line_fill ./test_protected_mode.py --strict

# A demand read answered in the very cycle valid rises (ready and the first data
# beat together).  z486's bus contract allows it; the default memory model never
# does it, and a wedge in paging_unit hid there.
test-protected-zero-wait: obj_dir/Vtb_protected_mode
	SIM_PLUSARGS=+zero_wait ./test_protected_mode.py --strict
	SIM_PLUSARGS="+zero_wait +no_line_fill" ./test_protected_mode.py --strict

# A throttled CPU is the same CPU seeing fewer clock edges (docs/throttle.md):
# the whole suite at each throttle setting, the memory and I/O at full rate.
# The runner scales cycle budgets and skips the programs that time themselves.
THROTTLE_SELS ?= 3 7
test-protected-throttled: obj_dir/Vtb_protected_mode
	for s in $(THROTTLE_SELS); do SIM_PLUSARGS=+cpu_speed=$$s ./test_protected_mode.py --strict; done

# The fuzzers with the memory answering in the accept cycle (FUZZ_EXTRA is
# appended to every run's plusargs).
test-fuzz-zero-wait: obj_dir/Vtb_protected_mode
	FUZZ_EXTRA=+zero_wait python3 ./hazard/fuzz_hazard.py --count $(FUZZ_THROTTLE_COUNT) --jobs $(JOBS)
	FUZZ_EXTRA=+zero_wait python3 ./hazard/fuzz_hazard_v86.py --count $(FUZZ_THROTTLE_COUNT) --jobs $(JOBS)
	FUZZ_EXTRA=+zero_wait python3 ./hazard/fuzz_hazard_emm.py --count $(FUZZ_THROTTLE_COUNT) --jobs $(JOBS)
	SIM_PLUSARGS=+zero_wait python3 ./fuzz_gpr_pipeline.py --count $(FUZZ_COUNT)

# Throttled time is the requested time, a REP STOSD included.
test-throttle-rate: obj_dir/Vtb_protected_mode
	./test_throttle_rate.py

# Every program's architectural result is identical to full speed at each
# (throttle setting, memory latency).
INVARIANCE_LATS ?= 1 9
test-throttle-invariance: obj_dir/Vtb_protected_mode
	./test_throttle_invariance.py --jobs $(JOBS) --sel $(THROTTLE_SELS) --lat $(INVARIANCE_LATS)

# The fuzzers with throttle variants against the full-speed reference.
FUZZ_THROTTLE ?= 3 9
FUZZ_THROTTLE_COUNT ?= 4
test-fuzz-throttle: obj_dir/Vtb_protected_mode
	FUZZ_THROTTLE="$(FUZZ_THROTTLE)" python3 ./hazard/fuzz_hazard.py --count $(FUZZ_THROTTLE_COUNT) --jobs $(JOBS)
	FUZZ_THROTTLE="$(FUZZ_THROTTLE)" python3 ./hazard/fuzz_hazard_v86.py --count $(FUZZ_THROTTLE_COUNT) --jobs $(JOBS)
	FUZZ_THROTTLE="$(FUZZ_THROTTLE)" python3 ./hazard/fuzz_hazard_emm.py --count $(FUZZ_THROTTLE_COUNT) --jobs $(JOBS)
	for s in $(FUZZ_THROTTLE); do SIM_PLUSARGS=+cpu_speed=$$s python3 ./fuzz_gpr_pipeline.py --count $(FUZZ_THROTTLE_COUNT); done

# Volume run (not in test-release; run it on a big host): the suite and the
# invariance bench over SWEEP_SELS x SWEEP_LATS, then the fuzzers over SWEEP_COUNT
# seeds at every setting.  SWEEP_FIRST offsets the fuzz seeds between runs.
SWEEP_SELS ?= 1 2 3 4 5 6 7 8 9 10 11 12 13
SWEEP_LATS ?= 0 1 3 9 17 32
SWEEP_COUNT ?= 200
SWEEP_FIRST ?= 1
test-throttle-sweep: obj_dir/Vtb_protected_mode
	for s in $(SWEEP_SELS); do for l in $(SWEEP_LATS); do \
	  SIM_PLUSARGS="+cpu_speed=$$s +mem_latency=$$l" ./test_protected_mode.py --strict || exit 1; done; done
	./test_throttle_invariance.py --jobs $(JOBS) --sel $(SWEEP_SELS) --lat $(SWEEP_LATS)
	FUZZ_THROTTLE="$(SWEEP_SELS)" python3 ./hazard/fuzz_hazard.py --count $(SWEEP_COUNT) --first $(SWEEP_FIRST) --jobs $(JOBS)
	FUZZ_THROTTLE="$(SWEEP_SELS)" python3 ./hazard/fuzz_hazard_v86.py --count $(SWEEP_COUNT) --first $(SWEEP_FIRST) --jobs $(JOBS)
	FUZZ_THROTTLE="$(SWEEP_SELS)" python3 ./hazard/fuzz_hazard_emm.py --count $(SWEEP_COUNT) --first $(SWEEP_FIRST) --jobs $(JOBS)

PC98_MAP_TESTS := pc98_direct_code pc98_noalloc_code hz_nonalloc_target pc98_high_alias lock_window rmw_device_reads pc98_a20_bit20 pc98_direct_read_shapes pc98_store_post pc98_store_post_win0 pc98_memwin_timing pc98_memwin_timing_nopg
test-pc98-map: obj_dir_pc98/Vtb_protected_mode
	Z486_PC98_MAP=1 Z486_TESTBENCH=$(CURDIR)/obj_dir_pc98/Vtb_protected_mode ./test_protected_mode.py --strict $(PC98_MAP_TESTS)
	SIM_PLUSARGS=+no_line_fill Z486_PC98_MAP=1 Z486_TESTBENCH=$(CURDIR)/obj_dir_pc98/Vtb_protected_mode ./test_protected_mode.py --strict $(PC98_MAP_TESTS)
	SIM_PLUSARGS=+zero_wait Z486_PC98_MAP=1 Z486_TESTBENCH=$(CURDIR)/obj_dir_pc98/Vtb_protected_mode ./test_protected_mode.py --strict $(PC98_MAP_TESTS)
	SIM_PLUSARGS="+zero_wait +no_line_fill" Z486_PC98_MAP=1 Z486_TESTBENCH=$(CURDIR)/obj_dir_pc98/Vtb_protected_mode ./test_protected_mode.py --strict $(PC98_MAP_TESTS)

# The hazard fuzzer under the PC-98 map, with a device window and window 0's
# range in its hot-window mix (FUZZ_PC98, hazard/fuzz_hazard.py): posted stores
# to RAM racing demand-path device stores, against the no-fast-path reference.
test-fuzz-pc98: obj_dir_pc98/Vtb_protected_mode
	FUZZ_PC98=1 Z486_TESTBENCH=$(CURDIR)/obj_dir_pc98/Vtb_protected_mode python3 ./hazard/fuzz_hazard.py --count $(FUZZ_PC98_COUNT) --jobs $(JOBS)
	FUZZ_PC98=1 Z486_TESTBENCH=$(CURDIR)/obj_dir_pc98/Vtb_protected_mode python3 ./hazard/fuzz_hazard.py --rmw --count $(FUZZ_PC98_COUNT) --first 1001 --jobs $(JOBS)
	FUZZ_PC98=1 FUZZ_EXTRA=+zero_wait Z486_TESTBENCH=$(CURDIR)/obj_dir_pc98/Vtb_protected_mode python3 ./hazard/fuzz_hazard.py --count $(FUZZ_PC98_COUNT) --first 2001 --jobs $(JOBS)
FUZZ_PC98_COUNT ?= 16

BIGMEM_TESTS := hz_spec_a20_rm
test-bigmem: obj_dir_bigmem/Vtb_protected_mode
	Z486_BIGMEM=1 Z486_TESTBENCH=$(CURDIR)/obj_dir_bigmem/Vtb_protected_mode ./test_protected_mode.py --strict $(BIGMEM_TESTS)
	SIM_PLUSARGS=+z486_fast_off Z486_BIGMEM=1 Z486_TESTBENCH=$(CURDIR)/obj_dir_bigmem/Vtb_protected_mode ./test_protected_mode.py --strict $(BIGMEM_TESTS)

test-386: obj_dir/Vtb_test386
	@echo "Running test386.asm..."
	./test386.py

test-l1-cache: obj_dir/Vtb_l1_cache
	@echo "Running L1 cache unit test..."
	./obj_dir/Vtb_l1_cache

test-l1-icache: obj_dir/Vtb_l1_icache
	@echo "Running L1 instruction cache unit test..."
	./obj_dir/Vtb_l1_icache

obj_dir/Vtb_data_access: $(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/data_access.sv $(RTL_DEPS) tb_data_access.sv
	$(VERILATOR) --binary --timing -Wno-fatal -j $(JOBS) -I$(Z486_DIR) --top-module tb_data_access \
		$(Z486_DIR)/z486_pkg.sv $(Z486_DIR)/data_access.sv tb_data_access.sv

test-data-access: obj_dir/Vtb_data_access
	./obj_dir/Vtb_data_access

test-memory-order: obj_dir/Vtb_memory_order
	@echo "Running device/store ordering unit test..."
	./obj_dir/Vtb_memory_order

# A read may be answered in its accept cycle, one cycle later or later still:
# a line fill and a direct read must complete with the right data in each.
test-mem-resp: obj_dir/Vtb_mem_resp
	@echo "Running external-bus response-timing bench..."
	./obj_dir/Vtb_mem_resp

# A younger direct load's write-back must win the GPR bytes it writes against
# an older hardwired load's deferred MEM token retiring in the same cycle.
test-load-waw: obj_dir/Vtb_load_waw
	@echo "Running same-cycle load write-arbitration unit test..."
	@./obj_dir/Vtb_load_waw | tee obj_dir/z486_load_waw.out | grep -q "LOAD WAW TEST PASS" \
		|| (echo "load write-arbitration test FAIL"; exit 1)

# Static checks revived from the fork: they guard the microcode/PLA images and
# the synthesis pragmas, none of which any RTL bench covers.
check-pragmas:
	@echo "Checking synthesis translate_off/translate_on balance..."
	@./check_pragmas.py $(Z486_DIR)

check-rom-columns:
	@echo "Scanning ROM images for constant (foldable) bit columns..."
	@./check_rom_columns.py $(Z486_DIR)

check-shift-ucode:
	@echo "Scanning ucode.hex for unrecognized SHIFT source pairings..."
	@./check_shift_ucode.py $(Z486_DIR)/ucode.hex

# Static audit: an always_ff that assigns state its reset branch never resets.
# Three live defects had this shape; new ones fail here.
check-reset-lists:
	@echo "Running reset-list audit..."
	@python3 test_reset_lists.py
	@python3 $(Z486_DIR)/scripts/check_reset_lists.py

# The survey's old findings were fixed; a new finding must fail the gate.
test-gpr-hazard: obj_dir/Vtb_gpr_hazard
	@./obj_dir/Vtb_gpr_hazard | tee obj_dir/z486_gpr_hazard.out
	@grep -q 'GPR HAZARD SURVEY: no hazards observed' obj_dir/z486_gpr_hazard.out

# The shared producer arbitration: one order for the commit and all views.
test-gpr-merge: obj_dir/Vtb_gpr_write_merge
	@echo "Running GPR write-merge unit bench..."
	@./obj_dir/Vtb_gpr_write_merge | tee obj_dir/z486_gpr_merge.out | grep -q "GPR WRITE MERGE TEST PASS" \
		|| (echo "GPR write-merge test FAIL"; exit 1)

test-memmap-template: obj_dir/Vtb_memmap_template
	@echo "Running memory-map template unit test..."
	./obj_dir/Vtb_memmap_template

# Proves the NMI deferred-delivery rule: an edge in the accept-to-SETNMI window
# is latched but not re-dispatched nested; CLRNMI (the IRET unmask) releases it.
test-interrupt-nmi: obj_dir/Vtb_interrupt_nmi
	@echo "Running interrupt-controller NMI deferred-delivery bench..."
	@./obj_dir/Vtb_interrupt_nmi | tee obj_dir/z486_interrupt_nmi.out \
		| grep -q "TB_INTERRUPT_NMI: PASS" \
		|| (echo "interrupt NMI bench FAIL"; exit 1)

test-paging-walker: obj_dir/Vtb_paging_walker
	@echo "Running page-walker A/D write-back bench..."
	@./obj_dir/Vtb_paging_walker | tee obj_dir/z486_paging_walker.out \
		| grep -q "PAGING WALKER TEST PASS" \
		|| (echo "page-walker A/D write-back bench FAIL"; exit 1)

test-paging-tlb: obj_dir/Vtb_paging_tlb_lru
	@echo "Running paging TLB replacement bench..."
	@./obj_dir/Vtb_paging_tlb_lru | tee obj_dir/z486_paging_tlb_lru.out \
		| grep -q "PAGING TLB TEST PASS" \
		|| (echo "paging TLB replacement bench FAIL"; exit 1)

test-cache-coherence: obj_dir/Vtb_cache_coherence
	@echo "Running I-cache store/DMA coherence bench..."
	./obj_dir/Vtb_cache_coherence

test-cache-flush: obj_dir/Vtb_cache_flush
	@echo "Running whole-L1 flush controller bench..."
	@./obj_dir/Vtb_cache_flush | tee obj_dir/z486_cache_flush.out \
		| grep -q "TB_CACHE_FLUSH: PASS" \
		|| (echo "cache-flush controller bench FAIL"; exit 1)

test-x87-bridge: obj_dir/Vtb_x87_bridge
	@echo "Running x87 bridge unit test..."
	./obj_dir/Vtb_x87_bridge

test-x87-sequencer: obj_dir/Vtb_x87_sequencer
	@echo "Running x87 sequencer unit test..."
	./obj_dir/Vtb_x87_sequencer

test-x87-executor: obj_dir/Vtb_x87_executor
	@echo "Running x87 executor unit test..."
	./obj_dir/Vtb_x87_executor

TESTFLOAT_GEN ?= $(CURDIR)/../../qemu/subprojects/berkeley-testfloat-3/build/Linux-x86_64-GCC/testfloat_gen
X87_TESTFLOAT_CASES ?= 512

test-x87-testfloat: obj_dir_x87_testfloat/Vtb_x87_testfloat
	@echo "Running x87 arithmetic against Berkeley TestFloat..."
	./run_x87_testfloat.sh "$(TESTFLOAT_GEN)" \
		./obj_dir_x87_testfloat/Vtb_x87_testfloat \
		"$(X87_TESTFLOAT_CASES)"

test-x87-fifo: obj_dir_x87_fifo/Vtb_x87_transfer_fifo
	@echo "Running x87 transfer FIFO unit test..."
	./obj_dir_x87_fifo/Vtb_x87_transfer_fifo

test-x87-core: obj_dir_x87_core/Vtb_x87_core
	@echo "Running x87 core unit test..."
	./obj_dir_x87_core/Vtb_x87_core

test-x87-integration: obj_dir_x87/Vtb_protected_mode
	@echo "Running x87-enabled CPU protocol tests..."
	Z486_ENABLE_X87=1 Z486_TESTBENCH=$(CURDIR)/obj_dir_x87/Vtb_protected_mode ./test_protected_mode.py x87_protocol x87_env32 x87_arithmetic x87_m32_page_fault x87_heap32 x87_qemu_special x87_qemu_exceptions x87_off_sx

test-x87-integer: obj_dir_x87_int/Vtb_z486
	@echo "Running integer regressions with x87 enabled..."
	Z486_TESTBENCH=$(CURDIR)/obj_dir_x87_int/Vtb_z486 ./test_simple.py --no-color
	Z486_TESTBENCH=$(CURDIR)/obj_dir_x87_int/Vtb_z486 ./test_singlestep_real.py --no-color
	Z486_TESTBENCH=$(CURDIR)/obj_dir_x87_int/Vtb_z486 ./test_singlestep_protected.py -nt

dhrystone:
	$(MAKE) -C dhrystone compare

# Dhrystone in the PC-9821 core's configuration (the PC-98 map template).
dhrystone-pc98:
	cd dhrystone && ./run_dhrystone.py --pc98-map --iters 200

# Clean build artifacts
clean:
	rm -rf obj_dir_tags32
	rm -rf obj_dir_reset_sweep
	rm -rf obj_dir_pc98
	rm -rf obj_dir_x87_testfloat
	rm -rf obj_dir_x87_fifo
	rm -rf obj_dir_x87_core
	rm -rf obj_dir_x87
	rm -rf obj_dir_x87_int
	rm -rf obj_dir
	rm -f trace.fst trace.vcd
	rm -f result.txt
	rm -f *.hex

# Help
help:
	@echo "z486 Test Makefile"
	@echo "=================="
	@echo ""
	@echo "Targets:"
	@echo "  make build          - Build all testbenches with Verilator"
	@echo "  make test-simple    - Run default test suite (~13 test files)"
	@echo "  make test-386       - Run test386.asm"
	@echo "  make test-l1-cache  - Run PIPT L1 cache unit test"
	@echo "  make test-l1-icache - Run PIPT L1 instruction cache unit test"
	@echo "  make test-memory-order - Run device/store ordering unit test"
	@echo "  make test-cache-coherence - Run I-cache store/DMA coherence unit test"
	@echo "  make test-load-waw  - Run same-cycle GPR write-arbitration unit test"
	@echo "  make test-gpr-hazard - Gate the GPR hazard survey"
	@echo "  make test-release  - Run all self-contained release gates"
	@echo "  make test-pc98-map - Execute/modify code in PC-98 DIRECT/NO_ALLOC windows"
	@echo "  make test-fuzz-pc98 - The hazard fuzzer under the PC-98 map (device windows)"
	@echo "  make dhrystone-pc98 - Dhrystone with the PC-98 map template (the core's configuration)"
	@echo "  make test-pc98-map-bus - Check each PC-98 window's external-port access shape"
	@echo "  make test-protected-throttled - The protected suite at THROTTLE_SELS (docs/throttle.md)"
	@echo "  make test-throttle-rate      - Throttled time is the requested time, REP included"
	@echo "  make test-throttle-invariance - Results identical to full speed at each throttle setting and latency"
	@echo "  make test-fuzz-throttle      - The fuzzers with throttle variants"
	@echo "  make test-throttle-sweep     - The volume run (suite, invariance, fuzzers)"
	@echo "  make test-mem-resp - Line fills and direct reads answered in, or after, their accept cycle"
	@echo "  make test-addr-unit-reloc - address_unit relocation vs independent arithmetic"
	@echo "  make test-reset-sweep - One-cycle reset at every offset through a program"
	@echo "  make check-equiv    - SAT-prove the zero-cycle rewrites in equiv/ (yosys)"
	@echo "  make check-reset-lists - Audit always_ff reset branches"
	@echo "  make test-memmap-template - Run memory-map template unit test"
	@echo "  make test-interrupt-nmi - Run interrupt-controller NMI deferred-delivery bench"
	@echo "  make test-x87-bridge - Run x87 protocol bridge unit test"
	@echo "  make test-x87-core - Run x87 state and transfer unit test"
	@echo "  make test-x87-testfloat - Check arithmetic with Berkeley TestFloat"
	@echo "  make test-x87-integration - Run x87-enabled CPU protocol test"
	@echo "  make dhrystone      - Compare released z386 and current z486 on Dhrystone"
	@echo "  make clean          - Remove build artifacts"
	@echo "  make help           - Show this help message"
