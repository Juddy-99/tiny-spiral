"""Tests for the CLOCK_50-domain framebuffer line engine."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from .test_line_drawer import _bresenham_reference


async def _start_request(dut, is_line, x0, y0, x1, y1, color):
    dut.is_line.value = is_line
    dut.x0.value = x0
    dut.y0.value = y0
    dut.x1.value = x1
    dut.y1.value = y1
    dut.pixel_color_in.value = color
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0


async def _collect_until_done(dut):
    pixels = []
    for _ in range(2048):
        await ReadOnly()
        if int(dut.pixel_write.value) == 1:
            pixels.append((int(dut.x.value), int(dut.y.value), int(dut.pixel_color.value)))
        done = int(dut.done.value)
        await RisingEdge(dut.clk)
        if done:
            return pixels
    raise AssertionError("fb_line_engine did not finish within 2048 cycles")


@cocotb.test()
async def test_fb_line_engine_direct_and_line(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.reset.value = 1
    dut.start.value = 0
    dut.is_line.value = 0
    dut.x0.value = 0
    dut.y0.value = 0
    dut.x1.value = 0
    dut.y1.value = 0
    dut.pixel_color_in.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.reset.value = 0
    await RisingEdge(dut.clk)

    await _start_request(dut, 0, 0, 0, 9, 4, 1)
    direct = await _collect_until_done(dut)
    assert direct == [(9, 4, 1)]

    await _start_request(dut, 1, 2, 1, 8, 4, 1)
    line = await _collect_until_done(dut)
    expected = [(x, y, 1) for x, y in _bresenham_reference(2, 1, 8, 4)]
    assert line == expected, f"expected {expected}, got {line}"
