"""Per-thread loop with data-dependent trip count.

Each thread loops %threadIdx times accumulating R2 (=5) into R1, then stores
the result. Expected per-thread results: thread 0 -> 0, 1 -> 5, 2 -> 10, 3 -> 15.

Why this kernel requires divergence support
-------------------------------------------
The CMP/BRz at the loop head exits each thread on different iterations
(thread 0 exits immediately at PC=8, thread 1 after 1 iteration, etc.). Under
the OLD single-PC scheduler the BRz commits a single PC for the whole warp
based on `next_pc[N-1]` -- the LAST thread's choice -- so the fast-exiting
threads either get carried along through extra iterations they shouldn't run
(corrupting their accumulators) or vice versa.

With IPDOM divergence the early-exiters get pushed onto the reconvergence
stack; each later iteration peels another thread off the leader group, so
stack_ptr ramps up to (THREADS_PER_BLOCK - 1) = 3 before the long-running
thread reaches the exit. The threads then reconverge one by one at the STR
instruction.

Per-thread output assertions verify the EXACT loop-trip count for each
thread: a partial pass cannot fake all four values simultaneously.
"""
import cocotb
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.diverge import run_kernel


@cocotb.test()
async def test_diverge_loop(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0x9500,  # PC 0:  CONST R5, #0           ; constant 0
        0x9601,  # PC 1:  CONST R6, #1           ; loop decrement
        0x9205,  # PC 2:  CONST R2, #5           ; per-iteration increment
        0x9332,  # PC 3:  CONST R3, #50          ; output base address
        0x30F5,  # PC 4:  ADD R0, %threadIdx, R5 ; R0 = threadIdx (loop counter)
        0x9100,  # PC 5:  CONST R1, #0           ; accumulator = 0
        0x343F,  # PC 6:  ADD R4, R3, %threadIdx ; R4 = 50 + threadIdx (output addr)
        # LOOP (PC=7):
        0x2005,  # PC 7:  CMP R0, R5             ; R0 vs 0
        0x140C,  # PC 8:  BRz EXIT (PC=12)       ; thread exits when its R0 hits 0
        0x3112,  # PC 9:  ADD R1, R1, R2         ; acc += 5
        0x4006,  # PC 10: SUB R0, R0, R6         ; R0 -= 1
        0x1E07,  # PC 11: BR ALWAYS LOOP (PC=7)  ; back-edge
        # EXIT (PC=12):
        0x8041,  # PC 12: STR R4, R1             ; mem[50+threadIdx] = acc
        0xF000,  # PC 13: RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [0] * 64
    threads = 4

    await setup(
        dut=dut, program_memory=program_memory, program=program,
        data_memory=data_memory, data=data, threads=threads,
    )

    cycles, max_stack_ptr, _ = await run_kernel(dut, program_memory, data_memory)

    # Worst case for THREADS_PER_BLOCK=4: leader peels off one thread per loop
    # iteration, so stack_ptr should reach at least 2 (we have 4 distinct exit
    # times). If <2 we never actually nested -- this kernel must.
    assert max_stack_ptr >= 2, (
        f"Expected nested divergence (max stack_ptr >= 2), got {max_stack_ptr}"
    )

    # Per-thread loop-trip assertions.
    expected = {0: 0, 1: 5, 2: 10, 3: 15}
    for tidx, want in expected.items():
        addr = 50 + tidx
        got = data_memory.memory[addr]
        assert got == want, (
            f"Thread {tidx} (looped {tidx} times) should have written {want} to mem[{addr}], got {got}"
        )
