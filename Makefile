.PHONY: test compile compile_synth compile_synth_top synth_kernel test_mem_bridge test_synth_top \
        quartus_map quartus_compile

# Path to the Quartus bin64 directory.  Leave unset to rely on PATH, or
# override on the command line:
#   make quartus_map QUARTUS_BIN=/path/to/quartus/17.0/quartus/bin64
QUARTUS_BIN ?=
_QBIN = $(if $(QUARTUS_BIN),$(QUARTUS_BIN)/,)

export LIBPYTHON_LOC=$(shell cocotb-config --libpython)

# Default cocotb test rule (top = gpu).
# The explicit test_mem_bridge / test_synth_top rules below take precedence.
test_%:
	make compile
	iverilog -o build/sim.vvp -s gpu -g2012 build/gpu.v
	MODULE=test.test_$* vvp -M $$(cocotb-config --prefix)/cocotb/libs -m libcocotbvpi_icarus build/sim.vvp

compile:
	make compile_alu
	sv2v -I src/* -w build/gpu.v
	echo "" >> build/gpu.v
	cat build/alu.v >> build/gpu.v
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/gpu.v >> build/temp.v
	mv build/temp.v build/gpu.v

# Compile gpu + bridges + sim memories for the bridge isolation test.
compile_synth:
	make compile_alu
	sv2v -w build/synth.v src/alu.sv src/controller.sv src/dcr.sv src/decoder.sv \
		src/divergence.sv src/dispatch.sv src/fetcher.sv src/lsu.sv src/pc.sv \
		src/registers.sv src/scheduler.sv src/core.sv src/gpu.sv \
		synth/mem_bridge.sv synth/sim_program_rom.sv synth/sim_data_ram.sv \
		synth/sim_harness.sv
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/synth.v >> build/temp.v
	mv build/temp.v build/synth.v

# Compile the LabsLand synth top with the auto-generated kernel memories.
compile_synth_top:
	make compile_alu
	@if [ ! -f synth/kernel_memories.sv ]; then \
		echo "synth/kernel_memories.sv missing -- run: make synth_kernel KERNEL=<test>"; \
		exit 1; \
	fi
	sv2v -w build/synth_top.v src/alu.sv src/controller.sv src/dcr.sv src/decoder.sv \
		src/divergence.sv src/dispatch.sv src/fetcher.sv src/lsu.sv src/pc.sv \
		src/registers.sv src/scheduler.sv src/core.sv src/gpu.sv \
		synth/mem_bridge.sv synth/seg7.sv synth/clock_step.sv \
		synth/kernel_memories.sv synth/de1_soc.sv
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/synth_top.v >> build/temp.v
	mv build/temp.v build/synth_top.v

# Bridge isolation test: matadd through mem_bridge + sim memories.
test_mem_bridge:
	$(MAKE) compile_synth
	iverilog -o build/sim.vvp -s sim_harness -g2012 build/synth.v
	MODULE=test.test_mem_bridge vvp -M $$(cocotb-config --prefix)/cocotb/libs -m libcocotbvpi_icarus build/sim.vvp

# Synth-top smoke test: instantiate de1_soc with a fast SLOW_CLK_DIV so the
# divider isn't 10M cycles per gpu_clk edge. Requires the if/else kernel image
# already generated -- this rule regenerates it just in case.
test_synth_top:
	$(MAKE) synth_kernel KERNEL=test_diverge_ifelse
	$(MAKE) compile_synth_top
	iverilog -Pde1_soc.SLOW_CLK_DIV=2 -o build/sim.vvp -s de1_soc -g2012 build/synth_top.v
	MODULE=test.test_synth_top vvp -M $$(cocotb-config --prefix)/cocotb/libs -m libcocotbvpi_icarus build/sim.vvp

compile_%:
	sv2v -w build/$*.v src/$*.sv

# Generate synth/kernel_memories.sv from a chosen cocotb test's program/data.
# Usage: make synth_kernel KERNEL=test_diverge_ifelse
synth_kernel:
	@if [ -z "$(KERNEL)" ]; then \
		echo "Usage: make synth_kernel KERNEL=<test_name>"; exit 1; \
	fi
	python3 -m test.helpers.synth_init $(KERNEL)

# ---------------------------------------------------------------------------
# Local Quartus synthesis targets (requires Quartus 17 at QUARTUS_BIN).
# Project files (de1_soc.qpf, de1_soc.qsf) live in quartus/.
# Pin assignments in quartus/DE1-SoC.qsf are only needed for fit/route.
# ---------------------------------------------------------------------------

# Analysis & Synthesis only -- fast elaboration check, no place-and-route.
# Requires synth/kernel_memories.sv (run: make synth_kernel KERNEL=<test>).
quartus_map:
	@if [ ! -f synth/kernel_memories.sv ]; then \
		echo "synth/kernel_memories.sv missing -- run: make synth_kernel KERNEL=<test>"; \
		exit 1; \
	fi
	cd quartus && $(_QBIN)quartus_map de1_soc

# Full compile: A&S → fit → assemble → timing analysis.
# Fit requires pin assignments; merge DE1-SoC.qsf into the project QSF first
# or accept Quartus auto-placement (sufficient for timing/area estimates).
quartus_compile: quartus_map
	cd quartus && $(_QBIN)quartus_fit de1_soc --part=5CSEMA5F31C6
	cd quartus && $(_QBIN)quartus_asm de1_soc
	cd quartus && $(_QBIN)quartus_sta de1_soc

# TODO: Get gtkwave visualizaiton

show_%: %.vcd %.gtkw
	gtkwave $^
test_synth_debug:
	$(MAKE) compile_synth_top
	iverilog -Pde1_soc.SLOW_CLK_DIV=2 -o build/sim.vvp -s de1_soc -g2012 build/synth_top.v
	MODULE=test.test_synth_debug vvp -M $$(cocotb-config --prefix)/cocotb/libs -m libcocotbvpi_icarus build/sim.vvp
