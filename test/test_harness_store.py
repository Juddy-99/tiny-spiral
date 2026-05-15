"""sim_harness store check for the test_diverge_ifelse kernel (bridge + sim RAM).

Same program as synth/kernel_memories.sv without DE1 clock/boot wrappers.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from .helpers.logger import logger
from .test_synth_store import DIVERGE_IFELSE_PROGRAM


@cocotb.test()
async def test_harness_diverge_ifelse_store(dut):
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

    for addr, val in enumerate(DIVERGE_IFELSE_PROGRAM):
        dut.init_we_program.value = 1
        dut.init_addr_program.value = addr
        dut.init_data_program.value = val
        await RisingEdge(dut.clk)
    dut.init_we_program.value = 0

    for addr in range(64):
        dut.init_we_data.value = 1
        dut.init_addr_data.value = addr
        dut.init_data_data.value = 0
        await RisingEdge(dut.clk)
    dut.init_we_data.value = 0

    dut.device_control_write_enable.value = 1
    dut.device_control_data.value = 4
    await RisingEdge(dut.clk)
    dut.device_control_write_enable.value = 0

    dut.start.value = 1

    cycles = 0
    while dut.done.value != 1:
        await RisingEdge(dut.clk)
        cycles += 1
        if cycles > 20_000:
            assert False, f"Kernel hung after {cycles} cycles"

    logger.info("harness diverge_ifelse store completed in %d cycles", cycles)

    assert int(dut.data_ram.mem[16].value) == 100
    for addr in (33, 34, 35):
        assert int(dut.data_ram.mem[addr].value) == 200, (
            f"mem[{addr}] expected 200, got {int(dut.data_ram.mem[addr].value)}"
        )
