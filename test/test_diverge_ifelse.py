"""If/else divergence: threadIdx == 0 takes the equal path, others take the
not-equal path. Both paths reconverge at RET.

Why this kernel requires divergence support
-------------------------------------------
The CMP/BRz at PC=7 splits the warp: thread 0 jumps to PC=11, threads 1/2/3
fall through to PC=8. Under the OLD single-PC scheduler this commits ONE PC
for the whole warp (fall-through=8) and silently masks thread 0's path forever
-- mem[16] would never get its 100 written, because thread 0's STR at PC=12
never runs.

With IPDOM divergence: PC=7 pushes (11, 0001) and runs 1110 from PC=8. The
fall-through side ends with `BR ALWAYS 13` (a leapfrog past saved reconverge
PC 11), which exercises the `>=` pop test plus role-swap in divergence.sv.

Per-thread output assertions (mem[16] for thread 0, mem[33..35] for
threads 1..3) prove BOTH sides ran. A partial pass that only ran one side
fails one of the asserts.
"""
import cocotb
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.diverge import run_kernel


@cocotb.test()
async def test_diverge_ifelse(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0x9000,  # PC 0:  CONST R0, #0           ; R0 = 0
        0x9164,  # PC 1:  CONST R1, #100         ; R1 = 100  (equal-path value)
        0x92C8,  # PC 2:  CONST R2, #200         ; R2 = 200  (not-equal-path value)
        0x9310,  # PC 3:  CONST R3, #16          ; baseA = 16
        0x9420,  # PC 4:  CONST R4, #32          ; baseB = 32
        0x35F0,  # PC 5:  ADD R5, %threadIdx, R0 ; R5 = threadIdx
        0x2050,  # PC 6:  CMP R5, R0             ; threadIdx vs 0
        0x140B,  # PC 7:  BRz EQUAL (PC=11)      ; thread 0 only branches
        0x3645,  # PC 8:  ADD R6, R4, R5         ; (1,2,3) addr = 32 + threadIdx
        0x8062,  # PC 9:  STR R6, R2             ; mem[32+t] = 200
        0x1E0D,  # PC 10: BR ALWAYS to RET (PC=13) -- leapfrogs past PC=11
        0x3635,  # PC 11: ADD R6, R3, R5         ; (thread 0) addr = 16 + 0
        0x8061,  # PC 12: STR R6, R1             ; mem[16] = 100
        0xF000,  # PC 13: RET                    ; reconvergence + per-thread RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [0] * 64

    threads = 4

    await setup(
        dut=dut, program_memory=program_memory, program=program,
        data_memory=data_memory, data=data, threads=threads,
    )

    cycles, max_stack_ptr, _ = await run_kernel(dut, program_memory, data_memory)

    # The kernel MUST have triggered at least one divergence push. If stack_ptr
    # stayed 0 throughout, the test passed without exercising the new code path.
    assert max_stack_ptr >= 1, (
        f"Divergence was never observed (stack_ptr stayed 0 over {cycles} cycles). "
        "This kernel is supposed to split into two groups."
    )

    # Per-thread output assertions: each thread wrote to its own dedicated address.
    assert data_memory.memory[16] == 100, (
        f"Thread 0 (equal path) should have written 100 to mem[16], got {data_memory.memory[16]}"
    )
    for tidx in range(1, 4):
        addr = 32 + tidx
        assert data_memory.memory[addr] == 200, (
            f"Thread {tidx} (not-equal path) should have written 200 to mem[{addr}], "
            f"got {data_memory.memory[addr]}"
        )

    # Sanity: addresses NOT written by any thread must remain 0. Catches
    # spurious writes from masked threads.
    for addr in [17, 18, 19, 32]:
        assert data_memory.memory[addr] == 0, (
            f"mem[{addr}] should remain 0, got {data_memory.memory[addr]} -- a masked thread wrote where it shouldn't"
        )
