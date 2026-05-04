"""Mem-bridge isolation test.

Runs the full matadd kernel through synth/sim_harness.sv (which wires gpu +
mem_bridge instances + sim_program_rom + sim_data_ram together), bypassing the
Python Memory model entirely. Validates two things:

1. **Bridge protocol correctness**: matadd produces the same final memory
   state (C[i] = A[i] + B[i] for i in 0..7) as the Python-driven version.
2. **Cycle-count parity**: the bridge contributes ZERO extra cycles relative
   to the Python Memory model (which has effectively 0-cycle response). With
   async-read RAM (sim_program_rom / sim_data_ram) and a purely combinational
   bridge, the controller's READ_WAITING -> READ_RELAYING transition fires on
   the very next clock edge -- exactly matching what test_matadd does with
   data_memory.run().

If either assertion regresses, the bridge is adding latency or losing
transactions. Stop and debug before integrating into the synth top.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from .helpers.logger import logger

# Matadd baseline cycles (run with default Python Memory model). Any drift
# means the bridge is not cycle-equivalent to data_memory.run().
MATADD_BASELINE_CYCLES = 178


@cocotb.test()
async def test_mem_bridge(dut):
    program = [
        0b0101000011011110,  # MUL R0, %blockIdx, %blockDim
        0b0011000000001111,  # ADD R0, R0, %threadIdx
        0b1001000100000000,  # CONST R1, #0   (baseA)
        0b1001001000001000,  # CONST R2, #8   (baseB)
        0b1001001100010000,  # CONST R3, #16  (baseC)
        0b0011010000010000,  # ADD R4, R1, R0
        0b0111010001000000,  # LDR R4, R4
        0b0011010100100000,  # ADD R5, R2, R0
        0b0111010101010000,  # LDR R5, R5
        0b0011011001000101,  # ADD R6, R4, R5
        0b0011011100110000,  # ADD R7, R3, R0
        0b1000000001110110,  # STR R7, R6
        0b1111000000000000,  # RET
    ]

    data = [
        0, 1, 2, 3, 4, 5, 6, 7,  # Matrix A
        0, 1, 2, 3, 4, 5, 6, 7,  # Matrix B
    ]

    clock = Clock(dut.clk, 25, units="us")
    cocotb.start_soon(clock.start())

    dut.reset.value = 1
    dut.start.value = 0
    dut.device_control_write_enable.value = 0
    dut.init_we_program.value = 0
    dut.init_addr_program.value = 0
    dut.init_data_program.value = 0
    dut.init_we_data.value = 0
    dut.init_addr_data.value = 0
    dut.init_data_data.value = 0
    await RisingEdge(dut.clk)
    dut.reset.value = 0

    # Backdoor-load program memory.
    for addr, val in enumerate(program):
        dut.init_we_program.value = 1
        dut.init_addr_program.value = addr
        dut.init_data_program.value = val
        await RisingEdge(dut.clk)
    dut.init_we_program.value = 0

    # Backdoor-load data memory.
    for addr, val in enumerate(data):
        dut.init_we_data.value = 1
        dut.init_addr_data.value = addr
        dut.init_data_data.value = val
        await RisingEdge(dut.clk)
    dut.init_we_data.value = 0

    # Set thread count.
    dut.device_control_write_enable.value = 1
    dut.device_control_data.value = 8
    await RisingEdge(dut.clk)
    dut.device_control_write_enable.value = 0

    # Start.
    dut.start.value = 1

    cycles = 0
    while dut.done.value != 1:
        await RisingEdge(dut.clk)
        cycles += 1
        if cycles > 5000:
            assert False, f"Kernel hung after {cycles} cycles"

    logger.info(f"Bridged matadd completed in {cycles} cycles (baseline {MATADD_BASELINE_CYCLES})")

    # Per-element correctness via direct backdoor read of data_ram.mem.
    expected_results = [a + b for a, b in zip(data[0:8], data[8:16])]
    for i, expected in enumerate(expected_results):
        addr = i + 16
        result = int(dut.data_ram.mem[addr].value)
        assert result == expected, (
            f"matadd C[{i}] (mem[{addr}]) mismatch: expected {expected}, got {result}"
        )

    # Cycle-count parity: must match the Python Memory baseline exactly.
    assert cycles == MATADD_BASELINE_CYCLES, (
        f"Bridge added latency: matadd took {cycles} cycles vs baseline {MATADD_BASELINE_CYCLES}. "
        "The bridge or RAM module is not cycle-equivalent to test/helpers/memory.py."
    )
