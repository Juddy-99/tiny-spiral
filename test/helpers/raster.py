"""Stage 1 - Integer-only Q16 scanline triangle rasterizer reference.

Every quantity is an integer. The reciprocal table is identical to the one
inlined into `synth/recip_lut.sv` (so the RTL and this Python reference cannot
disagree on slope math). Coordinates are 8-bit unsigned (0..255), matching
GPU register widths.

Fill rule (pre-committed in the plan):
    Left-inclusive, right-EXCLUSIVE.
    Top-inclusive, bottom-EXCLUSIVE.
i.e. `for x in range(xl, xr)` and `for cy in range(yt, yb)`.

Vertex sort: ascending by (y, x).

This file is importable as `test.helpers.raster` and also runnable as
`python -m test.helpers.raster --selftest` to print fixture counts.
"""
from __future__ import annotations

from typing import Iterable, Set, Tuple

Point = Tuple[int, int]
PixelSet = Set[Point]


RECIP: list[int] = [0] + [(1 << 16) // dy for dy in range(1, 256)]


def _sort3(v0: Point, v1: Point, v2: Point) -> tuple[Point, Point, Point]:
    pts = sorted([v0, v1, v2], key=lambda p: (p[1], p[0]))
    return pts[0], pts[1], pts[2]


def rasterize(v0: Point, v1: Point, v2: Point) -> PixelSet:
    """Return the set of (x, y) covered by the triangle v0-v1-v2.

    Implements scanline DDA with Q16 fixed-point slopes computed via the
    recip LUT. Matches the RTL in `synth/fb_triangle_engine.sv` bit-for-bit
    (when both run on the same vertices)."""
    (xt, yt), (xm, ym), (xb, yb) = _sort3(v0, v1, v2)

    if yt == yb:
        return set()

    cross = (xm - xt) * (yb - yt) - (xb - xt) * (ym - yt)
    if cross == 0:
        return set()

    slope_long = (xb - xt) * RECIP[yb - yt]
    slope_top = (xm - xt) * RECIP[ym - yt] if ym != yt else 0
    slope_bot = (xb - xm) * RECIP[yb - ym] if yb != ym else 0

    long_x_at_ym_q = (xt << 16) + slope_long * (ym - yt)
    mid_is_left = (xm << 16) < long_x_at_ym_q

    xa_q = xt << 16
    xb_q = xt << 16

    out: PixelSet = set()
    for cy in range(yt, yb):
        if cy == ym:
            xb_q = xm << 16
            slope_short = slope_bot
        elif cy < ym:
            slope_short = slope_top
        else:
            slope_short = slope_bot

        if mid_is_left:
            xl_q, xr_q = xb_q, xa_q
        else:
            xl_q, xr_q = xa_q, xb_q

        xl = xl_q >> 16
        xr = xr_q >> 16
        if 0 <= cy <= 255:
            for x in range(max(xl, 0), min(xr, 256)):
                out.add((x, cy))

        xa_q += slope_long
        xb_q += slope_short

    return out


def rasterize_many(triangles: Iterable[tuple[Point, Point, Point]]) -> PixelSet:
    pixels: PixelSet = set()
    for tri in triangles:
        pixels |= rasterize(*tri)
    return pixels


FIXTURES: dict[str, tuple[Point, Point, Point]] = {
    "solid_small":          ((10, 10), (20, 10), (15, 20)),
    "solid_large":          ((20, 20), (200, 20), (110, 180)),
    "flat_top":             ((10, 10), (50, 10), (30, 50)),
    "flat_bottom":          ((30, 10), (10, 50), (50, 50)),
    "skinny_horizontal":    ((10, 40), (250, 40), (130, 50)),
    "skinny_vertical":      ((40, 10), (50, 10), (45, 250)),
    "single_row":           ((10, 10), (20, 10), (30, 11)),
    "single_pixel":         ((10, 10), (10, 10), (10, 10)),
    "collinear":            ((10, 10), (20, 20), (30, 30)),
    "screen_edge":          ((0, 0), (255, 0), (127, 255)),
}


def _selftest() -> int:
    counts: dict[str, int] = {}
    for name, tri in FIXTURES.items():
        counts[name] = len(rasterize(*tri))
        print(f"{name:<22} v={tri}  count={counts[name]}")

    assert counts["single_pixel"] == 0, "zero-height triangle must rasterize to 0 pixels"
    assert counts["collinear"] == 0, "collinear vertices (cross=0) must rasterize to 0 pixels"
    assert counts["solid_small"] > 0
    assert counts["solid_large"] > 1000
    assert counts["flat_top"] > 0
    assert counts["flat_bottom"] > 0

    rotations = []
    for name, tri in FIXTURES.items():
        v0, v1, v2 = tri
        a = rasterize(v0, v1, v2)
        b = rasterize(v1, v2, v0)
        c = rasterize(v2, v0, v1)
        d = rasterize(v2, v1, v0)
        e = rasterize(v0, v2, v1)
        f = rasterize(v1, v0, v2)
        assert a == b == c == d == e == f, (
            f"fixture {name} is not vertex-order invariant: "
            f"sizes={[len(s) for s in (a, b, c, d, e, f)]}"
        )
        rotations.append((name, len(a)))
    print(f"vertex-order invariance: PASS ({len(rotations)} fixtures)")

    return 0


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        sys.exit(_selftest())
    sys.exit(_selftest())
