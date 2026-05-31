"""Stage 2 gate: standalone triangle engine bit-exact against Python reference.

Runs:
  1. 10 named fixtures from test/helpers/raster.FIXTURES.
  2. 100 deterministic random triangles (seed 0xBEEF).
  3. Vertex-order invariance: all 6 permutations of one fixture give the
     same pixel set.
  4. Reset mid-run does not corrupt the next triangle.
  5. Setup latency between `start` and the first `pixel_write` is small
     and bounded (matches plan budget of ~5 cycles).
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from .helpers.raster import FIXTURES, rasterize


async def _reset(dut):
    dut.reset.value = 1
    dut.start.value = 0
    dut.x0.value = 0
    dut.y0.value = 0
    dut.x1.value = 0
    dut.y1.value = 0
    dut.x2.value = 0
    dut.y2.value = 0
    dut.pixel_color_in.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.reset.value = 0
    await RisingEdge(dut.clk)


async def _drive_one_triangle(dut, v0, v1, v2, color=1, timeout=200_000):
    dut.x0.value, dut.y0.value = v0
    dut.x1.value, dut.y1.value = v1
    dut.x2.value, dut.y2.value = v2
    dut.pixel_color_in.value = color
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    pixels = set()
    setup_cycles = None
    cycles = 0
    while True:
        await ReadOnly()
        if int(dut.pixel_write.value) == 1:
            if setup_cycles is None:
                setup_cycles = cycles
            pixels.add((int(dut.x.value), int(dut.y.value)))
        done = int(dut.done.value)
        await RisingEdge(dut.clk)
        cycles += 1
        if done:
            return pixels, setup_cycles, cycles
        if cycles > timeout:
            raise AssertionError(
                f"fb_triangle_engine never asserted done for {(v0,v1,v2)}"
            )


@cocotb.test()
async def test_named_fixtures(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    for name, tri in FIXTURES.items():
        expected = rasterize(*tri)
        got, setup_cycles, cycles = await _drive_one_triangle(dut, *tri)
        assert got == expected, (
            f"{name}: pixel set mismatch.\n"
            f"  triangle: {tri}\n"
            f"  expected count: {len(expected)}\n"
            f"  got count:      {len(got)}\n"
            f"  missing first 10: {sorted(expected - got)[:10]}\n"
            f"  extra first 10:   {sorted(got - expected)[:10]}\n"
        )
        if expected:
            assert setup_cycles is not None and setup_cycles < 20, (
                f"{name}: setup latency {setup_cycles} > 20 cycles"
            )


@cocotb.test()
async def test_vertex_order_invariance(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    v0, v1, v2 = (10, 12), (45, 18), (22, 60)
    expected = rasterize(v0, v1, v2)

    for perm in [
        (v0, v1, v2), (v1, v2, v0), (v2, v0, v1),
        (v2, v1, v0), (v0, v2, v1), (v1, v0, v2),
    ]:
        got, _, _ = await _drive_one_triangle(dut, *perm)
        assert got == expected, (
            f"permutation {perm} produced different pixels than {(v0,v1,v2)}"
        )


@cocotb.test()
async def test_random_triangles(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    rng = random.Random(0xBEEF)
    failures = []
    for trial in range(100):
        v0 = (rng.randint(0, 255), rng.randint(0, 255))
        v1 = (rng.randint(0, 255), rng.randint(0, 255))
        v2 = (rng.randint(0, 255), rng.randint(0, 255))
        expected = rasterize(v0, v1, v2)
        got, _, _ = await _drive_one_triangle(dut, v0, v1, v2)
        if got != expected:
            failures.append((trial, (v0, v1, v2), len(expected), len(got)))
            if len(failures) <= 3:
                missing = sorted(expected - got)[:5]
                extra = sorted(got - expected)[:5]
                cocotb.log.error(
                    f"trial {trial} tri={v0}{v1}{v2} "
                    f"exp_n={len(expected)} got_n={len(got)} "
                    f"missing={missing} extra={extra}"
                )
    assert not failures, f"{len(failures)}/100 random triangles failed"


@cocotb.test()
async def test_reset_mid_run_does_not_corrupt_next(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    triA = (20, 20), (60, 20), (40, 50)
    triB = (5, 5), (80, 12), (40, 90)

    dut.x0.value, dut.y0.value = triA[0]
    dut.x1.value, dut.y1.value = triA[1]
    dut.x2.value, dut.y2.value = triA[2]
    dut.pixel_color_in.value = 1
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    for _ in range(15):
        await RisingEdge(dut.clk)

    await _reset(dut)

    expected_b = rasterize(*triB)
    got_b, _, _ = await _drive_one_triangle(dut, *triB)
    assert got_b == expected_b, (
        f"triangle B after mid-run reset of A produced wrong pixels: "
        f"missing={sorted(expected_b - got_b)[:5]} "
        f"extra={sorted(got_b - expected_b)[:5]}"
    )
