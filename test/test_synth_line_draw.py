"""Synth-top line drawing kernel for DE1-SoC upload.

Generate the exact kernel image used here with:

    make synth_kernel KERNEL=test_synth_line_draw

The kernel launches four threads. Each thread draws one vertical white line in
the top-left corner:

    x = threadIdx, y = 0..5
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from .helpers.logger import logger
from .test_synth_top import _ledr_bit


program = [
    0x9000,  # PC 0: CONST R0, #0
    0x9101,  # PC 1: CONST R1, #1
    0x9205,  # PC 2: CONST R2, #5
    0xAF01,  # PC 3: LNS %threadIdx, R0, R1
    0xBF21,  # PC 4: LNE %threadIdx, R2, R1
    0xF000,  # PC 5: RET
]

data = [0] * 64


async def _reset_de1_soc_auto(dut) -> None:
    """Pulse KEY[3] reset with SW[9]=1 so gpu_clk runs automatically."""
    clock = Clock(dut.CLOCK_50, 20, units="ns")
    cocotb.start_soon(clock.start())

    dut.KEY.value = 0b1111
    dut.SW.value = 1 << 9
    await RisingEdge(dut.CLOCK_50)

    dut.KEY.value = 0b0111
    for _ in range(40):
        await RisingEdge(dut.CLOCK_50)
    dut.KEY.value = 0b1111
    dut.SW.value = 1 << 9


@cocotb.test()
async def test_synth_line_draw_kernel(dut):
    await _reset_de1_soc_auto(dut)

    expected_pixels = {(x, y) for x in range(4) for y in range(6)}
    observed_pixels = set()
    done = False

    for _ in range(60_000):
        await RisingEdge(dut.CLOCK_50)
        await ReadOnly()

        if int(dut.fb_engine_pixel_write.value) == 1:
            x = int(dut.fb_engine_pixel_x.value)
            y = int(dut.fb_engine_pixel_y.value)
            color = int(dut.fb_engine_pixel_color.value)
            if color == 1:
                observed_pixels.add((x, y))

        if _ledr_bit(dut.LEDR.value, 9) == 1:
            done = True
            break

    logger.info(
        "line draw synth kernel: done=%s observed_pixels=%s",
        done,
        sorted(observed_pixels),
    )

    assert done, "Line draw kernel did not finish on de1_soc"
    assert expected_pixels.issubset(observed_pixels), (
        f"Missing expected line pixels: {sorted(expected_pixels - observed_pixels)}; "
        f"observed={sorted(observed_pixels)}"
    )

    for x, y in expected_pixels:
        addr = x + (y << 9) + (y << 7)
        assert int(dut.fb_instance.framebuffer[addr].value) == 1, (
            f"Framebuffer pixel ({x}, {y}) at address {addr} was not written white"
        )
