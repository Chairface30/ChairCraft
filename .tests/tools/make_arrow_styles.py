# Renders the flat waypoint arrow styles: ChairPlus/arrow_<style>.tga.
#   python .tests/tools/make_arrow_styles.py
#
# Unlike arrow.tga (the bevelled 3D arrow, 64 pre-rendered turns from
# make_arrow.py), a flat shape looks the same at every angle, so each style is
# one 128x128 texture pointing straight up and the addon turns it with
# SetRotation. That keeps each one to 64 KB instead of 4 MB.
#
# Drawn in greys with a dark outline, like arrow.tga, so SetVertexColor can
# tint it and it still reads against a bright sky. Pure Python, same as
# make_arrow.py: this machine has no numpy or PIL.
import math, os, struct

SIZE = 128
SS = 4                 # supersampling per axis
SPAN = 2.5             # model units across the texture; shapes live in [-1, 1]
OUTLINE_PX = 2


def poly(points):
    """Point-in-polygon test for a list of (x, y), even-odd rule."""
    def inside(x, y):
        hit = False
        n = len(points)
        for i in range(n):
            (x1, y1), (x2, y2) = points[i], points[(i + 1) % n]
            if (y1 > y) != (y2 > y):
                cx = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
                if x < cx:
                    hit = not hit
        return hit
    return inside


def union(*shapes):
    return lambda x, y: any(s(x, y) for s in shapes)


# Each style: (inside test, shade function). Shade returns 0..1 luminance for
# a point inside; the addon's tint multiplies it, so lighter reads brighter.
def top_lit(x, y):
    return 0.72 + 0.28 * (y + 1) / 2


STYLES = {
    # The bevel arrow's outline, flat.
    "flat": (poly([(-0.23, -0.95), (0.23, -0.95), (0.23, 0.05), (0.62, 0.05),
                   (0.0, 1.0), (-0.62, 0.05), (-0.23, 0.05)]), top_lit),
    # Two stacked chevrons.
    "chevron": (union(
        poly([(0.0, 1.0), (0.78, 0.22), (0.78, -0.08), (0.0, 0.62), (-0.78, -0.08), (-0.78, 0.22)]),
        poly([(0.0, 0.25), (0.78, -0.53), (0.78, -0.83), (0.0, -0.13), (-0.78, -0.83), (-0.78, -0.53)]),
    ), top_lit),
    # A compass needle: bright tip, dark tail, so which end points is obvious.
    "needle": (poly([(0.0, 1.0), (0.27, 0.0), (0.0, -1.0), (-0.27, 0.0)]),
               lambda x, y: 0.95 if y > 0 else 0.45),
    # A GPS-style dart with a notched tail.
    "dart": (poly([(0.0, 1.0), (0.72, -0.85), (0.0, -0.45), (-0.72, -0.85)]),
             lambda x, y: 0.62 + 0.38 * (1 - abs(x) / 0.72) if x != 0 else 1.0),
    # A plain solid triangle.
    "triangle": (poly([(0.0, 0.95), (0.8, -0.75), (-0.8, -0.75)]), top_lit),
    # A ring with a pointer on it, for those who want the direction without an
    # arrow in the middle of the screen.
    "ring": (union(
        lambda x, y: 0.52 <= math.hypot(x, y + 0.08) <= 0.72,
        poly([(0.0, 1.05), (0.3, 0.55), (-0.3, 0.55)]),
    ), lambda x, y: 1.0 if y > 0.55 else 0.8),
}


def render(inside, shade):
    cov = [[0.0] * SIZE for _ in range(SIZE)]
    lum = [[0.0] * SIZE for _ in range(SIZE)]
    for py in range(SIZE):
        for px in range(SIZE):
            hits, total = 0, 0.0
            for sy in range(SS):
                for sx in range(SS):
                    x = ((px + (sx + 0.5) / SS) / SIZE - 0.5) * SPAN
                    y = (0.5 - (py + (sy + 0.5) / SS) / SIZE) * SPAN
                    if inside(x, y):
                        hits += 1
                        total += shade(x, y)
            if hits:
                cov[py][px] = hits / (SS * SS)
                lum[py][px] = total / hits
    pixels = bytearray(SIZE * SIZE * 4)
    for py in range(SIZE):
        for px in range(SIZE):
            a = cov[py][px]
            ring = 0.0
            for dy in range(-OUTLINE_PX, OUTLINE_PX + 1):
                for dx in range(-OUTLINE_PX, OUTLINE_PX + 1):
                    yy, xx = py + dy, px + dx
                    if 0 <= yy < SIZE and 0 <= xx < SIZE:
                        ring = max(ring, cov[yy][xx])
            ring *= 0.85
            out_a = a + ring * (1 - a)
            v = (lum[py][px] * a) / out_a if out_a > 0 else 0.0
            g = int(round(max(0.0, min(1.0, v)) * 255))
            off = (py * SIZE + px) * 4
            pixels[off:off + 4] = bytes((g, g, g, int(round(out_a * 255))))
    return pixels


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.normpath(os.path.join(here, "..", "..", "ChairPlus"))
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28)
    for name, (inside, shade) in STYLES.items():
        path = os.path.join(out_dir, f"arrow_{name}.tga")
        with open(path, "wb") as f:
            f.write(header)
            f.write(render(inside, shade))
        print("wrote", path)


if __name__ == "__main__":
    main()
