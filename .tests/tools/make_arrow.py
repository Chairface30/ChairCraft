# Renders ChairPlus/arrow.tga, the waypoint arrow's sprite sheet.
#   python .tests/tools/make_arrow.py
#
# Pure Python on purpose: this machine has no numpy or PIL, and the sheet only
# needs rebuilding when the arrow's look changes.
#
# The arrow is a real mesh -- an extruded, bevelled arrow outline -- seen from
# an isometric-style tilt and lit from the upper left, so it reads as a solid
# object rather than a flat rotated icon. It is rendered in greys: the addon
# tints it with SetVertexColor, so one sheet serves every colour it turns.
#
# Layout: 8x8 cells of 128px in a 1024x1024 sheet. Cell i (row-major from the
# top left) shows the arrow turned i/64 of a full turn COUNTER-clockwise from
# pointing straight ahead (up the screen) -- the same sense as the client's
# GetPlayerFacing, so the addon's frame index is a plain division.
import math, os, struct

CELL = 128
GRID = 8
FRAMES = GRID * GRID
SS = 3                      # supersampling per axis
ELEVATION = math.radians(52)  # camera angle above the ground plane

# Outline in the ground plane, pointing +Y (forward), counter-clockwise.
HEAD_Y, TIP_Y, TAIL_Y = 0.05, 1.0, -0.95
HEAD_W, SHAFT_W = 0.62, 0.23
OUTLINE = [
    (-SHAFT_W, TAIL_Y), (SHAFT_W, TAIL_Y), (SHAFT_W, HEAD_Y),
    (HEAD_W, HEAD_Y), (0.0, TIP_Y), (-HEAD_W, HEAD_Y), (-SHAFT_W, HEAD_Y),
]
WALL_H, TOP_H, BEVEL = 0.16, 0.26, 0.11


def inset(poly, d):
    """Offset a counter-clockwise polygon inward by d (mitred corners)."""
    n = len(poly)
    lines = []
    for i in range(n):
        (x1, y1), (x2, y2) = poly[i], poly[(i + 1) % n]
        ex, ey = x2 - x1, y2 - y1
        length = math.hypot(ex, ey)
        nx, ny = -ey / length, ex / length          # inward for CCW
        lines.append(((x1 + nx * d, y1 + ny * d), (ex, ey)))
    out = []
    for i in range(n):
        (p, r), (q, s) = lines[i - 1], lines[i]
        cross = r[0] * s[1] - r[1] * s[0]
        t = ((q[0] - p[0]) * s[1] - (q[1] - p[1]) * s[0]) / cross
        out.append((p[0] + r[0] * t, p[1] + r[1] * t))
    return out


INNER = inset(OUTLINE, BEVEL)


def build_mesh():
    tris = []
    n = len(OUTLINE)
    for i in range(n):
        a, b = OUTLINE[i], OUTLINE[(i + 1) % n]
        ia, ib = INNER[i], INNER[(i + 1) % n]
        # Side wall.
        A0, B0 = (a[0], a[1], 0.0), (b[0], b[1], 0.0)
        A1, B1 = (a[0], a[1], WALL_H), (b[0], b[1], WALL_H)
        tris += [(A0, B0, B1), (A0, B1, A1)]
        # Bevel up to the top face.
        IA, IB = (ia[0], ia[1], TOP_H), (ib[0], ib[1], TOP_H)
        tris += [(A1, B1, IB), (A1, IB, IA)]
    # Top face: the shaft and the head, which is all the concave outline is.
    t = [(x, y, TOP_H) for x, y in INNER]
    tris += [(t[0], t[1], t[2]), (t[0], t[2], t[6]),
             (t[3], t[4], t[5]), (t[6], t[2], t[3]), (t[6], t[3], t[5])]
    return tris


MESH = build_mesh()

LIGHT = (-0.45, 0.35, 0.82)
_l = math.sqrt(sum(c * c for c in LIGHT))
LIGHT = tuple(c / _l for c in LIGHT)
VIEW = (0.0, -math.cos(ELEVATION), math.sin(ELEVATION))   # towards the camera


def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def norm(v):
    length = math.sqrt(dot(v, v)) or 1.0
    return (v[0] / length, v[1] / length, v[2] / length)


def render(angle):
    size = CELL * SS
    scale = size / 2.55
    cx, cy = size / 2, size / 2
    zbuf = [[1e9] * size for _ in range(size)]
    lum = [[None] * size for _ in range(size)]
    ca, sa = math.cos(angle), math.sin(angle)
    se, ce = math.sin(ELEVATION), math.cos(ELEVATION)

    def turn(p):
        x, y, z = p
        return (x * ca - y * sa, x * sa + y * ca, z)

    for tri in MESH:
        w = [turn(p) for p in tri]
        nrm = norm(cross(sub(w[1], w[0]), sub(w[2], w[0])))
        if dot(nrm, VIEW) < 0:
            nrm = (-nrm[0], -nrm[1], -nrm[2])
            if dot(nrm, VIEW) < 0:
                continue
        diffuse = max(0.0, dot(nrm, LIGHT))
        half = norm((LIGHT[0] + VIEW[0], LIGHT[1] + VIEW[1], LIGHT[2] + VIEW[2]))
        spec = max(0.0, dot(nrm, half)) ** 24
        shade = min(1.0, 0.30 + 0.62 * diffuse + 0.35 * spec)

        pts = []
        for x, y, z in w:
            sx = cx + x * scale
            sy = cy - (y * se + z * ce) * scale
            depth = y * ce - z * se
            pts.append((sx, sy, depth))
        (x0, y0, d0), (x1, y1, d1), (x2, y2, d2) = pts
        area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
        if abs(area) < 1e-9:
            continue
        minx, maxx = max(0, int(min(x0, x1, x2))), min(size - 1, int(max(x0, x1, x2)) + 1)
        miny, maxy = max(0, int(min(y0, y1, y2))), min(size - 1, int(max(y0, y1, y2)) + 1)
        for py in range(miny, maxy + 1):
            fy = py + 0.5
            for px in range(minx, maxx + 1):
                fx = px + 0.5
                w0 = ((x1 - fx) * (y2 - fy) - (x2 - fx) * (y1 - fy)) / area
                w1 = ((x2 - fx) * (y0 - fy) - (x0 - fx) * (y2 - fy)) / area
                w2 = 1 - w0 - w1
                if w0 < 0 or w1 < 0 or w2 < 0:
                    continue
                d = w0 * d0 + w1 * d1 + w2 * d2
                if d < zbuf[py][px]:
                    zbuf[py][px] = d
                    lum[py][px] = shade

    # Downsample, then ring the shape with a dark outline so it holds up
    # against a bright sky once tinted.
    cell_l = [[0.0] * CELL for _ in range(CELL)]
    cell_a = [[0.0] * CELL for _ in range(CELL)]
    for y in range(CELL):
        for x in range(CELL):
            total, hits = 0.0, 0
            for sy in range(SS):
                row = lum[y * SS + sy]
                for sx in range(SS):
                    v = row[x * SS + sx]
                    if v is not None:
                        total += v
                        hits += 1
            if hits:
                cell_l[y][x] = total / hits
                cell_a[y][x] = hits / (SS * SS)
    pixels = []
    for y in range(CELL):
        for x in range(CELL):
            a = cell_a[y][x]
            ring = 0.0
            for dy in (-2, -1, 0, 1, 2):
                for dx in (-2, -1, 0, 1, 2):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < CELL and 0 <= xx < CELL:
                        ring = max(ring, cell_a[yy][xx])
            ring *= 0.85
            # Composite the lit arrow over the black ring.
            out_a = a + ring * (1 - a)
            v = (cell_l[y][x] * a) / out_a if out_a > 0 else 0.0
            pixels.append((v, out_a))
    return pixels


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    target = os.path.join(here, "..", "..", "ChairPlus", "arrow.tga")
    side = CELL * GRID
    sheet = bytearray(side * side * 4)
    for i in range(FRAMES):
        angle = 2 * math.pi * i / FRAMES
        pixels = render(angle)
        ox, oy = (i % GRID) * CELL, (i // GRID) * CELL
        for y in range(CELL):
            for x in range(CELL):
                v, a = pixels[y * CELL + x]
                g = int(round(max(0.0, min(1.0, v)) * 255))
                off = ((oy + y) * side + (ox + x)) * 4
                sheet[off:off + 4] = bytes((g, g, g, int(round(a * 255))))
        print(f"frame {i + 1}/{FRAMES}", end="\r")
    # Uncompressed true-colour TGA, 32 bits, origin top left (descriptor 0x28).
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, side, side, 32, 0x28)
    with open(target, "wb") as f:
        f.write(header)
        f.write(sheet)
    print(f"\nwrote {os.path.normpath(target)}")


if __name__ == "__main__":
    main()
