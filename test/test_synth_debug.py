"""Simulation diagnostics for `synth/de1_soc.sv` LEDR debug pages.

Use these tests when FPGA behavior (HEX PC, SW settings) does not match
expectations.

**Page 0 (SW[8]=1, SW[3:2]=0):** LEDR[7:4] mirrors `data_mem_write_valid` on the
GPU top-level. LEDR[3:0] is the selected-thread LSU panel (SW[1:0]).
(4 ports to multi-channel RAM), *not* one-hot per hardware thread. The data
`controller` maps 8 LSUs → 4 channels; when threads 1..3 store together you
typically see **three channel bits** asserted — often `4'b0111` (channels 0..2
each serving one LSU), not `4'b1110`.

To prove thread 0 is masked at PC=9, sample
`gpu_instance.data_memory_controller.consumer_write_valid`: expect LSUs 1..3
requesting while consumer 0 is quiet.

Sampling uses `ReadOnly()` so combinational LEDR matches the GPU outputs after
delta cycles settle.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from .helpers.logger import logger
from .test_synth_top import _decode_hex_pair, _to_int_or_none


def _sw_debug_p0(sw9_auto: int = 1) -> int:
    """SW[9] auto-step, SW[8] debug LED page, SW[3:2]=page0 (writes)."""
    return (sw9_auto << 9) | (1 << 8)


def _bits_match_ledr_write_valid(dut) -> bool:
    """Return True if LEDR[7:4] matches gpu data_mem_write_valid (page 0 wiring)."""
    gpu = dut.gpu_instance
    ledr = _to_int_or_none(dut.LEDR.value)
    wv = _to_int_or_none(gpu.data_mem_write_valid.value)
    if ledr is None or wv is None:
        return False
    return ((ledr >> 4) & 0xF) == (wv & 0xF)


def _int8(sig):
    """8-bit bus as int, or None if x/z."""
    v = _to_int_or_none(sig)
    if v is None:
        return None
    return v & 0xFF


def _popcount4(x: int) -> int:
    return ((x >> 0) & 1) + ((x >> 1) & 1) + ((x >> 2) & 1) + ((x >> 3) & 1)


@cocotb.test()
async def test_debug_page0_ledr_tracks_write_valid(dut):
    """LEDR[7:4] must always equal data_mem_write_valid when SW[8]=1, SW[3:2]=0."""
    clock = Clock(dut.CLOCK_50, 20, units="ns")
    cocotb.start_soon(clock.start())

    dut.KEY.value = 0b1111
    dut.SW.value = _sw_debug_p0(1)
    await RisingEdge(dut.CLOCK_50)

    dut.KEY.value = 0b0111
    for _ in range(40):
        await RisingEdge(dut.CLOCK_50)
    dut.KEY.value = 0b1111

    mismatches = 0
    checked = 0
    for _ in range(2000):
        await RisingEdge(dut.CLOCK_50)
        await ReadOnly()
        gpu = dut.gpu_instance
        if _to_int_or_none(dut.LEDR.value) is None:
            continue
        if _to_int_or_none(gpu.data_mem_write_valid.value) is None:
            continue
        checked += 1
        if not _bits_match_ledr_write_valid(dut):
            mismatches += 1

    assert checked > 1000, "Too few non-X samples to verify LEDR vs mem_write_valid"
    assert mismatches == 0, (
        f"LEDR[7:4] != data_mem_write_valid in {mismatches}/{checked} non-X samples "
        "(SW[8]=1 debug page 0)"
    )


@cocotb.test()
async def test_pc9_str_three_channels_and_lsus_123_not_0(dut):
    """At PC=9 (not-equal STR), three LSUs (1..3) should request; thread 0 must not.

    Mem interface: expect three of four `data_mem_write_valid` bits (3 active
    channels). LSU interface: `consumer_write_valid[3:1]` should be non-zero
    pattern with [0]==0 while those requests are outstanding.
    """
    clock = Clock(dut.CLOCK_50, 20, units="ns")
    cocotb.start_soon(clock.start())

    dut.KEY.value = 0b1111
    dut.SW.value = _sw_debug_p0(1)
    await RisingEdge(dut.CLOCK_50)

    dut.KEY.value = 0b0111
    for _ in range(40):
        await RisingEdge(dut.CLOCK_50)
    dut.KEY.value = 0b1111

    gpu = dut.gpu_instance
    # Wait until HEX decodes to PC 9 (same display path as the board).
    saw_pc9 = False
    for _ in range(50_000):
        await RisingEdge(dut.CLOCK_50)
        pc = _decode_hex_pair(dut.HEX5.value, dut.HEX4.value)
        if pc == 9:
            saw_pc9 = True
            break
    assert saw_pc9, "Never reached PC=9 on HEX5..HEX4 (kernel or timing issue)"

    ctrl = gpu.data_memory_controller

    triple_mem = []  # (mem_wv, lsu_cv_low4, core_state)
    log_lines = []
    for _ in range(128):
        await RisingEdge(gpu.clk)
        await ReadOnly()
        pc = _decode_hex_pair(dut.HEX5.value, dut.HEX4.value)
        wv = _to_int_or_none(gpu.data_mem_write_valid.value)
        ledr_lo = _to_int_or_none(dut.LEDR.value)
        cst = _to_int_or_none(gpu.dbg_core0_state.value)
        cv = _int8(ctrl.consumer_write_valid)
        if ledr_lo is not None:
            ledr_lo &= 0xF
        if wv is not None:
            wv &= 0xF
        log_lines.append(
            f"  pc={pc} mem_ch_wv={wv} LEDR3_0={ledr_lo} core_state={cst} "
            f"lsu_cv[3:0]={(cv & 0xF) if cv is not None else None}"
        )
        if pc is not None and pc in (9, 10) and wv is not None and cv is not None and _popcount4(wv) == 3:
            triple_mem.append((wv, cv & 0xF, cst))

    for line in log_lines[:20]:
        logger.info(line)
    if len(log_lines) > 20:
        logger.info("  ... (%d more gpu_clk samples)", len(log_lines) - 20)

    assert triple_mem, (
        "Expected at least one PC=9 gpu_clk sample with three mem channels "
        f"asserting write_valid (3 parallel stores). Log excerpt:\n" + "\n".join(log_lines[:16])
    )
    wv, low4, cst = triple_mem[0]
    logger.info(
        "PC=9 triple-store snapshot: mem_wv=0b%04b lsu_cv[3:0]=%s core_state=%s",
        wv,
        f"{low4:04b}",
        cst,
    )

    assert (low4 & 0b0001) == 0 and _popcount4(low4) == 3, (
        f"Expected LSUs 1..3 requesting with LSU0 idle (consumer_write_valid[3:0]={low4:04b}), "
        "thread 0 must be masked on the not-equal path STR"
    )
