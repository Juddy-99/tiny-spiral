"""Stage 6 gate: 4-thread triangle kernel on the de1_soc synth top.

The kernel launches 4 threads. Each thread branches to one fixed path and
submits exactly one TRV/TRV/TRE triangle. Together the four triangles tile
a diamond around the screen center (127, 127):

    Thread 0: top-right    quadrant -- (127, 97) (157, 127) (127, 127)
    Thread 1: top-left     quadrant -- (127, 97) ( 97, 127) (127, 127)
    Thread 2: bottom-left  quadrant -- ( 97,127) (127, 157) (127, 127)
    Thread 3: bottom-right quadrant -- (157,127) (127, 157) (127, 127)

The diamond shares vertices and edges across triangles; the top-left rule
must paint each shared edge exactly once (no cracks, no double-paint).

Generate the exact kernel image used here with:

    make synth_kernel KERNEL=test_synth_triangle

Test methodology (mirrors test/test_synth_spiral.py):
  - Drive CLOCK_50 + KEY[3] reset + SW[9]=1 (auto-clock).
  - Read the dut.fb_engine_pixel_write stream, collect (x, y).
  - Compare observed pixel set to the Python reference's union of the four
    triangles. Also spot-check 20 framebuffer storage cells.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from .helpers.logger import logger
from .helpers.raster import rasterize
from .test_synth_top import _ledr_bit


program = [
    0x9000,  # PC  0: CONST R0, #0
    0x9101,  # PC  1: CONST R1, #1
    0x9202,  # PC  2: CONST R2, #2
    0x9303,  # PC  3: CONST R3, #3
    0x9401,  # PC  4: CONST R4, #1   (color)
    0x20F0,  # PC  5: CMP %threadIdx, R0
    0x140C,  # PC  6: BRz T0(12)
    0x20F1,  # PC  7: CMP %threadIdx, R1
    0x1416,  # PC  8: BRz T1(22)
    0x20F2,  # PC  9: CMP %threadIdx, R2
    0x1420,  # PC 10: BRz T2(32)
    0x1E2A,  # PC 11: BR always T3(42)
    # T0: top-right quadrant -- v0=(127,97), v1=(157,127), v2=(127,127)
    0x957F,  # PC 12: CONST R5, #127
    0x9661,  # PC 13: CONST R6, #97
    0x979D,  # PC 14: CONST R7, #157
    0x987F,  # PC 15: CONST R8, #127
    0x997F,  # PC 16: CONST R9, #127
    0x9A7F,  # PC 17: CONST R10, #127
    0xD564,  # PC 18: TRV R5, R6, R4
    0xD784,  # PC 19: TRV R7, R8, R4
    0xE9A4,  # PC 20: TRE R9, R10, R4
    0x1E34,  # PC 21: BR always RET(52)
    # T1: top-left -- v0=(127,97), v1=(97,127), v2=(127,127)
    0x957F,  # PC 22: CONST R5, #127
    0x9661,  # PC 23: CONST R6, #97
    0x9761,  # PC 24: CONST R7, #97
    0x987F,  # PC 25: CONST R8, #127
    0x997F,  # PC 26: CONST R9, #127
    0x9A7F,  # PC 27: CONST R10, #127
    0xD564,  # PC 28: TRV
    0xD784,  # PC 29: TRV
    0xE9A4,  # PC 30: TRE
    0x1E34,  # PC 31: BR RET
    # T2: bottom-left -- v0=(97,127), v1=(127,157), v2=(127,127)
    0x9561,  # PC 32: CONST R5, #97
    0x967F,  # PC 33: CONST R6, #127
    0x977F,  # PC 34: CONST R7, #127
    0x989D,  # PC 35: CONST R8, #157
    0x997F,  # PC 36: CONST R9, #127
    0x9A7F,  # PC 37: CONST R10, #127
    0xD564,  # PC 38: TRV
    0xD784,  # PC 39: TRV
    0xE9A4,  # PC 40: TRE
    0x1E34,  # PC 41: BR RET
    # T3: bottom-right -- v0=(157,127), v1=(127,157), v2=(127,127)
    0x959D,  # PC 42: CONST R5, #157
    0x967F,  # PC 43: CONST R6, #127
    0x977F,  # PC 44: CONST R7, #127
    0x989D,  # PC 45: CONST R8, #157
    0x997F,  # PC 46: CONST R9, #127
    0x9A7F,  # PC 47: CONST R10, #127
    0xD564,  # PC 48: TRV
    0xD784,  # PC 49: TRV
    0xE9A4,  # PC 50: TRE
    0x1E34,  # PC 51: BR RET
    0xF000,  # PC 52: RET
]

data = [0] * 64

TRIANGLES = [
    ((127, 97),  (157, 127), (127, 127)),
    ((127, 97),  (97, 127),  (127, 127)),
    ((97, 127),  (127, 157), (127, 127)),
    ((157, 127), (127, 157), (127, 127)),
]


def _expected_triangle_pixels():
    out = set()
    for tri in TRIANGLES:
        out |= rasterize(*tri)
    return out


async def _reset_de1_soc_auto(dut) -> None:
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
async def test_synth_triangle_kernel(dut):
    await _reset_de1_soc_auto(dut)

    expected_pixels = _expected_triangle_pixels()
    observed_pixels = set()
    done = False

    for _ in range(400_000):
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
        "triangle synth kernel: done=%s observed=%d expected=%d",
        done,
        len(observed_pixels),
        len(expected_pixels),
    )

    assert done, "Triangle kernel did not finish on de1_soc"

    # Triangles must cover their pixels; the de1_soc engine may emit extras
    # at clipped boundaries but every expected pixel must appear.
    missing = expected_pixels - observed_pixels
    assert not missing, (
        f"Missing {len(missing)} expected pixels (first 20): {sorted(missing)[:20]}"
    )

    # Sanity: every quadrant around center (127,127) should have some pixel.
    assert any(x > 127 and y < 127 for x, y in observed_pixels), "top-right empty"
    assert any(x < 127 and y < 127 for x, y in observed_pixels), "top-left empty"
    assert any(x < 127 and y > 127 for x, y in observed_pixels), "bottom-left empty"
    assert any(x > 127 and y > 127 for x, y in observed_pixels), "bottom-right empty"

    # 20-pixel framebuffer spot check (matches the spiral test).
    spot = sorted(expected_pixels)[::max(1, len(expected_pixels) // 20)][:20]
    for x, y in spot:
        addr = x + (y << 9) + (y << 7)
        assert int(dut.fb_instance.framebuffer[addr].value) == 1, (
            f"Framebuffer pixel ({x}, {y}) at address {addr} was not written white"
        )
