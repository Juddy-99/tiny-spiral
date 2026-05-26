"""Synth-top smoke test for the LabsLand DE1-SoC bring-up.

Instantiates `synth/de1_soc.sv` directly (with kernel_memories.sv generated from
test_diverge_ifelse) and verifies:

1. The clock_step + boot FSM brings the GPU out of reset and runs.
2. PC advances past 0 (HEX5..HEX4 reflects the divergence unit's current_pc).
3. LEDR[9] (done) eventually rises -- the kernel runs to completion through
   the bridges + inferred RAM.
4. After done, HEX1..HEX0 readback at SW[7:4]=1 (data_ram[16]) shows 0x64
   = 100 -- the value thread 0 wrote on the equal path.

This proves the synth-top glue (clock_step, mem_bridge, kernel_memories,
seg7, HEX/LED panel wiring) all work end-to-end without needing actual FPGA
time. It does NOT prove cycle parity -- that's the mem_bridge isolation
test's job.
"""
import json
import time
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from .helpers.logger import logger


# #region agent log
def _agent_debug_log(hypothesis_id: str, message: str, data: dict, run_id: str) -> None:
    """Append one NDJSON line for debug-mode evidence (session c328fc)."""
    log_path = Path(__file__).resolve().parents[1] / ".cursor" / "debug-c328fc.log"
    rec = {
        "sessionId": "c328fc",
        "timestamp": int(time.time() * 1000),
        "hypothesisId": hypothesis_id,
        "location": "test/test_synth_top.py",
        "message": message,
        "data": data,
        "runId": run_id,
    }
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
    except OSError:
        pass


# #endregion

# 7-segment cathode pattern (active-low) -> nibble. Must mirror synth/seg7.sv.
_SEG7_DECODE = {
    0b1000000: 0x0, 0b1111001: 0x1, 0b0100100: 0x2, 0b0110000: 0x3,
    0b0011001: 0x4, 0b0010010: 0x5, 0b0000010: 0x6, 0b1111000: 0x7,
    0b0000000: 0x8, 0b0010000: 0x9, 0b0001000: 0xA, 0b0000011: 0xB,
    0b1000110: 0xC, 0b0100001: 0xD, 0b0000110: 0xE, 0b0001110: 0xF,
}


def _to_int_or_none(sig):
    """Return int(sig) or None if any bit is x/z (uninitialized regs early on)."""
    s = str(sig)
    if any(c in "xz" for c in s.lower()):
        return None
    try:
        return int(s, 2)
    except ValueError:
        return None


def _decode_hex_pair(hi_segs, lo_segs):
    hi_i = _to_int_or_none(hi_segs)
    lo_i = _to_int_or_none(lo_segs)
    if hi_i is None or lo_i is None:
        return None
    hi = _SEG7_DECODE.get(hi_i)
    lo = _SEG7_DECODE.get(lo_i)
    if hi is None or lo is None:
        return None
    return (hi << 4) | lo


def _ledr_bit(sig, bit):
    # cocotb 2.0 returns LogicArray; str() yields uppercase X/Z for unknown bits.
    s = str(sig).lower()
    # MSB-first; bit index counts from LSB. Length should be 10.
    if not s or len(s) < bit + 1:
        return None
    c = s[-(bit + 1)]
    if c in "xz":
        return None
    return int(c)


@cocotb.test()
async def test_synth_top(dut):
    # 50 MHz CLOCK_50.
    clock = Clock(dut.CLOCK_50, 20, units="ns")
    cocotb.start_soon(clock.start())

    # KEY is active-low: 1 = unpressed.
    dut.KEY.value = 0b1111
    dut.SW.value = 0
    await RisingEdge(dut.CLOCK_50)

    # Pulse reset (KEY[3] press = active-low). Hold long enough for several
    # gpu_clk edges (we built with SLOW_CLK_DIV=2 -> each gpu_clk half-period
    # is 2 CLOCK_50 cycles).
    dut.KEY.value = 0b0111  # KEY[3] pressed
    dut.SW.value = (1 << 9)  # auto mode active so reset is seen by gpu_clk path too
    for _ in range(40):
        await RisingEdge(dut.CLOCK_50)
    dut.KEY.value = 0b1111  # release reset, stay in auto mode

    # SW[9]=1 (auto) keeps gpu_clk free-running. Set SW[7:4]=1 so HEX1..HEX0
    # reads back data_ram[16] -- where thread 0 stores 100 on the equal path.
    dut.SW.value = (1 << 9) | (1 << 4)

    # Run until LEDR[9] (done) rises, or time out.
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

    logger.info(f"Done={done}, distinct PCs reflected on HEX5..HEX4: {sorted(seen_pcs)}")

    assert done, (
        f"LEDR[9] (done) never asserted within 40000 CLOCK_50 cycles. "
        f"Distinct PCs seen on HEX5..HEX4: {sorted(seen_pcs)}"
    )

    # PC should have advanced past the initial 0. The if/else kernel runs through
    # PC 0..13, so we should have observed several distinct values.
    assert 0 in seen_pcs, "PC=0 (post-reset) was never visible on HEX5..HEX4"
    assert max(seen_pcs) > 5, (
        f"PC never advanced past 5 (max seen = {max(seen_pcs)}). "
        "GPU may not be running through clock_step + bridges correctly."
    )

    # After done, the data_ram readback at SW[7:4]=1 -> mem[16] should be 100
    # (thread 0's equal-path write). Allow a few extra cycles for the seg7 to
    # settle on the new SW value.
    for _ in range(10):
        await RisingEdge(dut.CLOCK_50)
    readback = _decode_hex_pair(dut.HEX1.value, dut.HEX0.value)
    assert readback == 100, (
        f"Expected data_ram[16] readback = 100 (thread 0 equal-path write), "
        f"got {readback} on HEX1..HEX0"
    )

    # #region agent log
    _agent_debug_log(
        "H_SIM",
        "de1_soc synth_top simulation completed",
        {
            "done": done,
            "max_pc_seen": max(seen_pcs),
            "min_pc_seen": min(seen_pcs),
            "distinct_pc_count": len(seen_pcs),
            "mem16_readback_hex": readback,
        },
        run_id="sim-de1_soc-post-assert",
    )
    # #endregion
