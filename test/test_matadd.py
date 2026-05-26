import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle, divergence_state
from .helpers.logger import logger

@cocotb.test()
async def test_matadd(dut):
    # Program Memory
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b0101000011011110, # MUL R0, %blockIdx, %blockDim
        0b0011000000001111, # ADD R0, R0, %threadIdx         ; i = blockIdx * blockDim + threadIdx
        0b1001000100000000, # CONST R1, #0                   ; baseA (matrix A base address)
        0b1001001000001000, # CONST R2, #8                   ; baseB (matrix B base address)
        0b1001001100010000, # CONST R3, #16                  ; baseC (matrix C base address)
        0b0011010000010000, # ADD R4, R1, R0                 ; addr(A[i]) = baseA + i
        0b0111010001000000, # LDR R4, R4                     ; load A[i] from global memory
        0b0011010100100000, # ADD R5, R2, R0                 ; addr(B[i]) = baseB + i
        0b0111010101010000, # LDR R5, R5                     ; load B[i] from global memory
        0b0011011001000101, # ADD R6, R4, R5                 ; C[i] = A[i] + B[i]
        0b0011011100110000, # ADD R7, R3, R0                 ; addr(C[i]) = baseC + i
        0b1000000001110110, # STR R7, R6                     ; store C[i] in global memory
        0b1111000000000000, # RET                            ; end of kernel
    ]

    # Data Memory
    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [
        0, 1, 2, 3, 4, 5, 6, 7, # Matrix A (1 x 8)
        0, 1, 2, 3, 4, 5, 6, 7  # Matrix B (1 x 8)
    ]

    # Device Control
    threads = 8

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads
    )

    data_memory.display(24)

    # No-false-divergence assertion: matadd is a fully convergent kernel.
    # active_mask must stay full (all alive threads), stack_ptr must stay 0,
    # done_mask must stay 0 throughout. Catches accidental divergence triggers.
    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles)

        for core in dut.cores:
            if int(str(dut.thread_count.value), 2) <= int(core.i.value) * int(dut.THREADS_PER_BLOCK.value):
                continue
            ds = divergence_state(core)
            assert ds["stack_ptr"] == 0, (
                f"cycle {cycles} core {core.i.value}: unexpected divergence push (stack_ptr={ds['stack_ptr']})"
            )
            # Non-divergent kernel: done_mask flips from 0 to all-1s in the single
            # RET cycle. A partial value means a thread RETed alone -> divergence.
            assert ds["done_mask"] in (0, ds["alive_full"]), (
                f"cycle {cycles} core {core.i.value}: partial done_mask={ds['done_mask']:b} "
                f"(expected 0 or {ds['alive_full']:b})"
            )
            # active_mask is 0 in IDLE / after block_done, otherwise must be full.
            assert ds["active_mask"] in (0, ds["alive_full"]), (
                f"cycle {cycles} core {core.i.value}: partial active_mask={ds['active_mask']:b} "
                f"(expected 0 or {ds['alive_full']:b})"
            )

        await RisingEdge(dut.clk)
        cycles += 1

    logger.info(f"Completed in {cycles} cycles")
    data_memory.display(24)

    expected_results = [a + b for a, b in zip(data[0:8], data[8:16])]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 16]
        assert result == expected, f"Result mismatch at index {i}: expected {expected}, got {result}"