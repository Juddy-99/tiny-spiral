"""Standalone tests for synth/line_drawer.sv."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge


def _bresenham_reference(x0, y0, x1, y1):
    """Match the hardware's left-to-right Bresenham normalization."""
    is_steep = abs(x1 - x0) < abs(y1 - y0)
    if is_steep:
        x0, y0 = y0, x0
        x1, y1 = y1, x1

    if x0 > x1:
        x0, y0, x1, y1 = x1, y1, x0, y0

    dx = x1 - x0
    dy = abs(y1 - y0)
    y_step = 1 if y0 < y1 else -1
    error = -(dx // 2)
    y = y0

    pixels = []
    for x in range(x0, x1 + 1):
        if is_steep:
            pixels.append((max(0, min(479, y)), x))
        else:
            pixels.append((x, max(0, min(479, y))))

        if x != x1:
            error += dy
            if error >= 0:
                y += y_step
                error -= dx

    return pixels


async def _draw_line(dut, x0, y0, x1, y1):
    dut.x0.value = x0
    dut.y0.value = y0
    dut.x1.value = x1
    dut.y1.value = y1
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    pixels = []
    for _ in range(2048):
        await ReadOnly()
        if int(dut.pixel_valid.value) == 1:
            pixels.append((int(dut.x.value), int(dut.y.value)))
        done = int(dut.done.value)
        await RisingEdge(dut.clk)
        if done:
            return pixels

    raise AssertionError("line_drawer did not finish within 2048 cycles")


@cocotb.test()
async def test_line_drawer_cases(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.reset.value = 1
    dut.start.value = 0
    dut.x0.value = 0
    dut.y0.value = 0
    dut.x1.value = 0
    dut.y1.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.reset.value = 0
    await RisingEdge(dut.clk)

    cases = [
        (2, 5, 7, 5),      # horizontal
        (10, 2, 10, 7),    # vertical / steep
        (0, 0, 6, 3),      # shallow diagonal
        (4, 1, 6, 8),      # steep diagonal
        (12, 9, 4, 3),     # reversed endpoints
    ]

    for case in cases:
        got = await _draw_line(dut, *case)
        expected = _bresenham_reference(*case)
        assert got == expected, f"{case}: expected {expected}, got {got}"
