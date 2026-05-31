"""Synth-top four-tendril spiral kernel for DE1-SoC upload.

Generate the exact kernel image used here with:

    make synth_kernel KERNEL=test_synth_spiral

The kernel launches four threads. Each thread branches to one fixed path and
draws one rotated square-spiral tendril from the center point (127, 127).
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from .helpers.logger import logger
from .test_line_drawer import _bresenham_reference
from .test_synth_top import _ledr_bit


program = [
    0x907F,  # PC   0: CONST R0, #127        ; center
    0x9101,  # PC   1: CONST R1, #1          ; white
    0x9200,  # PC   2: CONST R2, #0          ; tid 0
    0x9301,  # PC   3: CONST R3, #1          ; tid 1
    0x9402,  # PC   4: CONST R4, #2          ; tid 2
    0x9503,  # PC   5: CONST R5, #3          ; tid 3
    0x20F2,  # PC   6: CMP %threadIdx, R2
    0x140D,  # PC   7: BRz T0
    0x20F3,  # PC   8: CMP %threadIdx, R3
    0x142C,  # PC   9: BRz T1
    0x20F4,  # PC  10: CMP %threadIdx, R4
    0x144B,  # PC  11: BRz T2
    0x1E6A,  # PC  12: BR ALWAYS T3
    0x967F,  # PC  13: T0 S0: CONST R6, #127 ; x0
    0x977F,  # PC  14: CONST R7, #127        ; y0
    0x9897,  # PC  15: CONST R8, #151        ; x1
    0x997F,  # PC  16: CONST R9, #127        ; y1
    0xA671,  # PC  17: LNS R6, R7, R1
    0xB891,  # PC  18: LNE R8, R9, R1
    0x9697,  # PC  19: T0 S1: CONST R6, #151 ; x0
    0x977F,  # PC  20: CONST R7, #127        ; y0
    0x9897,  # PC  21: CONST R8, #151        ; x1
    0x9967,  # PC  22: CONST R9, #103        ; y1
    0xA671,  # PC  23: LNS R6, R7, R1
    0xB891,  # PC  24: LNE R8, R9, R1
    0x9697,  # PC  25: T0 S2: CONST R6, #151 ; x0
    0x9767,  # PC  26: CONST R7, #103        ; y0
    0x9867,  # PC  27: CONST R8, #103        ; x1
    0x9967,  # PC  28: CONST R9, #103        ; y1
    0xA671,  # PC  29: LNS R6, R7, R1
    0xB891,  # PC  30: LNE R8, R9, R1
    0x9667,  # PC  31: T0 S3: CONST R6, #103 ; x0
    0x9767,  # PC  32: CONST R7, #103        ; y0
    0x9867,  # PC  33: CONST R8, #103        ; x1
    0x99AF,  # PC  34: CONST R9, #175        ; y1
    0xA671,  # PC  35: LNS R6, R7, R1
    0xB891,  # PC  36: LNE R8, R9, R1
    0x9667,  # PC  37: T0 S4: CONST R6, #103 ; x0
    0x97AF,  # PC  38: CONST R7, #175        ; y0
    0x98C7,  # PC  39: CONST R8, #199        ; x1
    0x99AF,  # PC  40: CONST R9, #175        ; y1
    0xA671,  # PC  41: LNS R6, R7, R1
    0xB891,  # PC  42: LNE R8, R9, R1
    0x1E89,  # PC  43: BR ALWAYS RET
    0x967F,  # PC  44: T1 S0: CONST R6, #127 ; x0
    0x977F,  # PC  45: CONST R7, #127        ; y0
    0x987F,  # PC  46: CONST R8, #127        ; x1
    0x9967,  # PC  47: CONST R9, #103        ; y1
    0xA671,  # PC  48: LNS R6, R7, R1
    0xB891,  # PC  49: LNE R8, R9, R1
    0x967F,  # PC  50: T1 S1: CONST R6, #127 ; x0
    0x9767,  # PC  51: CONST R7, #103        ; y0
    0x9867,  # PC  52: CONST R8, #103        ; x1
    0x9967,  # PC  53: CONST R9, #103        ; y1
    0xA671,  # PC  54: LNS R6, R7, R1
    0xB891,  # PC  55: LNE R8, R9, R1
    0x9667,  # PC  56: T1 S2: CONST R6, #103 ; x0
    0x9767,  # PC  57: CONST R7, #103        ; y0
    0x9867,  # PC  58: CONST R8, #103        ; x1
    0x9997,  # PC  59: CONST R9, #151        ; y1
    0xA671,  # PC  60: LNS R6, R7, R1
    0xB891,  # PC  61: LNE R8, R9, R1
    0x9667,  # PC  62: T1 S3: CONST R6, #103 ; x0
    0x9797,  # PC  63: CONST R7, #151        ; y0
    0x98AF,  # PC  64: CONST R8, #175        ; x1
    0x9997,  # PC  65: CONST R9, #151        ; y1
    0xA671,  # PC  66: LNS R6, R7, R1
    0xB891,  # PC  67: LNE R8, R9, R1
    0x96AF,  # PC  68: T1 S4: CONST R6, #175 ; x0
    0x9797,  # PC  69: CONST R7, #151        ; y0
    0x98AF,  # PC  70: CONST R8, #175        ; x1
    0x9937,  # PC  71: CONST R9, #55         ; y1
    0xA671,  # PC  72: LNS R6, R7, R1
    0xB891,  # PC  73: LNE R8, R9, R1
    0x1E89,  # PC  74: BR ALWAYS RET
    0x967F,  # PC  75: T2 S0: CONST R6, #127 ; x0
    0x977F,  # PC  76: CONST R7, #127        ; y0
    0x9867,  # PC  77: CONST R8, #103        ; x1
    0x997F,  # PC  78: CONST R9, #127        ; y1
    0xA671,  # PC  79: LNS R6, R7, R1
    0xB891,  # PC  80: LNE R8, R9, R1
    0x9667,  # PC  81: T2 S1: CONST R6, #103 ; x0
    0x977F,  # PC  82: CONST R7, #127        ; y0
    0x9867,  # PC  83: CONST R8, #103        ; x1
    0x9997,  # PC  84: CONST R9, #151        ; y1
    0xA671,  # PC  85: LNS R6, R7, R1
    0xB891,  # PC  86: LNE R8, R9, R1
    0x9667,  # PC  87: T2 S2: CONST R6, #103 ; x0
    0x9797,  # PC  88: CONST R7, #151        ; y0
    0x9897,  # PC  89: CONST R8, #151        ; x1
    0x9997,  # PC  90: CONST R9, #151        ; y1
    0xA671,  # PC  91: LNS R6, R7, R1
    0xB891,  # PC  92: LNE R8, R9, R1
    0x9697,  # PC  93: T2 S3: CONST R6, #151 ; x0
    0x9797,  # PC  94: CONST R7, #151        ; y0
    0x9897,  # PC  95: CONST R8, #151        ; x1
    0x994F,  # PC  96: CONST R9, #79         ; y1
    0xA671,  # PC  97: LNS R6, R7, R1
    0xB891,  # PC  98: LNE R8, R9, R1
    0x9697,  # PC  99: T2 S4: CONST R6, #151 ; x0
    0x974F,  # PC 100: CONST R7, #79         ; y0
    0x9837,  # PC 101: CONST R8, #55         ; x1
    0x994F,  # PC 102: CONST R9, #79         ; y1
    0xA671,  # PC 103: LNS R6, R7, R1
    0xB891,  # PC 104: LNE R8, R9, R1
    0x1E89,  # PC 105: BR ALWAYS RET
    0x967F,  # PC 106: T3 S0: CONST R6, #127 ; x0
    0x977F,  # PC 107: CONST R7, #127        ; y0
    0x987F,  # PC 108: CONST R8, #127        ; x1
    0x9997,  # PC 109: CONST R9, #151        ; y1
    0xA671,  # PC 110: LNS R6, R7, R1
    0xB891,  # PC 111: LNE R8, R9, R1
    0x967F,  # PC 112: T3 S1: CONST R6, #127 ; x0
    0x9797,  # PC 113: CONST R7, #151        ; y0
    0x9897,  # PC 114: CONST R8, #151        ; x1
    0x9997,  # PC 115: CONST R9, #151        ; y1
    0xA671,  # PC 116: LNS R6, R7, R1
    0xB891,  # PC 117: LNE R8, R9, R1
    0x9697,  # PC 118: T3 S2: CONST R6, #151 ; x0
    0x9797,  # PC 119: CONST R7, #151        ; y0
    0x9897,  # PC 120: CONST R8, #151        ; x1
    0x9967,  # PC 121: CONST R9, #103        ; y1
    0xA671,  # PC 122: LNS R6, R7, R1
    0xB891,  # PC 123: LNE R8, R9, R1
    0x9697,  # PC 124: T3 S3: CONST R6, #151 ; x0
    0x9767,  # PC 125: CONST R7, #103        ; y0
    0x984F,  # PC 126: CONST R8, #79         ; x1
    0x9967,  # PC 127: CONST R9, #103        ; y1
    0xA671,  # PC 128: LNS R6, R7, R1
    0xB891,  # PC 129: LNE R8, R9, R1
    0x964F,  # PC 130: T3 S4: CONST R6, #79  ; x0
    0x9767,  # PC 131: CONST R7, #103        ; y0
    0x984F,  # PC 132: CONST R8, #79         ; x1
    0x99C7,  # PC 133: CONST R9, #199        ; y1
    0xA671,  # PC 134: LNS R6, R7, R1
    0xB891,  # PC 135: LNE R8, R9, R1
    0x1E89,  # PC 136: BR ALWAYS RET
    0xF000,  # PC 137: RET
]

data = [0] * 64

SPIRAL_SEGMENTS = [
    [(127, 127, 151, 127), (151, 127, 151, 103), (151, 103, 103, 103),
     (103, 103, 103, 175), (103, 175, 199, 175)],
    [(127, 127, 127, 103), (127, 103, 103, 103), (103, 103, 103, 151),
     (103, 151, 175, 151), (175, 151, 175, 55)],
    [(127, 127, 103, 127), (103, 127, 103, 151), (103, 151, 151, 151),
     (151, 151, 151, 79), (151, 79, 55, 79)],
    [(127, 127, 127, 151), (127, 151, 151, 151), (151, 151, 151, 103),
     (151, 103, 79, 103), (79, 103, 79, 199)],
]


def _expected_spiral_pixels():
    pixels = set()
    for tendril in SPIRAL_SEGMENTS:
        for segment in tendril:
            pixels.update(_bresenham_reference(*segment))
    return pixels


async def _reset_de1_soc_auto(dut) -> None:
    """Pulse KEY[3] reset with SW[9]=1 so gpu_clk runs automatically."""
    clock = Clock(dut.CLOCK_50, 20, units="ns")
    cocotb.start_soon(clock.start())

    dut.KEY.value = 0b1111
    dut.SW.value = 1 << 9
    await RisingEdge(dut.CLOCK_50)

    dut.KEY.value = 0b0111
    for _ in range(40):
        await RisingEdge(dut.CLOCK_50)
    dut.KEY.value = 0b1111
    dut.SW.value = 1 << 9


@cocotb.test()
async def test_synth_spiral_kernel(dut):
    await _reset_de1_soc_auto(dut)

    expected_pixels = _expected_spiral_pixels()
    observed_pixels = set()
    done = False

    for _ in range(300_000):
        await RisingEdge(dut.CLOCK_50)
        await ReadOnly()

        if int(dut.fb_engine_pixel_write.value) == 1:
            x = int(dut.fb_engine_pixel_x.value)
            y = int(dut.fb_engine_pixel_y.value)
            color = int(dut.fb_engine_pixel_color.value)
            if color == 1:
                observed_pixels.add((x, y))

        if _ledr_bit(dut.LEDR.value, 9) == 1:
            done = True
            break

    logger.info(
        "spiral synth kernel: done=%s observed=%d expected=%d",
        done,
        len(observed_pixels),
        len(expected_pixels),
    )

    assert done, "Spiral line-draw kernel did not finish on de1_soc"
    assert expected_pixels.issubset(observed_pixels), (
        f"Missing spiral pixels: {sorted(expected_pixels - observed_pixels)[:20]}"
    )

    # Shape sanity checks: center, all four outer tendril tips, and every
    # quadrant around center should be covered.
    for pixel in [(127, 127), (199, 175), (175, 55), (55, 79), (79, 199)]:
        assert pixel in observed_pixels, f"Expected key spiral pixel {pixel}"

    assert any(x > 127 and y < 127 for x, y in observed_pixels)
    assert any(x < 127 and y < 127 for x, y in observed_pixels)
    assert any(x < 127 and y > 127 for x, y in observed_pixels)
    assert any(x > 127 and y > 127 for x, y in observed_pixels)

    for x, y in expected_pixels:
        addr = x + (y << 9) + (y << 7)
        assert int(dut.fb_instance.framebuffer[addr].value) == 1, (
            f"Framebuffer pixel ({x}, {y}) at address {addr} was not written white"
        )
