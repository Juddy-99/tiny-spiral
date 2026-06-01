"""Throughput benchmark: random triangles drawn ad infinitum on de1_soc.

This is a benchmark, not a golden-image correctness test. A 4-thread kernel
runs forever (no RET): each thread carries its own pseudo-random state seeded
by its unique thread id (`%threadIdx`, register R15) and, on every loop
iteration, generates a fresh triangle with random vertices (anywhere in the
8-bit 0..255 coordinate space -- so triangles range from tiny slivers to nearly
full-screen) and a random 8-bit RGB-3-3-2 color, then submits it via TRV/TRV/TRE.
Overlap is fine and expected; we only care how fast the triangle engine can
chew through random work.

Note on "unique id": the per-thread identifier is `%threadIdx` (R15), distinct
from the device control register (DCR), which carries the launch thread count.
Seeding each lane's LCG from `%threadIdx` gives the four threads four
independent random streams running in parallel through the single FB engine.

On-GPU pseudo-random generator (8-bit LCG, full period 256 by Hull-Dobell:
multiplier 5 == 1 mod 4, increment 1 odd):

    state = (5 * state + 1) mod 256        # ALU is 8-bit, so it wraps for free

The state is carried through R5/R6 (and R4 for color) so no extra register is
needed. Program (literal so `make synth_kernel KERNEL=test_synth_triangles_random`
can AST-extract it):

    PC 0 : CONST R0, #0          ; zero
    PC 1 : CONST R1, #5          ; LCG multiplier a
    PC 2 : CONST R2, #1          ; LCG increment c
    PC 3 : ADD   R6, R15, R0     ; seed = %threadIdx (per-lane unique id)
    PC 4 : CMP   R1, R0          ; 5 > 0 -> sets NZP (P); makes BR-always branch
  LOOP (PC 5):
    MUL R4,R6,R1 / ADD R4,R4,R2  ; color  = rng()
    MUL R5,R4,R1 / ADD R5,R5,R2  ; v0.x   = rng()
    MUL R6,R5,R1 / ADD R6,R6,R2  ; v0.y   = rng()
    TRV R5, R6, R4
    MUL R5,R6,R1 / ADD R5,R5,R2  ; v1.x   = rng()
    MUL R6,R5,R1 / ADD R6,R6,R2  ; v1.y   = rng()
    TRV R5, R6, R4
    MUL R5,R6,R1 / ADD R5,R5,R2  ; v2.x   = rng()
    MUL R6,R5,R1 / ADD R6,R6,R2  ; v2.y   = rng()
    TRE R5, R6, R4
    BR ALWAYS LOOP

The NZP register is only written by CMP, so the single pre-loop CMP keeps
BR-always (mask 111) taken on every iteration (`nzp & 111 != 0`). Without it,
the loop falls through, the kernel runs off the program end, and re-seeds.

Methodology: drive CLOCK_50 + KEY[3] reset + SW[9]=1 (auto-clock), let the
kernel run, and over a fixed CLOCK_50 window count finished triangles
(`tri_engine_done` pulses) and written pixels (`fb_engine_pixel_write`).
We stop early once enough triangles have been drawn to keep sim time bounded,
then report throughput. Pass criteria are liveness/sanity only.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from .helpers.logger import logger
from .test_synth_top import _ledr_bit


program = [
    0x9000,  # PC  0: CONST R0, #0          ; zero
    0x9105,  # PC  1: CONST R1, #5          ; LCG multiplier a
    0x9201,  # PC  2: CONST R2, #1          ; LCG increment c
    0x36F0,  # PC  3: ADD   R6, R15, R0     ; seed = %threadIdx
    0x2010,  # PC  4: CMP   R1, R0          ; set NZP so BR-always branches
    # LOOP (PC 5):
    0x5461,  # PC  5: MUL R4, R6, R1
    0x3442,  # PC  6: ADD R4, R4, R2        ; color = rng()
    0x5541,  # PC  7: MUL R5, R4, R1
    0x3552,  # PC  8: ADD R5, R5, R2        ; v0.x = rng()
    0x5651,  # PC  9: MUL R6, R5, R1
    0x3662,  # PC 10: ADD R6, R6, R2        ; v0.y = rng()
    0xD564,  # PC 11: TRV R5, R6, R4
    0x5561,  # PC 12: MUL R5, R6, R1
    0x3552,  # PC 13: ADD R5, R5, R2        ; v1.x = rng()
    0x5651,  # PC 14: MUL R6, R5, R1
    0x3662,  # PC 15: ADD R6, R6, R2        ; v1.y = rng()
    0xD564,  # PC 16: TRV R5, R6, R4
    0x5561,  # PC 17: MUL R5, R6, R1
    0x3552,  # PC 18: ADD R5, R5, R2        ; v2.x = rng()
    0x5651,  # PC 19: MUL R6, R5, R1
    0x3662,  # PC 20: ADD R6, R6, R2        ; v2.y = rng()
    0xE564,  # PC 21: TRE R5, R6, R4
    0x1E05,  # PC 22: BR ALWAYS LOOP(5)
]

data = [0] * 64

# Stop after this many finished triangles (keeps sim wall-time bounded) or when
# the cycle cap is hit, whichever comes first.
TARGET_TRIANGLES = 120
CYCLE_CAP = 300_000


async def _reset_de1_soc_auto(dut) -> None:
    clock = Clock(dut.CLOCK_50, 20, unit="ns")
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
async def test_synth_triangles_random(dut):
    await _reset_de1_soc_auto(dut)

    triangles_done = 0
    pixels_drawn = 0
    colors_seen = set()
    tri_color_seq = []
    prev_tri_done = 0
    cycles = 0

    for cycles in range(1, CYCLE_CAP + 1):
        await RisingEdge(dut.CLOCK_50)
        await ReadOnly()

        if int(dut.fb_engine_pixel_write.value) == 1:
            pixels_drawn += 1
            colors_seen.add(int(dut.fb_engine_pixel_color.value))

        tri_done = int(dut.tri_engine_done.value)
        if tri_done == 1 and prev_tri_done == 0:
            triangles_done += 1
            if len(tri_color_seq) < 24:
                tri_color_seq.append(int(dut.fb_engine_color.value))
        prev_tri_done = tri_done

        if triangles_done >= TARGET_TRIANGLES:
            break

    # The kernel never finishes (LEDR[9]/done stays low); confirm that.
    finished = _ledr_bit(dut.LEDR.value, 9) == 1

    pixels_per_tri = pixels_drawn / triangles_done if triangles_done else 0.0
    tris_per_kcycle = 1000.0 * triangles_done / cycles if cycles else 0.0
    pixels_per_cycle = pixels_drawn / cycles if cycles else 0.0

    logger.info(
        f"random-triangle benchmark: {triangles_done} triangles, "
        f"{pixels_drawn} pixels over {cycles} CLOCK_50 cycles"
    )
    logger.info(
        f"  throughput: {tris_per_kcycle:.3f} triangles / 1k cycles, "
        f"{pixels_per_cycle:.3f} pixels / cycle, "
        f"{pixels_per_tri:.1f} pixels / triangle avg, "
        f"{len(colors_seen)} distinct colors"
    )
    logger.info(f"  sample of per-triangle colors (first 24): {tri_color_seq}")

    # Liveness / sanity (this is a benchmark, so checks are loose):
    assert not finished, "infinite kernel unexpectedly asserted done"
    assert triangles_done > 0, "no triangles were drawn -- engine made no progress"
    assert pixels_drawn > 0, "no pixels were written"
    # With a working per-lane LCG the color changes every triangle. The earlier
    # "state never advances" bug showed exactly 4 colors (the four seed values),
    # so require clearly more than that.
    assert len(colors_seen) >= 8, (
        f"random colors barely varied ({len(colors_seen)} distinct): "
        f"{sorted(colors_seen)} -- LCG state may not be advancing across the loop"
    )
