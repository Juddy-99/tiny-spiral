"""Synth-top store verification for the test_diverge_ifelse kernel image.

`kernel_memories.sv` is generated from the same program literals below. These
tests run through `de1_soc` + `mem_bridge` + inferred `data_ram` to prove the
not-equal-path STR at PC=9 completes and the full kernel writes mem[16] and
mem[33..35] as expected.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from .helpers.logger import logger
from .test_synth_top import _decode_hex_pair, _ledr_bit, _to_int_or_none

# Must stay aligned with test/test_diverge_ifelse.py and synth/kernel_memories.sv.
DIVERGE_IFELSE_PROGRAM = [
    0x9000,  # PC 0:  CONST R0, #0
    0x9164,  # PC 1:  CONST R1, #100
    0x92C8,  # PC 2:  CONST R2, #200
    0x9310,  # PC 3:  CONST R3, #16
    0x9420,  # PC 4:  CONST R4, #32
    0x35F0,  # PC 5:  ADD R5, %threadIdx, R0
    0x2050,  # PC 6:  CMP R5, R0
    0x140B,  # PC 7:  BRz EQUAL (PC=11)
    0x3645,  # PC 8:  ADD R6, R4, R5
    0x8062,  # PC 9:  STR R6, R2
    0x1E0D,  # PC 10: BR ALWAYS to RET (PC=13)
    0x3635,  # PC 11: ADD R6, R3, R5
    0x8061,  # PC 12: STR R6, R1
    0xF000,  # PC 13: RET
]


def _sw_debug_p0(sw9_auto: int = 1) -> int:
    """SW[9] auto-step, SW[8] debug LED page, SW[3:2]=page0 (writes)."""
    return (sw9_auto << 9) | (1 << 8)


def _int4(sig):
    v = _to_int_or_none(sig)
    if v is None:
        return None
    return v & 0xF


def _fmt4(value) -> str:
    if value is None:
        return "xxxx"
    return f"{value:04b}"


def _popcount4(x: int) -> int:
    return ((x >> 0) & 1) + ((x >> 1) & 1) + ((x >> 2) & 1) + ((x >> 3) & 1)


def _mem_byte(dut, addr: int) -> int:
    return int(dut.data_ram_instance.mem[addr].value)


async def _reset_de1_soc_auto(dut, sw: int = 1 << 9) -> None:
    """Pulse KEY[3] reset with SW[9]=1 so gpu_clk sees reset during bring-up."""
    clock = Clock(dut.CLOCK_50, 20, units="ns")
    cocotb.start_soon(clock.start())

    dut.KEY.value = 0b1111
    dut.SW.value = sw
    await RisingEdge(dut.CLOCK_50)

    dut.KEY.value = 0b0111
    for _ in range(40):
        await RisingEdge(dut.CLOCK_50)
    dut.KEY.value = 0b1111


@cocotb.test()
async def test_kernel_store_completes(dut):
    """Kernel finishes; PC passes 9; mem[16] and mem[33..35] hold path values."""
    await _reset_de1_soc_auto(dut, sw=(1 << 9) | (1 << 4))

    seen_pcs = set()
    done = False
    for _ in range(40_000):
        await RisingEdge(dut.CLOCK_50)
        pc = _decode_hex_pair(dut.HEX5.value, dut.HEX4.value)
        if pc is not None:
            seen_pcs.add(pc)
        if _ledr_bit(dut.LEDR.value, 9) == 1:
            done = True
            break

    logger.info(
        "store completes: done=%s distinct_pcs=%s",
        done,
        sorted(seen_pcs),
    )

    assert done, (
        f"LEDR[9] (done) never asserted within 40000 CLOCK_50 cycles. "
        f"Distinct PCs on HEX5..HEX4: {sorted(seen_pcs)}"
    )
    assert seen_pcs, "No PC samples on HEX5..HEX4"
    assert max(seen_pcs) >= 10, (
        f"Warp never left PC=9 STR (max PC seen = {max(seen_pcs)}). "
        f"Distinct PCs: {sorted(seen_pcs)}"
    )

    assert _mem_byte(dut, 16) == 100, (
        f"Thread 0 equal-path mem[16] expected 100, got {_mem_byte(dut, 16)}"
    )
    for tidx, addr in enumerate((33, 34, 35), start=1):
        got = _mem_byte(dut, addr)
        assert got == 200, (
            f"Thread {tidx} not-equal-path mem[{addr}] expected 200, got {got}"
        )


@cocotb.test()
async def test_pc9_str_handshake(dut):
    """At PC=9, three masked LSUs complete STR and the warp advances past PC=9."""
    await _reset_de1_soc_auto(dut, sw=_sw_debug_p0(1))

    gpu = dut.gpu_instance
    saw_pc9 = False
    for _ in range(50_000):
        await RisingEdge(dut.CLOCK_50)
        pc = _decode_hex_pair(dut.HEX5.value, dut.HEX4.value)
        if pc == 9:
            saw_pc9 = True
            break
    assert saw_pc9, "Never reached PC=9 on HEX5..HEX4"

    ctrl = gpu.data_memory_controller
    log_lines = []
    triple_mem = []
    left_pc9 = False
    stuck_after_triple = None

    for sample in range(256):
        await RisingEdge(gpu.clk)
        await ReadOnly()

        pc = _decode_hex_pair(dut.HEX5.value, dut.HEX4.value)
        done = _ledr_bit(dut.LEDR.value, 9) == 1
        core_state = _to_int_or_none(gpu.dbg_core0_state.value)
        active_mask = _int4(gpu.dbg_active_mask.value)
        wv = _int4(gpu.data_mem_write_valid.value)
        wr = _int4(gpu.data_mem_write_ready.value)
        ram_we = _int4(dut.data_ram_we.value)
        cv = _int4(ctrl.consumer_write_valid)
        cr = _int4(ctrl.consumer_write_ready)
        lsu_waiting = _int4(gpu.dbg_core0_lsu_waiting.value)
        lsu_requesting = _int4(gpu.dbg_core0_lsu_requesting.value)

        stuck = None
        if wv is not None and wr is not None:
            stuck = wv & ~wr

        log_lines.append(
            f"  s={sample} pc={pc} core={core_state} act=0b{_fmt4(active_mask)} "
            f"mem_wv=0b{_fmt4(wv)} mem_wr=0b{_fmt4(wr)} stuck=0b{_fmt4(stuck)} "
            f"ram_we=0b{_fmt4(ram_we)} lsu_cv=0b{_fmt4(cv)} lsu_cr=0b{_fmt4(cr)} "
            f"lsu_wait=0b{_fmt4(lsu_waiting)} lsu_req=0b{_fmt4(lsu_requesting)}"
        )

        if (
            pc is not None
            and pc in (9, 10)
            and wv is not None
            and cv is not None
            and _popcount4(wv) == 3
        ):
            triple_mem.append((wv, cv, core_state, stuck))
            if stuck == 0 and stuck_after_triple is None:
                stuck_after_triple = sample

        if sample < 64 and ((pc is not None and pc >= 10) or done):
            left_pc9 = True
            break

    for line in log_lines[:32]:
        logger.info(line)
    if len(log_lines) > 32:
        logger.info("  ... (%d more gpu_clk samples)", len(log_lines) - 32)

    assert left_pc9, (
        "PC did not advance to 10+ and done did not rise within 64 gpu_clk "
        f"samples after PC=9. Log excerpt:\n" + "\n".join(log_lines[:16])
    )
    assert triple_mem, (
        "Expected at least one sample with three mem write_valid bits at PC 9/10. "
        f"Log excerpt:\n" + "\n".join(log_lines[:16])
    )

    wv, cv, _cst, _stuck = triple_mem[0]
    assert (cv & 0b0001) == 0 and _popcount4(cv) == 3, (
        f"Expected LSUs 1..3 requesting with LSU0 idle (consumer_write_valid[3:0]={cv:04b})"
    )
    assert stuck_after_triple is not None, (
        "Never observed three-channel write_valid with all channels ready (stuck=0)"
    )

    logger.info(
        "PC=9 handshake: mem_wv=0b%04b lsu_cv=0b%04b first_stuck_clear_sample=%s",
        wv,
        cv,
        stuck_after_triple,
    )
