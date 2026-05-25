"""Focused leapfrog test: the leader takes a BR that jumps STRICTLY PAST the
saved reconvergence PC, exercising the `>=` pop test plus the role-swap
re-divergence path in src/divergence.sv.

Why this kernel requires leapfrog handling specifically
-------------------------------------------------------
The CMP/BRz at PC=8 splits the warp:
  thread 0     -> PC=20 (HIGH path), pushed onto stack as (reconverge_pc=20, mask=0001)
  threads 1,2,3 -> PC=9 (fall-through path), become the leader

The leader runs PC=9-11. PC=11 is `BR ALWAYS to PC=30`, which sets
next_pc=30 -- STRICTLY > saved reconverge PC 20. With a `==` pop test the
deferred thread 0 would be stranded forever at PC=20 because the leader's PC
just skipped past it. With the `>=` test plus same-cycle re-evaluation of
divergence, the algorithm:
  1. Pops (20, 0001).
  2. Detects re-divergence (popped wants pc=20, leader wants pc=30).
  3. Swaps roles: overwrites top with (30, 1110) and runs thread 0 from PC=20.

When thread 0 then BRs to PC=30 the merged group reconverges cleanly.

Per-thread output assertions: mem[100] for thread 0 (HIGH path) and
mem[111..113] for threads 1..3 (fall-through path). If the leapfrog handling
were broken (e.g. == instead of >=), thread 0 would never write mem[100] and
the first assertion would fail.
"""
import cocotb
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.diverge import run_kernel


@cocotb.test()
async def test_diverge_leapfrog(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0x9000,  # PC 0:  CONST R0, #0
        0x9101,  # PC 1:  CONST R1, #1
        0x9501,  # PC 2:  CONST R5, #1            ; HIGH-path write value
        0x9602,  # PC 3:  CONST R6, #2            ; fall-through write value
        0x9764,  # PC 4:  CONST R7, #100          ; HIGH-path addr base
        0x986E,  # PC 5:  CONST R8, #110          ; fall-through addr base
        0x32F0,  # PC 6:  ADD R2, %threadIdx, R0  ; R2 = threadIdx
        0x2020,  # PC 7:  CMP R2, R0              ; vs 0
        0x1414,  # PC 8:  BRz HIGH (PC=20)        ; thread 0 branches up
        # Fall-through path (threads 1,2,3):
        0x3982,  # PC 9:  ADD R9, R8, R2          ; addr = 110 + threadIdx
        0x8096,  # PC 10: STR R9, R6              ; mem[110+t] = 2
        0x1E1E,  # PC 11: BR ALWAYS to PC=30      ; *** LEAPFROG past saved pc=20 ***
        # Padding to keep absolute PCs aligned:
        0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,  # PC 12-19
        # HIGH path (thread 0):
        0x3972,  # PC 20: ADD R9, R7, R2          ; addr = 100 + 0
        0x8095,  # PC 21: STR R9, R5              ; mem[100] = 1
        0x1E1E,  # PC 22: BR ALWAYS to PC=30      ; reconverge with the (30, 1110) entry
        0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,  # PC 23-29
        0xF000,  # PC 30: RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [0] * 128
    threads = 4

    await setup(
        dut=dut, program_memory=program_memory, program=program,
        data_memory=data_memory, data=data, threads=threads,
    )

    cycles, max_stack_ptr, _ = await run_kernel(dut, program_memory, data_memory)

    assert max_stack_ptr >= 1, (
        f"Divergence was never observed (stack_ptr stayed 0 over {cycles} cycles)."
    )

    # The leapfrog assertion: thread 0 must have written its HIGH-path value.
    # If the pop test were `==` instead of `>=`, thread 0 would be stranded at
    # PC=20 and mem[100] would still be 0.
    assert data_memory.memory[100] == 1, (
        f"Thread 0 (HIGH path) expected mem[100]=1, got {data_memory.memory[100]}. "
        f"This usually means the leapfrog pop didn't fire (check `>=` vs `==` in divergence.sv)."
    )
    for tidx in range(1, 4):
        addr = 110 + tidx
        assert data_memory.memory[addr] == 2, (
            f"Thread {tidx} (fall-through) expected mem[{addr}]=2, got {data_memory.memory[addr]}"
        )

    for addr in [101, 102, 103, 110]:
        assert data_memory.memory[addr] == 0, (
            f"mem[{addr}] should remain 0, got {data_memory.memory[addr]}"
        )
