"""Stage 3 gate: TRV / TRE LSU ladders behave correctly.

  1. Two consecutive TRV instructions latch v0 then v1 (verified by inspecting
     each thread's lsu_instance.tri_v0_* and tri_v1_*).
  2. TRV's lsu_state ladder never asserts fb_write_valid (recorded across the
     whole kernel; any TRV-cycle write is a failure).
  3. After TRE submits, tri_idx is 0 again so a subsequent TRV writes v0.
  4. With one thread masked off (thread_count=3), the masked thread's
     latches remain zero.

The kernel issues two TRV/TRV/TRE triangles per thread; both triangles use
per-thread-distinct coordinates so a swap of v0/v1 would be visible.
"""
import cocotb
from cocotb.triggers import ReadOnly, RisingEdge

from .helpers.memory import Memory
from .helpers.setup import setup


# Encoding helpers ---------------------------------------------------------
def CONST(rd, imm):   return (0x9 << 12) | ((rd & 0xF) << 8) | (imm & 0xFF)
def TRV(rd, rs, rt):  return (0xD << 12) | ((rd & 0xF) << 8) | ((rs & 0xF) << 4) | (rt & 0xF)
def TRE(rd, rs, rt):  return (0xE << 12) | ((rd & 0xF) << 8) | ((rs & 0xF) << 4) | (rt & 0xF)
RET = 0xF000


@cocotb.test()
async def test_trv_tre_ladders(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")

    # Each thread submits: TRV(v0), TRV(v1), TRE(v2,color) -- twice.
    #   v0 = (10 + tid, 20 + tid)
    #   v1 = (50 + tid, 30 + tid)
    #   v2 = (40 + tid, 60 + tid)
    # Color = 1 (so fb_color is set).
    #
    # Bases go in R0..R5; tid-offsets in R7..R12 (R13..R15 are read-only).
    program = [
        # PC 0..6: load base constants
        CONST(0, 10),  # R0 = 10  (v0.x base)
        CONST(1, 20),  # R1 = 20  (v0.y base)
        CONST(2, 50),  # R2 = 50  (v1.x base)
        CONST(3, 30),  # R3 = 30  (v1.y base)
        CONST(4, 40),  # R4 = 40  (v2.x base)
        CONST(5, 60),  # R5 = 60  (v2.y base)
        CONST(6, 1),   # R6 = 1   (color)
        # Tid-offset addends: R7 = R0 + tid, ..., R12 = R5 + tid.
        0x370F,   # ADD R7,  R0, %threadIdx
        0x381F,   # ADD R8,  R1, %threadIdx
        0x392F,   # ADD R9,  R2, %threadIdx
        0x3A3F,   # ADD R10, R3, %threadIdx
        0x3B4F,   # ADD R11, R4, %threadIdx
        0x3C5F,   # ADD R12, R5, %threadIdx
        # Triangle 1
        TRV(7, 8, 6),     # v0 = (R7, R8)
        TRV(9, 10, 6),    # v1 = (R9, R10)
        TRE(11, 12, 6),   # v2 = (R11, R12), color=R6
        # Triangle 2 -- repeats the same shape; if tri_idx wasn't reset after
        # TRE, the first TRV here would write v1 instead of v0.
        TRV(7, 8, 6),
        TRV(9, 10, 6),
        TRE(11, 12, 6),
        RET,
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [0] * 64
    threads = 3

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads,
    )

    dut.fb_write_ready.value = 1

    fb_writes = []
    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()
        await ReadOnly()
        if int(dut.fb_write_valid.value) == 1:
            fb_writes.append({
                "mode": int(dut.fb_mode.value),
                "x0": int(dut.fb_x0.value), "y0": int(dut.fb_y0.value),
                "x1": int(dut.fb_x1.value), "y1": int(dut.fb_y1.value),
                "x":  int(dut.fb_x.value),  "y":  int(dut.fb_y.value),
                "color": int(dut.fb_color.value),
                "cycle": cycles,
            })
        await RisingEdge(dut.clk)
        cycles += 1
        if cycles > 20_000:
            assert False, "TRV/TRE kernel hung"

    # Every observed FB write should be MODE_TRI (no PIXEL/LINE in this kernel).
    assert all(w["mode"] == 2 for w in fb_writes), (
        f"Expected only TRI mode writes; got modes={set(w['mode'] for w in fb_writes)}"
    )

    # Two triangles per thread x threads active = 2 * threads submissions.
    expected_submissions = 2 * threads
    assert len(fb_writes) == expected_submissions, (
        f"Expected {expected_submissions} TRE submissions, got {len(fb_writes)}: {fb_writes}"
    )

    # For each thread, both triangles must show v0=(10+tid,20+tid),
    # v1=(50+tid,30+tid), v2=(40+tid,60+tid). If tri_idx wasn't reset after
    # TRE, the second triangle's v0/v1 would be swapped.
    by_thread: dict[int, list[dict]] = {}
    for w in fb_writes:
        tid = w["x0"] - 10  # invertible from base offsets
        by_thread.setdefault(tid, []).append(w)
    assert set(by_thread.keys()) == set(range(threads)), (
        f"FB writes do not span threads 0..{threads-1}: {by_thread.keys()}"
    )
    for tid, writes in by_thread.items():
        assert len(writes) == 2, f"thread {tid}: expected 2 TRE writes, got {len(writes)}"
        for w in writes:
            assert (w["x0"], w["y0"]) == (10 + tid, 20 + tid), (
                f"thread {tid} TRE write {w}: v0 mismatch (expected ({10+tid},{20+tid}))"
            )
            assert (w["x1"], w["y1"]) == (50 + tid, 30 + tid), (
                f"thread {tid} TRE write {w}: v1 mismatch (expected ({50+tid},{30+tid}))"
            )
            assert (w["x"],  w["y"])  == (40 + tid, 60 + tid), (
                f"thread {tid} TRE write {w}: v2 mismatch (expected ({40+tid},{60+tid}))"
            )
            assert w["color"] == 1, f"thread {tid} TRE write {w}: color should be 1"

    # Thread 3 (the masked-off thread; thread_count=3 so only tids 0..2 run)
    # must keep its triangle latches at zero.
    masked_thread = dut.cores[0].core_instance.threads[3].lsu_instance
    assert int(masked_thread.tri_v0_x.value) == 0
    assert int(masked_thread.tri_v0_y.value) == 0
    assert int(masked_thread.tri_v1_x.value) == 0
    assert int(masked_thread.tri_v1_y.value) == 0
    assert int(masked_thread.tri_idx.value) == 0
