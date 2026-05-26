"""STRFB end-to-end cocotb test.

Kernel: 4 threads, each thread writes one framebuffer pixel.

  CONST R0, #0                ; R0 = 0
  STRFB %threadIdx, R0, %threadIdx   ; FB[x=tid, y=0] = tid (color = tid != 0)
  RET

Expected framebuffer writes (order-independent; arbitration is not specified):
    (x=0, y=0, data=0, color=0)
    (x=1, y=0, data=1, color=1)
    (x=2, y=0, data=2, color=1)
    (x=3, y=0, data=3, color=1)

Drives `dut.fb_write_ready = 1` unconditionally and samples the FB write port
on every rising clock edge. This exercises the full STRFB path: decoder ->
LSU FB ladder -> per-core / NUM_LSUS aggregation -> dedicated FB controller
-> single top-level FB write channel.
"""
import cocotb
from cocotb.triggers import RisingEdge

from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.logger import logger


@cocotb.test()
async def test_strfb(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0x9000,  # PC 0: CONST R0, #0
        0xCF0F,  # PC 1: STRFB %threadIdx, R0, %threadIdx
        0xF000,  # PC 2: RET
    ]

    # No LDR/STR in this kernel but the GPU top still has a data memory
    # interface that must be driven (otherwise data_mem_read_ready and friends
    # are floating, which leaks into the controller's combinational picks).
    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [0] * 64

    threads = 4

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads,
    )

    # Always-ready FB sink. The handshake completes in the same gpu_clk cycle
    # the controller asserts fb_write_valid -- matches Memory.run()'s
    # combinational ready protocol.
    dut.fb_write_ready.value = 1

    recorded_writes = set()
    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()

        if int(dut.fb_write_valid.value) == 1:
            x = int(dut.fb_x.value)
            y = int(dut.fb_y.value)
            d = int(dut.fb_data.value)
            c = int(dut.fb_color.value)
            recorded_writes.add((x, y, d, c))
            logger.info(
                f"cycle {cycles}: FB write x={x} y={y} data={d} color={c}"
            )

        await RisingEdge(dut.clk)
        cycles += 1

        if cycles > 10_000:
            assert False, f"STRFB kernel hung after {cycles} cycles"

    logger.info(
        f"STRFB kernel completed in {cycles} cycles, FB writes={sorted(recorded_writes)}"
    )

    expected = {
        (0, 0, 0, 0),
        (1, 0, 1, 1),
        (2, 0, 2, 1),
        (3, 0, 3, 1),
    }
    assert recorded_writes == expected, (
        f"FB write set mismatch: expected {sorted(expected)}, "
        f"got {sorted(recorded_writes)}"
    )
