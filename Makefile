# The PC-9821 z486 core build workflow.
#
#   make build            fit the core            SEED=N pins the fitter seed
#   make bench            every unit bench        BENCH=<name> runs one
#   make pack             build the firmware pack PC98_DUMPS=/path/to/dumps
#   make deploy           provision the MiSTer    (stages mister_deploy/)
#   make base|trace|iofaithful|mediumoc|heavyoc   switch the build profile (base = 90 MHz)
#   make help

PY := python3

.DEFAULT_GOAL := help
.PHONY: help build bench pack deploy base trace iofaithful mediumoc heavyoc

help:
	@echo 'PC-9821 z486.'
	@echo '  make build                          fit the core (SEED=N pins the seed)'
	@echo '  make bench                          run the Verilator benches (BENCH=<name> runs one)'
	@echo '  make pack                           build the firmware pack (PC98_DUMPS=/path/to/dumps)'
	@echo '  make deploy                         stage the MiSTer load set into mister_deploy/'
	@echo '  make base|trace|iofaithful|mediumoc|heavyoc   switch the clk_sys build profile'
	@echo 'Run the deploy/load/run scripts under tools/ directly for the on-card workflow.'

# --- build -------------------------------------------------------------------
build:
	@$(PY) tools/build.py $(if $(SEED),--seed $(SEED))

# --- unit benches ------------------------------------------------------------
bench:
	@$(PY) tools/bench.py $(if $(BENCH),$(BENCH),--all)

# --- firmware pack (from your own dumps) --------------------------------------
pack:
	@$(PY) tools/build_pack.py $(if $(PC98_DUMPS),--dumps $(PC98_DUMPS))

# --- MiSTer deploy/load -------------------------------------------------------
deploy:
	@tools/deploy_mister.sh

# --- build profile ------------------------------------------------------------
base trace iofaithful mediumoc heavyoc:
	@$(PY) build_profile.py $@
