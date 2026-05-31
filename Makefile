.PHONY: test compile compile_synth compile_synth_top synth_kernel test_line_drawer test_fb_line_engine test_recip_lut test_fb_triangle_engine test_mem_bridge test_synth_top test_synth_line_draw test_synth_spiral test_synth_triangle test_synth_debug test_synth_store test_harness_store

# Prefer repo .venv for cocotb (cocotb-config + VPI) without manually activating it.
# Use an absolute path for $(shell ...) — exported PATH is not always visible to
# GNU make's $(shell) on the same parse pass.
VENV_BIN := $(abspath .venv/bin)
ifeq ($(wildcard $(VENV_BIN)/cocotb-config),)
COCOTB_CONFIG := cocotb-config
else
COCOTB_CONFIG := $(VENV_BIN)/cocotb-config
export VIRTUAL_ENV := $(abspath .venv)
export PATH := $(VENV_BIN):$(PATH)
endif

export LIBPYTHON_LOC := $(shell $(COCOTB_CONFIG) --libpython)
# cocotb >= 2.0 dropped `--prefix` in favor of `--lib-dir`, which already
# resolves to the cocotb/libs directory containing libcocotbvpi_icarus.vpi.
COCOTB_LIB_DIR := $(shell $(COCOTB_CONFIG) --lib-dir)
# cocotb >= 2.0 embeds Python and needs an explicit interpreter binary plus
# stdlib paths so the embedded interpreter can import `encodings` etc.
export PYGPI_PYTHON_BIN := $(shell $(COCOTB_CONFIG) --python-bin)
# Build PYTHONPATH = system Python stdlib + lib-dynload + venv site-packages +
# repo root (so `test.test_*` resolves). Compute the stdlib paths from the
# active cocotb Python's own sysconfig so this works on any host (homebrew /
# system / Conda Python).
PY_STDLIB := $(shell $(PYGPI_PYTHON_BIN) -c "import sysconfig;print(sysconfig.get_paths()['stdlib'])")
PY_DYNLOAD := $(PY_STDLIB)/lib-dynload
PY_SITEPACK := $(shell $(PYGPI_PYTHON_BIN) -c "import sysconfig;print(sysconfig.get_paths()['purelib'])")
export PYTHONPATH := $(PY_STDLIB):$(PY_DYNLOAD):$(PY_SITEPACK):$(abspath .)

# Default cocotb test rule (top = gpu).
# The explicit test_mem_bridge / test_synth_top rules below take precedence.
# COCOTB_TEST_MODULES is the cocotb 2.0+ name for the old MODULE env var; we
# set both so old + new cocotb releases work without further Makefile churn.
test_%:
	make compile
	iverilog -o build/sim.vvp -s gpu -g2012 build/gpu.v
	MODULE=test.test_$* COCOTB_TEST_MODULES=test.test_$* vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp

test_line_drawer:
	iverilog -o build/sim.vvp -s line_drawer -g2012 synth/line_drawer.sv
	MODULE=test.test_line_drawer COCOTB_TEST_MODULES=test.test_line_drawer vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp

test_fb_line_engine:
	iverilog -o build/sim.vvp -s fb_line_engine -g2012 synth/line_drawer.sv synth/fb_line_engine.sv
	MODULE=test.test_fb_line_engine COCOTB_TEST_MODULES=test.test_fb_line_engine vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp

# Stage 0 gate: standalone Q16 reciprocal LUT sweep.
test_recip_lut:
	iverilog -o build/sim.vvp -s recip_lut -g2012 synth/recip_lut.sv
	MODULE=test.test_recip_lut COCOTB_TEST_MODULES=test.test_recip_lut vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp

# Stage 2 gate: standalone triangle rasterizer engine.
test_fb_triangle_engine:
	iverilog -o build/sim.vvp -s fb_triangle_engine -g2012 synth/recip_lut.sv synth/fb_triangle_engine.sv
	MODULE=test.test_fb_triangle_engine COCOTB_TEST_MODULES=test.test_fb_triangle_engine vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp

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
		synth/line_drawer.sv synth/fb_line_engine.sv \
		synth/recip_lut.sv synth/fb_triangle_engine.sv \
		synth/VGA_framebuffer.sv \
		synth/kernel_memories.sv synth/de1_soc.sv
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/synth_top.v >> build/temp.v
	mv build/temp.v build/synth_top.v

# Bridge isolation test: matadd through mem_bridge + sim memories.
test_mem_bridge:
	$(MAKE) compile_synth
	iverilog -o build/sim.vvp -s sim_harness -g2012 build/synth.v
	MODULE=test.test_mem_bridge COCOTB_TEST_MODULES=test.test_mem_bridge vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp

# Synth-top smoke test: instantiate de1_soc with a fast SLOW_CLK_DIV so the
# divider isn't 10M cycles per gpu_clk edge. Requires the if/else kernel image
# already generated -- this rule regenerates it just in case.
test_synth_top:
	$(MAKE) synth_kernel KERNEL=test_diverge_ifelse
	$(MAKE) compile_synth_top
	iverilog -Pde1_soc.SLOW_CLK_DIV=2 -Pde1_soc.FB_CLEAR_END_ADDR=63 -o build/sim.vvp -s de1_soc -g2012 build/synth_top.v
	MODULE=test.test_synth_top COCOTB_TEST_MODULES=test.test_synth_top vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp

# Synth-top line-drawing kernel. After this rule, synth/kernel_memories.sv is
# the uploadable DE1-SoC image for drawing four short vertical lines.
test_synth_line_draw:
	$(MAKE) synth_kernel KERNEL=test_synth_line_draw
	$(MAKE) compile_synth_top
	iverilog -Pde1_soc.SLOW_CLK_DIV=2 -Pde1_soc.FB_CLEAR_END_ADDR=63 -o build/sim.vvp -s de1_soc -g2012 build/synth_top.v
	MODULE=test.test_synth_line_draw COCOTB_TEST_MODULES=test.test_synth_line_draw vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp

# Synth-top spiral kernel. After this rule, synth/kernel_memories.sv is the
# uploadable DE1-SoC image for the four-tendril line-drawer spiral.
test_synth_spiral:
	$(MAKE) synth_kernel KERNEL=test_synth_spiral
	$(MAKE) compile_synth_top
	iverilog -Pde1_soc.SLOW_CLK_DIV=2 -Pde1_soc.FB_CLEAR_END_ADDR=63 -o build/sim.vvp -s de1_soc -g2012 build/synth_top.v
	MODULE=test.test_synth_spiral COCOTB_TEST_MODULES=test.test_synth_spiral vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp

# Stage 6 gate: 4-thread triangle kernel on the synth top + cocotb sim.
test_synth_triangle:
	$(MAKE) synth_kernel KERNEL=test_synth_triangle
	$(MAKE) compile_synth_top
	iverilog -Pde1_soc.SLOW_CLK_DIV=2 -Pde1_soc.FB_CLEAR_END_ADDR=63 -o build/sim.vvp -s de1_soc -g2012 build/synth_top.v
	MODULE=test.test_synth_triangle COCOTB_TEST_MODULES=test.test_synth_triangle vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp

compile_%:
	sv2v -w build/$*.v src/$*.sv

# Generate synth/kernel_memories.sv from a chosen cocotb test's program/data.
# Usage: make synth_kernel KERNEL=test_diverge_ifelse
synth_kernel:
	@if [ -z "$(KERNEL)" ]; then \
		echo "Usage: make synth_kernel KERNEL=<test_name>"; exit 1; \
	fi
	# Use the cocotb Python so the exported PYTHONPATH (which points to that
	# Python's stdlib) stays consistent. The system `python3` may be a
	# different minor version and will error on PYTHONPATH mismatch.
	$(PYGPI_PYTHON_BIN) -m test.helpers.synth_init $(KERNEL)

# TODO: Get gtkwave visualizaiton

show_%: %.vcd %.gtkw
	gtkwave $^
test_synth_debug:
	$(MAKE) synth_kernel KERNEL=test_diverge_ifelse
	$(MAKE) compile_synth_top
	iverilog -Pde1_soc.SLOW_CLK_DIV=2 -Pde1_soc.FB_CLEAR_END_ADDR=63 -o build/sim.vvp -s de1_soc -g2012 build/synth_top.v
	MODULE=test.test_synth_debug COCOTB_TEST_MODULES=test.test_synth_debug vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp

# de1_soc store regression: PC=9 STR handshake + mem[16|33..35] (kernel_memories image).
test_synth_store:
	$(MAKE) synth_kernel KERNEL=test_diverge_ifelse
	$(MAKE) compile_synth_top
	iverilog -Pde1_soc.SLOW_CLK_DIV=2 -Pde1_soc.FB_CLEAR_END_ADDR=63 -o build/sim.vvp -s de1_soc -g2012 build/synth_top.v
	MODULE=test.test_synth_store COCOTB_TEST_MODULES=test.test_synth_store vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp

# sim_harness diverge_ifelse store (bridge + sim_data_ram, no DE1 wrappers).
test_harness_store:
	$(MAKE) compile_synth
	iverilog -o build/sim.vvp -s sim_harness -g2012 build/synth.v
	MODULE=test.test_harness_store COCOTB_TEST_MODULES=test.test_harness_store vvp -M $(COCOTB_LIB_DIR) -m libcocotbvpi_icarus build/sim.vvp
