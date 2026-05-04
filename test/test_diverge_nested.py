"""Nested if/else: 4 threads split into 3 distinct exit groups via two nested
CMP/BRz comparisons. Validates that the reconvergence stack actually nests
(stack_ptr reaches >= 2 at the deepest moment) and that all three groups
write to disjoint memory regions.

Group split:
  threadIdx == 0  -> PATH_A (writes 10 to mem[40])
  threadIdx == 1  -> PATH_B (writes 20 to mem[61])
  threadIdx in 2,3 -> PATH_C (writes 30 to mem[80+threadIdx])

Why this kernel requires divergence support
-------------------------------------------
Two nested splits push two stack entries simultaneously. Under the OLD
single-PC scheduler at most one path per CMP would survive, so two of the
three regions would be silently skipped.

Each path ends with `BR ALWAYS to RET` whose target lies past the stack-top
reconverge PC -- exercises the leapfrog (`>=`) pop path twice, once for the
inner stack entry and once for the outer.

Per-region assertions verify all three groups ran to completion AND that
memory addresses NOT belonging to any group remain 0 (catches stray writes
from masked threads).
"""
import cocotb
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.diverge import run_kernel


@cocotb.test()
async def test_diverge_nested(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0x9500,  # PC 0:  CONST R5, #0
        0x9601,  # PC 1:  CONST R6, #1
        0x970A,  # PC 2:  CONST R7, #10        ; PATH_A value
        0x9814,  # PC 3:  CONST R8, #20        ; PATH_B value
        0x991E,  # PC 4:  CONST R9, #30        ; PATH_C value
        0x9A28,  # PC 5:  CONST R10, #40       ; PATH_A base addr
        0x9B3C,  # PC 6:  CONST R11, #60       ; PATH_B base addr
        0x9C50,  # PC 7:  CONST R12, #80       ; PATH_C base addr
        0x30F5,  # PC 8:  ADD R0, %threadIdx, R5  ; R0 = threadIdx
        0x2005,  # PC 9:  CMP R0, R5           ; vs 0
        0x1414,  # PC 10: BRz PATH_A (PC=20)   ; thread 0 branches up
        0x2006,  # PC 11: CMP R0, R6           ; vs 1
        0x1411,  # PC 12: BRz PATH_B (PC=17)   ; thread 1 branches up
        # PATH_C (threads 2, 3):
        0x31C0,  # PC 13: ADD R1, R12, R0      ; addr = 80 + threadIdx
        0x8019,  # PC 14: STR R1, R9           ; mem[80+t] = 30
        0x1E17,  # PC 15: BR ALWAYS to RET (PC=23)
        0x0000,  # PC 16: NOP                  ; padding (never reached)
        # PATH_B (thread 1):
        0x31B0,  # PC 17: ADD R1, R11, R0      ; addr = 60 + 1 = 61
        0x8018,  # PC 18: STR R1, R8           ; mem[61] = 20
        0x1E17,  # PC 19: BR ALWAYS to RET (PC=23)
        # PATH_A (thread 0):
        0x31A0,  # PC 20: ADD R1, R10, R0      ; addr = 40 + 0 = 40
        0x8017,  # PC 21: STR R1, R7           ; mem[40] = 10
        0x1E17,  # PC 22: BR ALWAYS to RET (PC=23)
        0xF000,  # PC 23: RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [0] * 128
    threads = 4

    await setup(
        dut=dut, program_memory=program_memory, program=program,
        data_memory=data_memory, data=data, threads=threads,
    )

    cycles, max_stack_ptr, _ = await run_kernel(dut, program_memory, data_memory)

    # Two nested splits -> stack depth must reach 2.
    assert max_stack_ptr >= 2, (
        f"Expected nested divergence with stack_ptr >= 2, got {max_stack_ptr}"
    )

    # Per-region assertions.
    assert data_memory.memory[40] == 10, f"PATH_A: expected mem[40]=10, got {data_memory.memory[40]}"
    assert data_memory.memory[61] == 20, f"PATH_B: expected mem[61]=20, got {data_memory.memory[61]}"
    assert data_memory.memory[82] == 30, f"PATH_C thread 2: expected mem[82]=30, got {data_memory.memory[82]}"
    assert data_memory.memory[83] == 30, f"PATH_C thread 3: expected mem[83]=30, got {data_memory.memory[83]}"

    # Negative assertions: nothing should have leaked into other slots.
    for addr in [41, 42, 43, 60, 62, 63, 80, 81]:
        assert data_memory.memory[addr] == 0, (
            f"mem[{addr}] should remain 0, got {data_memory.memory[addr]}"
        )
