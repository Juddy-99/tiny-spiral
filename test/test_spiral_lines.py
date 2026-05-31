"""Equiangular spiral drawn as line segments via LNS/LNE (`test_spiral_lines`).

Sister test to `test_spiral_pixels`: instead of issuing one STRFB per pixel,
each thread walks 30 endpoint samples along its spiral arm and submits the
straight segments between consecutive endpoints to the framebuffer line
engine (LNS latches the start point, LNE submits a line to the next end
point). The fb_line_engine rasterises each segment with Bresenham in the
CLOCK_50 domain, filling in any pixels between the endpoints -- so 30
sparse samples per arm produce a continuous-looking pinwheel without
needing the in-kernel 90 deg rotation trick the pixel version relies on.

Data RAM layout (240 bytes; thread-major, x table then y table):

    data[t*30 + s]              = x endpoint s for thread t   (s = 0..29)
    data[t*30 + s + 120]        = y endpoint s for thread t

There are 4 threads * 30 = 120 endpoints (240 bytes), 29 line segments per
thread. The line engine handles rasterisation backpressure: while a long
segment is being drawn, fb_write_ready stays low and the issuing thread's
LSU stalls in WAITING, so the kernel naturally paces itself to the engine.

What the test asserts
---------------------
It cannot easily assert per-pixel rasterised output (the kernel doesn't see
the FB engine's pixel stream; that lives in the CLOCK_50 domain on the
synth top). Instead it records the *line-segment requests* the GPU emits
(mode=1, x0, y0, x1, y1, color) and asserts they equal the expected set --
the same correctness check `test_lnslne` uses, scaled up to 4 * 29 lines.
"""
import cocotb
from cocotb.triggers import RisingEdge

from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.logger import logger


NUM_PTS = 30                 # endpoints per thread (29 line segments per arm)
NUM_THREADS = 4
Y_OFFSET = NUM_THREADS * NUM_PTS  # = 120; matches base = tid*NUM_PTS layout


# --- Endpoint data ---------------------------------------------------------
# Generated from a 3*pi/4 sweep Archimedean spiral with r = (s+1)*R_MAX/NUM_PTS,
# theta = base_angle + s * (3*pi/4)/NUM_PTS, R_MAX = 120, base_angle =
# threadIdx * pi/2. Clamped to [0, 255].
#
# Layout: thread-major x then thread-major y so the kernel can address its
# slice via base = threadIdx * NUM_PTS, y_addr = x_addr + Y_OFFSET.
#
# Must stay a plain int-literal list so test/helpers/synth_init.py can extract
# it via ast when generating synth/kernel_memories.sv.
data = [
    # ----- x endpoints (4 threads * 30 = 120 bytes) -----
    # thread 0 (base angle 0):
    131, 135, 138, 141, 143, 144, 143, 142, 138, 133,
    127, 119, 111, 102,  92,  82,  72,  63,  55,  48,
     43,  40,  40,  41,  46,  53,  64,  76,  91, 108,
    # thread 1 (base angle pi/2):
    127, 126, 123, 120, 115, 110, 104,  98,  93,  87,
     83,  80,  78,  77,  78,  82,  87,  94, 104, 114,
    127, 141, 155, 171, 186, 201, 214, 227, 237, 246,
    # thread 2 (base angle pi):
    123, 119, 116, 113, 111, 110, 111, 112, 116, 121,
    127, 135, 143, 152, 162, 172, 182, 191, 199, 206,
    211, 214, 214, 213, 208, 201, 190, 178, 163, 146,
    # thread 3 (base angle 3*pi/2):
    127, 128, 131, 134, 139, 144, 150, 156, 161, 167,
    171, 174, 176, 177, 176, 172, 167, 160, 150, 140,
    127, 113,  99,  83,  68,  53,  40,  27,  17,   8,
    # ----- y endpoints (120 bytes) -----
    # thread 0:
    127, 128, 131, 134, 139, 144, 150, 156, 161, 167,
    171, 174, 176, 177, 176, 172, 167, 160, 150, 140,
    127, 113,  99,  83,  68,  53,  40,  27,  17,   8,
    # thread 1:
    131, 135, 138, 141, 143, 144, 143, 142, 138, 133,
    127, 119, 111, 102,  92,  82,  72,  63,  55,  48,
     43,  40,  40,  41,  46,  53,  64,  76,  91, 108,
    # thread 2:
    127, 126, 123, 120, 115, 110, 104,  98,  93,  87,
     83,  80,  78,  77,  78,  82,  87,  94, 104, 114,
    127, 141, 155, 171, 186, 201, 214, 227, 237, 246,
    # thread 3:
    123, 119, 116, 113, 111, 110, 111, 112, 116, 121,
    127, 135, 143, 152, 162, 172, 182, 191, 199, 206,
    211, 214, 214, 213, 208, 201, 190, 178, 163, 146,
]
assert len(data) == 240, f"data length must be 240, got {len(data)}"


# --- Kernel ----------------------------------------------------------------
# Register usage:
#   R0  = NUM_PTS (=30)               -- loop bound
#   R1  = Y_OFFSET (=120)             -- offset from x table to y table
#   R2  = 1                           -- step increment
#   R3  = 1                           -- color / pixel data (nonzero -> white)
#   R4  = base = %threadIdx * NUM_PTS -- per-thread x base address
#   R5  = step counter
#   R6  = loaded x endpoint
#   R7  = loaded y endpoint
#   R8  = scratch (x addr)
#   R9  = scratch (y addr)
#   R15 = %threadIdx
#
# Each iteration: LDR x[step]; LDR y[step]; LNE (latched_start -> (x, y));
# LNS (x, y, color) to update the latched start for the next segment.
program = [
    # ----- setup -----
    0x901E,  # PC  0: CONST R0, #30
    0x9178,  # PC  1: CONST R1, #120         ; Y_OFFSET
    0x9201,  # PC  2: CONST R2, #1           ; step increment
    0x9301,  # PC  3: CONST R3, #1           ; color/data (nonzero -> white)
    0x54F0,  # PC  4: MUL R4, %threadIdx, R0 ; base = tid * NUM_PTS

    # Load endpoint 0 (x[0], y[0]) for this thread and latch as line start.
    0x7640,  # PC  5: LDR R6, R4             ; R6 = x[0]
    0x3841,  # PC  6: ADD R8, R4, R1         ; y_addr = base + Y_OFFSET
    0x7780,  # PC  7: LDR R7, R8             ; R7 = y[0]
    0xA673,  # PC  8: LNS R6, R7, R3         ; latch start = (x[0], y[0])
    0x9501,  # PC  9: CONST R5, #1           ; step = 1 (segment endpoint index)

    # ----- LOOP (PC=10) ---------------------------------------------------
    0x3845,  # PC 10: ADD R8, R4, R5         ; x_addr = base + step
    0x7680,  # PC 11: LDR R6, R8             ; R6 = x[step]
    0x3981,  # PC 12: ADD R9, R8, R1         ; y_addr = x_addr + Y_OFFSET
    0x7790,  # PC 13: LDR R7, R9             ; R7 = y[step]
    0xB673,  # PC 14: LNE R6, R7, R3         ; draw line latched_start -> (R6, R7)
    0xA673,  # PC 15: LNS R6, R7, R3         ; update latched start = (R6, R7)
    0x3552,  # PC 16: ADD R5, R5, R2         ; step++
    0x2050,  # PC 17: CMP R5, R0             ; cmp step vs NUM_PTS
    0x180A,  # PC 18: BRn LOOP (PC=10)       ; loop while step < 30
    0xF000,  # PC 19: RET
]


def _expected_line_requests():
    """Mirror the LNE requests the kernel will emit.

    Each LNE produces one (mode=1, x0, y0, x1=fb_x, y1=fb_y, data, color)
    tuple. The latched (x0, y0) is the prior endpoint; (x1, y1) is the current.
    """
    out = set()
    for t in range(NUM_THREADS):
        base = t * NUM_PTS
        for s in range(1, NUM_PTS):
            x0 = data[base + s - 1]
            y0 = data[base + s - 1 + Y_OFFSET]
            x1 = data[base + s]
            y1 = data[base + s + Y_OFFSET]
            # mode=1 (line), data=1, color=1 (rt != 0).
            out.add((1, x0, y0, x1, y1, 1, 1))
    return out


@cocotb.test()
async def test_spiral_lines(dut):
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

    # Always-ready FB sink. Real fb_line_engine takes multiple cycles per line
    # (Bresenham at CLOCK_50), but here we model the LSU handshake only and
    # record each submitted line request once.
    dut.fb_write_ready.value = 1

    recorded = set()
    last_seen = None  # de-dup contiguous samples while fb_write_valid is held
    cycles = 0
    max_cycles = 30_000  # 9 ops/iter * 29 iter * ~15 cyc/op + slack

    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()

        if int(dut.fb_write_valid.value) == 1:
            sample = (
                int(dut.fb_mode.value),
                int(dut.fb_x0.value),
                int(dut.fb_y0.value),
                int(dut.fb_x.value),
                int(dut.fb_y.value),
                int(dut.fb_data.value),
                int(dut.fb_color.value),
            )
            if sample != last_seen:
                recorded.add(sample)
                last_seen = sample
        else:
            last_seen = None

        await RisingEdge(dut.clk)
        cycles += 1

        if cycles > max_cycles:
            assert False, (
                f"spiral_lines kernel hung after {cycles} cycles "
                f"(captured {len(recorded)} unique line requests)"
            )

    expected = _expected_line_requests()
    cycles_per_segment = cycles / (NUM_THREADS * (NUM_PTS - 1))
    logger.info(
        f"spiral_lines kernel completed in {cycles} cycles "
        f"({cycles_per_segment:.2f} gpu_clk cycles per line segment per thread, "
        f"segments/thread = {NUM_PTS - 1})"
    )
    logger.info(
        f"recorded {len(recorded)} unique LINE requests, expected {len(expected)}"
    )

    # Only line-mode requests are expected; explicitly filter out anything
    # non-LINE to make a mismatch loud.
    non_line = {r for r in recorded if r[0] != 1}
    assert not non_line, f"unexpected non-line FB requests: {sorted(non_line)[:5]}"

    missing = expected - recorded
    extra = recorded - expected
    assert not missing, (
        f"missing {len(missing)} expected line segments, e.g. {sorted(missing)[:5]}"
    )
    assert not extra, (
        f"unexpected line segments emitted, e.g. {sorted(extra)[:5]}"
    )
