"""Equiangular spiral drawn pixel-by-pixel via STRFB (`test_spiral_pixels`).

This is the original spiral kernel: each emit is one STRFB to a single
framebuffer pixel. The companion `test_spiral_lines` cocotb test draws the
same four arms with LNS/LNE line segments through the framebuffer line
engine, so we can compare the two rendering styles side by side.

Each of the 4 threads draws one spiral arm starting at the center (127, 127)
of the 256x256 framebuffer region and curving outward toward the screen edge.
The 4 arms are spaced 90 degrees apart (equiangular), so the result is a
pinwheel that fills out as more pixels are emitted.

Densification strategy
----------------------
With only 256 bytes of data RAM, naively storing per-thread (x, y) pairs caps
us at ~30 pixels per arc -- which leaves visible gaps in the outer part of
each arm where arc-length per sample grows. Instead we store thread 0's full
120-pixel dense trajectory once and have the kernel ROTATE it by
90 deg * threadIdx for the other three threads, using a 2x2 sign-only
rotation matrix.

In unsigned 8-bit arithmetic, `x * 255 == -x mod 256` (because
255 = 256 - 1), so multiplication by the lookup-table entries {0, 1, 255}
turns into mod-256 sign flips and zeroings -- exactly what we need to apply

    x' = a*dx + b*dy + cx
    y' = c*dx + d*dy + cy

where (a, b, c, d) is the rotation matrix for the current thread and
(dx, dy) = (x_base - 127, y_base - 127). This burns four MULs per emit but
quadruples the effective resolution without spending any extra data bytes
on the other three threads.

Data RAM layout (exactly 256 bytes):

    data[  0 .. 119] = thread 0 x trajectory (dense pixel sequence)
    data[120 .. 239] = thread 0 y trajectory
    data[240 .. 243] = a coefficient, indexed by threadIdx
    data[244 .. 247] = b coefficient
    data[248 .. 251] = c coefficient
    data[252 .. 255] = d coefficient

At 4 pixels per second per thread, all 120 emits per arm take ~30 s to
paint -- the eye watches the pinwheel grow without obvious gaps. The
`clock_step.AUTO_DIV` default is chosen for that visual cadence (see
synth/clock_step.sv).
"""
import cocotb
from cocotb.triggers import RisingEdge

from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.logger import logger


NUM_PTS = 120
NUM_THREADS = 4
CX = 127

# Indices into `data` for the four coefficient tables (4 bytes each).
A_BASE = 240
B_BASE = 244
C_BASE = 248
D_BASE = 252
Y_OFFSET = NUM_PTS  # y trajectory starts immediately after x trajectory


# --- Pixel data ------------------------------------------------------------
# Generated from a quarter-of-3 turn (3*pi/2 *0.5 = 3*pi/4) Archimedean spiral
# with r = (s+1) * R_MAX / NUM_PTS, theta = s * (3*pi/4) / NUM_PTS, R_MAX = 120.
# Coordinates clamped to [0, 255]. See the script in the commit description /
# the spiral helper at the bottom of the file for the exact recipe.
#
# Must stay a plain int-literal list so test/helpers/synth_init.py can extract
# it via ast for synth/kernel_memories.sv generation.
data = [
    # ----- thread 0 x trajectory (120 bytes) -----
    128, 129, 130, 131, 132, 133, 134, 135, 136, 136,
    137, 138, 139, 139, 140, 140, 141, 141, 141, 142,
    142, 142, 142, 142, 142, 141, 141, 141, 140, 140,
    139, 138, 137, 136, 135, 134, 133, 131, 130, 129,
    127, 125, 124, 122, 120, 118, 116, 114, 112, 110,
    107, 105, 103, 101,  98,  96,  93,  91,  89,  86,
     84,  81,  79,  77,  74,  72,  70,  68,  66,  63,
     61,  59,  58,  56,  54,  52,  51,  50,  48,  47,
     46,  45,  44,  44,  43,  43,  42,  42,  42,  43,
     43,  43,  44,  45,  46,  47,  49,  50,  52,  54,
     56,  58,  60,  63,  65,  68,  71,  74,  78,  81,
     85,  88,  92,  96, 100, 104, 109, 113, 118, 122,
    # ----- thread 0 y trajectory (120 bytes) -----
    127, 127, 127, 127, 128, 128, 129, 129, 130, 130,
    131, 132, 133, 134, 135, 136, 137, 138, 139, 141,
    142, 143, 144, 146, 147, 149, 150, 151, 153, 154,
    156, 157, 158, 160, 161, 162, 164, 165, 166, 167,
    168, 169, 170, 171, 171, 172, 173, 173, 174, 174,
    174, 174, 174, 174, 174, 174, 173, 173, 172, 171,
    170, 169, 168, 167, 165, 164, 162, 160, 158, 156,
    154, 152, 150, 147, 145, 142, 139, 136, 133, 130,
    127, 124, 120, 117, 114, 110, 107, 103,  99,  96,
     92,  88,  85,  81,  77,  74,  70,  66,  63,  59,
     56,  52,  49,  45,  42,  39,  36,  33,  30,  27,
     24,  22,  20,  17,  15,  13,  11,  10,   8,   7,
    # ----- per-thread rotation coefficients (16 bytes) -----
    # a (idx by threadIdx): t=0:+1, t=1: 0, t=2:-1, t=3: 0
      1,   0, 255,   0,
    # b: t=0: 0, t=1:-1, t=2: 0, t=3:+1
      0, 255,   0,   1,
    # c: t=0: 0, t=1:+1, t=2: 0, t=3:-1
      0,   1,   0, 255,
    # d: t=0:+1, t=1: 0, t=2:-1, t=3: 0
      1,   0, 255,   0,
]
assert len(data) == 256, f"data must fully fill the 256-byte RAM, got {len(data)}"


# --- Kernel ----------------------------------------------------------------
# Register usage:
#   R0  = NUM_PTS (=120, also doubles as Y_OFFSET since the y table starts at addr 120)
#   R1  = CX (=127)
#   R2  = 1 (step increment)
#   R3  = 1 (pixel color / data byte)
#   R4  = a coefficient (loaded once per thread)
#   R5  = b
#   R6  = c
#   R7  = d
#   R8  = step counter (0..119) -- also the address of x_base
#   R9  = scratch (y_thread)
#   R10 = scratch (x_base / dx / d*dy)
#   R11 = scratch (y_addr / y_base / dy)
#   R12 = scratch (coeff base addr / x_thread)
#   R15 = %threadIdx (read-only)
program = [
    # ----- setup: load constants and per-thread rotation coefficients -----
    0x9078,  # PC  0: CONST R0, #120          ; loop bound / y offset
    0x917F,  # PC  1: CONST R1, #127          ; center (cx == cy)
    0x9201,  # PC  2: CONST R2, #1            ; step increment
    0x9301,  # PC  3: CONST R3, #1            ; nonzero -> pixel.color = white
    0x9CF0,  # PC  4: CONST R12, #240         ; A_BASE
    0x34CF,  # PC  5: ADD R4, R12, %threadIdx ; a address
    0x7440,  # PC  6: LDR R4, R4              ; a coefficient
    0x9CF4,  # PC  7: CONST R12, #244         ; B_BASE
    0x35CF,  # PC  8: ADD R5, R12, %threadIdx
    0x7550,  # PC  9: LDR R5, R5              ; b
    0x9CF8,  # PC 10: CONST R12, #248         ; C_BASE
    0x36CF,  # PC 11: ADD R6, R12, %threadIdx
    0x7660,  # PC 12: LDR R6, R6              ; c
    0x9CFC,  # PC 13: CONST R12, #252         ; D_BASE
    0x37CF,  # PC 14: ADD R7, R12, %threadIdx
    0x7770,  # PC 15: LDR R7, R7              ; d
    0x9800,  # PC 16: CONST R8, #0            ; step counter
    # ----- LOOP (PC=17): load thread-0 sample, rotate per thread, STRFB ---
    0x7A80,  # PC 17: LDR R10, R8             ; x_base = mem[step]
    0x3B80,  # PC 18: ADD R11, R8, R0         ; y_addr = step + 120
    0x7BB0,  # PC 19: LDR R11, R11            ; y_base = mem[y_addr]
    0x4AA1,  # PC 20: SUB R10, R10, R1        ; dx = x_base - 127 (mod 256)
    0x4BB1,  # PC 21: SUB R11, R11, R1        ; dy = y_base - 127
    0x5C4A,  # PC 22: MUL R12, R4, R10        ; a*dx       (mod 256; *255 == negate)
    0x595B,  # PC 23: MUL R9,  R5, R11        ; b*dy
    0x3CC9,  # PC 24: ADD R12, R12, R9        ; a*dx + b*dy
    0x3CC1,  # PC 25: ADD R12, R12, R1        ; + 127      -> x_thread (in R12)
    0x596A,  # PC 26: MUL R9,  R6, R10        ; c*dx       (reuse R9; x_thread is safe in R12)
    0x5A7B,  # PC 27: MUL R10, R7, R11        ; d*dy       (reuse R10; dx no longer needed)
    0x399A,  # PC 28: ADD R9, R9, R10         ; c*dx + d*dy
    0x3991,  # PC 29: ADD R9, R9, R1          ; + 127      -> y_thread (in R9)
    0xCC93,  # PC 30: STRFB R12, R9, R3       ; framebuffer[x=R12, y=R9] = R3 (white)
    0x3882,  # PC 31: ADD R8, R8, R2          ; step++
    0x2080,  # PC 32: CMP R8, R0              ; step vs 120
    0x1811,  # PC 33: BRn LOOP (PC=17)        ; loop while step < 120
    0xF000,  # PC 34: RET
]


def _expected_writes():
    """Mirror what the kernel will emit so we can do a set-equality assertion.

    Uses the exact same mod-256 arithmetic as the kernel (Python's `& 0xFF`
    matches the 8-bit ALU's truncation).
    """
    xs = data[:Y_OFFSET]
    ys = data[Y_OFFSET:Y_OFFSET * 2]
    out = set()
    for t in range(NUM_THREADS):
        a = data[A_BASE + t]
        b = data[B_BASE + t]
        c = data[C_BASE + t]
        d = data[D_BASE + t]
        for s in range(NUM_PTS):
            dx = (xs[s] - CX) & 0xFF
            dy = (ys[s] - CX) & 0xFF
            x_t = (a * dx + b * dy + CX) & 0xFF
            y_t = (c * dx + d * dy + CX) & 0xFF
            out.add((x_t, y_t, 1, 1))
    return out


@cocotb.test()
async def test_spiral_pixels(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")

    threads = NUM_THREADS

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads,
    )

    # Always-ready framebuffer sink (matches test_strfb).
    dut.fb_write_ready.value = 1

    recorded_writes = set()
    last_seen = None  # de-dup contiguous samples while fb_write_valid is held
    cycles = 0
    max_cycles = 80_000  # ~17 ops/iter * 120 iter * ~15 cyc/op + slack

    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()

        if int(dut.fb_write_valid.value) == 1:
            x = int(dut.fb_x.value)
            y = int(dut.fb_y.value)
            d = int(dut.fb_data.value)
            c = int(dut.fb_color.value)
            sample = (x, y, d, c)
            if sample != last_seen:
                recorded_writes.add(sample)
                last_seen = sample
        else:
            last_seen = None

        await RisingEdge(dut.clk)
        cycles += 1

        if cycles > max_cycles:
            assert False, (
                f"spiral kernel hung after {cycles} cycles "
                f"(captured {len(recorded_writes)} unique pixels)"
            )

    expected = _expected_writes()
    cycles_per_emit = cycles / (NUM_THREADS * NUM_PTS)
    logger.info(
        f"spiral_pixels kernel completed in {cycles} cycles "
        f"({cycles_per_emit:.2f} gpu_clk cycles per pixel-emit per thread, "
        f"emits/thread = {NUM_PTS})"
    )
    logger.info(
        f"recorded {len(recorded_writes)} unique FB writes, expected {len(expected)}"
    )

    missing = expected - recorded_writes
    extra = recorded_writes - expected
    assert not missing, (
        f"missing {len(missing)} expected pixels, e.g. {sorted(missing)[:5]}"
    )
    assert not extra, (
        f"unexpected pixels written, e.g. {sorted(extra)[:5]}"
    )
