"""Shared run-loop helpers for divergence cocotb tests."""
import cocotb
from cocotb.triggers import RisingEdge
from .format import format_cycle, divergence_state
from .logger import logger


async def run_kernel(dut, program_memory, data_memory):
    """Run the kernel to completion. Returns (cycles, max_stack_ptr_seen,
    max_done_mask_seen). Tests use the latter two to assert divergence
    actually happened (so a passing test can't have skipped the new code path)."""
    max_stack_ptr_seen = 0
    max_done_mask_seen = 0
    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles)

        for core in dut.cores:
            if int(str(dut.thread_count.value), 2) <= int(core.i.value) * int(dut.THREADS_PER_BLOCK.value):
                continue
            ds = divergence_state(core)
            if ds["stack_ptr"] > max_stack_ptr_seen:
                max_stack_ptr_seen = ds["stack_ptr"]
            if ds["done_mask"] > max_done_mask_seen:
                max_done_mask_seen = ds["done_mask"]

        await RisingEdge(dut.clk)
        cycles += 1

    logger.info(
        f"Completed in {cycles} cycles "
        f"(max stack_ptr={max_stack_ptr_seen}, max done_mask=0b{max_done_mask_seen:b})"
    )
    return cycles, max_stack_ptr_seen, max_done_mask_seen
