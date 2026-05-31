"""Stage 5 end-to-end gate: 4-thread TRV/TRV/TRE kernel on the gpu top.

At the GPU top the framebuffer controller serializes each TRE submission to a
single fb_write_valid pulse carrying {mode=TRI, v0, v1, v2, color}. The pixel
walk happens further downstream in the CLOCK_50-domain fb_triangle_engine
(Stage 6), so this test records the request packets emitted at the top and
verifies the Python rasterizer's union of those triangles matches the union of
the expected fixture triangles.

Kernel: 4 threads, each thread submits one different triangle (general,
flat-top, flat-bottom, skinny) chosen to exercise the engine's main code
paths.
"""
import cocotb
from cocotb.triggers import ReadOnly, RisingEdge

from .helpers.memory import Memory
from .helpers.setup import setup
from .helpers.raster import rasterize


def CONST(rd, imm):   return (0x9 << 12) | ((rd & 0xF) << 8) | (imm & 0xFF)
def TRV(rd, rs, rt):  return (0xD << 12) | ((rd & 0xF) << 8) | ((rs & 0xF) << 4) | (rt & 0xF)
def TRE(rd, rs, rt):  return (0xE << 12) | ((rd & 0xF) << 8) | ((rs & 0xF) << 4) | (rt & 0xF)
def CMP(rs, rt):      return (0x2 << 12) | ((rs & 0xF) << 4) | (rt & 0xF)
def BRz(imm):         return (0x1 << 12) | (0b010 << 9) | (imm & 0xFF)  # nzp = Z
def BRalways(imm):    return (0x1 << 12) | (0b111 << 9) | (imm & 0xFF)
RET = 0xF000


# Triangles per thread. Chosen to exercise distinct engine code paths:
TRIANGLES = [
    ((8, 8),  (40, 16), (24, 32)),   # T0: general (mid-is-right)
    ((8, 8),  (40, 8),  (24, 32)),   # T1: flat-top
    ((24, 8), (8, 32),  (40, 32)),   # T2: flat-bottom
    ((8, 8),  (12, 40), (60, 24)),   # T3: skinny
]


@cocotb.test()
async def test_triangle_kernel(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")

    # Per-thread branch on %threadIdx -> a body that emits TRV/TRV/TRE for that
    # thread's triangle. Each body ends with BRalways(RET_PC). Layout (using
    # explicit PC math during edit-time):
    #
    # PC  0:  CONST R0, #0          ; tid 0 const
    # PC  1:  CONST R1, #1          ; tid 1
    # PC  2:  CONST R2, #2          ; tid 2
    # PC  3:  CONST R3, #3          ; tid 3
    # PC  4:  CONST R4, #1          ; color
    # PC  5:  CMP %threadIdx, R0
    # PC  6:  BRz T0
    # PC  7:  CMP %threadIdx, R1
    # PC  8:  BRz T1
    # PC  9:  CMP %threadIdx, R2
    # PC 10:  BRz T2
    # PC 11:  BRalways T3
    # PC 12..18: T0 body (CONST R5..R10, TRV, TRV, TRE, BR RET)
    # PC 19..25: T1 body
    # PC 26..32: T2 body
    # PC 33..39: T3 body
    # PC 40:  RET

    def body(start_pc, v0, v1, v2, ret_pc):
        x0, y0 = v0; x1, y1 = v1; x2, y2 = v2
        ops = [
            CONST(5, x0),    # R5 = v0.x
            CONST(6, y0),    # R6 = v0.y
            CONST(7, x1),    # R7 = v1.x
            CONST(8, y1),    # R8 = v1.y
            CONST(9, x2),    # R9 = v2.x
            CONST(10, y2),   # R10 = v2.y
            TRV(5, 6, 4),
            TRV(7, 8, 4),
            TRE(9, 10, 4),
            BRalways(ret_pc),
        ]
        return ops

    # Header: 12 instructions (PC 0..11).
    header = [
        CONST(0, 0),
        CONST(1, 1),
        CONST(2, 2),
        CONST(3, 3),
        CONST(4, 1),
        CMP(15, 0),
        # PC 6: BRz T0   (filled in below once we know body locations)
        # PC 7: CMP %threadIdx, R1
        # PC 8: BRz T1
        # PC 9: CMP %threadIdx, R2
        # PC 10: BRz T2
        # PC 11: BRalways T3
    ]
    HEADER_LEN = 12
    BODY_LEN = 10
    T0_PC = HEADER_LEN
    T1_PC = T0_PC + BODY_LEN
    T2_PC = T1_PC + BODY_LEN
    T3_PC = T2_PC + BODY_LEN
    RET_PC = T3_PC + BODY_LEN

    header.extend([
        BRz(T0_PC),
        CMP(15, 1),
        BRz(T1_PC),
        CMP(15, 2),
        BRz(T2_PC),
        BRalways(T3_PC),
    ])
    assert len(header) == HEADER_LEN

    program = list(header)
    for tri in TRIANGLES:
        program.extend(body(len(program), *tri, RET_PC))
    program.append(RET)
    assert len(program) == RET_PC + 1, f"program length {len(program)} != RET_PC+1 {RET_PC + 1}"

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

    submissions = []
    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()
        await ReadOnly()
        if int(dut.fb_write_valid.value) == 1:
            submissions.append({
                "mode": int(dut.fb_mode.value),
                "v0": (int(dut.fb_x0.value), int(dut.fb_y0.value)),
                "v1": (int(dut.fb_x1.value), int(dut.fb_y1.value)),
                "v2": (int(dut.fb_x.value),  int(dut.fb_y.value)),
                "color": int(dut.fb_color.value),
            })
        await RisingEdge(dut.clk)
        cycles += 1
        if cycles > 50_000:
            assert False, f"triangle kernel hung after {cycles} cycles"

    assert len(submissions) == 4, (
        f"Expected 4 TRE submissions (one per thread), got {len(submissions)}: {submissions}"
    )
    assert all(s["mode"] == 2 for s in submissions), (
        f"All submissions should have mode=TRI(=2); got modes {[s['mode'] for s in submissions]}"
    )
    assert all(s["color"] == 1 for s in submissions)

    # Verify each thread's triangle was submitted (by matching the v2 vertex,
    # which is distinct across the 4 fixtures).
    expected_triangles = {tuple(sorted([v0, v1, v2])) for v0, v1, v2 in TRIANGLES}
    got_triangles = {tuple(sorted([s["v0"], s["v1"], s["v2"]])) for s in submissions}
    assert got_triangles == expected_triangles, (
        f"Triangle vertex set mismatch.\n  expected: {expected_triangles}\n  got:      {got_triangles}"
    )

    # Rasterize each emitted triangle with the Python reference and check that
    # the union matches the fixture union pixel-for-pixel.
    expected_pixels = set()
    for v0, v1, v2 in TRIANGLES:
        expected_pixels |= rasterize(v0, v1, v2)
    got_pixels = set()
    for s in submissions:
        got_pixels |= rasterize(s["v0"], s["v1"], s["v2"])
    assert got_pixels == expected_pixels, (
        f"Pixel union mismatch (n_exp={len(expected_pixels)} n_got={len(got_pixels)})"
    )
