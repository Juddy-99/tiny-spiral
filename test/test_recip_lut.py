"""Stage 0 gate: recip_lut.sv matches the Python Q16 golden table.

Sweeps dy = 0..255, compares the LUT output against
    recip[dy] = (1 << 16) // dy   for dy != 0
    recip[0]  = 0                  (sentinel)
and asserts the spot-checks from the plan: dy=1 -> 65536, dy=2 -> 32768,
dy=255 -> 257, dy=0 -> 0.
"""
import cocotb
from cocotb.triggers import Timer


GOLDEN = [0] + [(1 << 16) // dy for dy in range(1, 256)]


@cocotb.test()
async def test_recip_lut_full_sweep(dut):
    for dy in range(256):
        dut.dy.value = dy
        await Timer(1, units="ns")
        got = int(dut.recip.value)
        assert got == GOLDEN[dy], (
            f"recip[{dy}] mismatch: got {got}, expected {GOLDEN[dy]}"
        )


@cocotb.test()
async def test_recip_lut_spot_checks(dut):
    for dy, expected in [(0, 0), (1, 65536), (2, 32768), (255, 257)]:
        dut.dy.value = dy
        await Timer(1, units="ns")
        got = int(dut.recip.value)
        assert got == expected, (
            f"spot-check recip[{dy}]={got}, expected {expected}"
        )
