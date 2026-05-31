"""LNS/LNE end-to-end cocotb test at the GPU top."""
import cocotb
from cocotb.triggers import ReadOnly, RisingEdge

from .helpers.memory import Memory
from .helpers.setup import setup


@cocotb.test()
async def test_lnslne_line_requests(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0x9000,  # PC 0: CONST R0, #0
        0x9101,  # PC 1: CONST R1, #1
        0x9205,  # PC 2: CONST R2, #5
        0xAF01,  # PC 3: LNS %threadIdx, R0, R1
        0xBF21,  # PC 4: LNE %threadIdx, R2, R1
        0xF000,  # PC 5: RET
    ]

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

    dut.fb_write_ready.value = 1

    recorded = set()
    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await ReadOnly()

        if int(dut.fb_write_valid.value) == 1:
            recorded.add(
                (
                    int(dut.fb_mode.value),
                    int(dut.fb_x0.value),
                    int(dut.fb_y0.value),
                    int(dut.fb_x.value),
                    int(dut.fb_y.value),
                    int(dut.fb_data.value),
                    int(dut.fb_color.value),
                )
            )

        await RisingEdge(dut.clk)
        cycles += 1
        if cycles > 10_000:
            assert False, f"LNS/LNE kernel hung after {cycles} cycles"

    expected = {
        (1, 0, 0, 0, 5, 1, 1),
        (1, 1, 0, 1, 5, 1, 1),
        (1, 2, 0, 2, 5, 1, 1),
        (1, 3, 0, 3, 5, 1, 1),
    }
    assert recorded == expected, (
        f"line request set mismatch: expected {sorted(expected)}, got {sorted(recorded)}"
    )
