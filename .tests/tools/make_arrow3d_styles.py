# Renders the 3D waypoint arrow styles other than the original bevel arrow:
#   python .tests/tools/make_arrow3d_styles.py [style ...]
# writes ChairPlus/arrow3d_<style>.tga for each (all of them with no argument).
#
# The same sheet layout and look as arrow.tga from make_arrow.py -- 8x8 cells
# of 128px, cell i turned i/64 of a turn counter-clockwise, seen from the same
# tilt and lit from the same side -- so the addon draws them exactly the way
# it draws the original. Only the mesh differs:
#
#   needle    a faceted compass needle: a ridge down its length, the tail half
#             darker so which end points is never in doubt
#   dart      a GPS dart with a notched tail, extruded and bevelled
#   chevron   two stacked chevrons, extruded and bevelled
#   triangle  a faceted triangle with a ridge from tip to base
#
# Pure Python, like the others. Each sheet takes a few minutes; run the styles
# in parallel if you are in a hurry.
import math, os, struct, sys

CELL = 128
GRID = 8
FRAMES = GRID * GRID
SS = 3
ELEVATION = math.radians(52)
WALL_H, TOP_H = 0.16, 0.26


def inset(poly, d):
    """Offset a counter-clockwise polygon inward by d (mitred corners)."""
    n = len(poly)
    lines = []
    for i in range(n):
        (x1, y1), (x2, y2) = poly[i], poly[(i + 1) % n]
        ex, ey = x2 - x1, y2 - y1
        length = math.hypot(ex, ey)
        nx, ny = -ey / length, ex / length
        lines.append(((x1 + nx * d, y1 + ny * d), (ex, ey)))
    out = []
    for i in range(n):
        (p, r), (q, s) = lines[i - 1], lines[i]
        cross = r[0] * s[1] - r[1] * s[0]
        t = ((q[0] - p[0]) * s[1] - (q[1] - p[1]) * s[0]) / cross
        out.append((p[0] + r[0] * t, p[1] + r[1] * t))
    return out


def ccw(poly):
    area = sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
               for i in range(len(poly)))
    return poly if area > 0 else list(reversed(poly))


def ear_clip(poly):
    """Triangles covering a simple counter-clockwise polygon."""
    pts = list(poly)
    tris = []

    def is_convex(a, b, c):
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) > 1e-12

    def inside(p, a, b, c):
        d1 = (p[0] - b[0]) * (a[1] - b[1]) - (a[0] - b[0]) * (p[1] - b[1])
        d2 = (p[0] - c[0]) * (b[1] - c[1]) - (b[0] - c[0]) * (p[1] - c[1])
        d3 = (p[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (p[1] - a[1])
        neg = d1 < 0 or d2 < 0 or d3 < 0
        pos = d1 > 0 or d2 > 0 or d3 > 0
        return not (neg and pos)

    guard = 0
    while len(pts) > 3 and guard < 1000:
        guard += 1
        n = len(pts)
        for i in range(n):
            a, b, c = pts[i - 1], pts[i], pts[(i + 1) % n]
            if not is_convex(a, b, c):
                continue
            if any(inside(p, a, b, c) for p in pts if p not in (a, b, c)):
                continue
            tris.append((a, b, c))
            del pts[i]
            break
    tris.append(tuple(pts))
    return tris


def extruded(outline, bevel, albedo=lambda x, y: 1.0):
    """A slab: side walls, a bevel, and a flat top. (triangle, albedo) pairs."""
    outline = ccw(outline)
    inner = inset(outline, bevel)
    out = []
    n = len(outline)
    for i in range(n):
        a, b = outline[i], outline[(i + 1) % n]
        ia, ib = inner[i], inner[(i + 1) % n]
        A0, B0 = (a[0], a[1], 0.0), (b[0], b[1], 0.0)
        A1, B1 = (a[0], a[1], WALL_H), (b[0], b[1], WALL_H)
        IA, IB = (ia[0], ia[1], TOP_H), (ib[0], ib[1], TOP_H)
        for tri in ((A0, B0, B1), (A0, B1, A1), (A1, B1, IB), (A1, IB, IA)):
            cx = sum(p[0] for p in tri) / 3
            cy = sum(p[1] for p in tri) / 3
            out.append((tri, albedo(cx, cy)))
    for a, b, c in ear_clip(inner):
        tri = ((a[0], a[1], TOP_H), (b[0], b[1], TOP_H), (c[0], c[1], TOP_H))
        cx, cy = (a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3
        out.append((tri, albedo(cx, cy)))
    return out


def ridged(outline, ridge_from, ridge_to, ridge_h, albedo=lambda x, y: 1.0):
    """Side walls up to WALL_H, then every edge slopes up to a ridge line."""
    outline = ccw(outline)
    out = []
    n = len(outline)
    rf = (ridge_from[0], ridge_from[1], ridge_h)
    rt = (ridge_to[0], ridge_to[1], ridge_h)

    def nearest_ridge(p):
        # The ridge point a top vertex of edge p slopes to: its projection on
        # the ridge line, clamped to the ridge's ends.
        dx, dy = rt[0] - rf[0], rt[1] - rf[1]
        length2 = dx * dx + dy * dy or 1.0
        t = max(0.0, min(1.0, ((p[0] - rf[0]) * dx + (p[1] - rf[1]) * dy) / length2))
        return (rf[0] + dx * t, rf[1] + dy * t, ridge_h)

    for i in range(n):
        a, b = outline[i], outline[(i + 1) % n]
        A0, B0 = (a[0], a[1], 0.0), (b[0], b[1], 0.0)
        A1, B1 = (a[0], a[1], WALL_H), (b[0], b[1], WALL_H)
        RA, RB = nearest_ridge(a), nearest_ridge(b)
        tris = [(A0, B0, B1), (A0, B1, A1), (A1, B1, RB)]
        if RA != RB:
            tris.append((A1, RB, RA))
        for tri in tris:
            cx = sum(p[0] for p in tri) / 3
            cy = sum(p[1] for p in tri) / 3
            out.append((tri, albedo(cx, cy)))
    return out


CHEVRON_A = [(0.0, 1.0), (-0.78, 0.22), (-0.78, -0.08), (0.0, 0.62), (0.78, -0.08), (0.78, 0.22)]
CHEVRON_B = [(0.0, 0.25), (-0.78, -0.53), (-0.78, -0.83), (0.0, -0.13), (0.78, -0.83), (0.78, -0.53)]

STYLES = {
    "needle": lambda: ridged([(0.0, 1.0), (-0.3, 0.0), (0.0, -1.0), (0.3, 0.0)],
                             (0.0, 1.0), (0.0, -1.0), 0.42,
                             albedo=lambda x, y: 1.0 if y > 0 else 0.5),
    "dart": lambda: extruded([(0.0, 1.0), (-0.72, -0.85), (0.0, -0.45), (0.72, -0.85)], 0.07),
    "chevron": lambda: extruded(CHEVRON_A, 0.06) + extruded(CHEVRON_B, 0.06),
    "triangle": lambda: ridged([(0.0, 0.95), (-0.8, -0.75), (0.8, -0.75)],
                               (0.0, 0.95), (0.0, -0.75), 0.5),
}

LIGHT = (-0.45, 0.35, 0.82)
_l = math.sqrt(sum(c * c for c in LIGHT))
LIGHT = tuple(c / _l for c in LIGHT)
VIEW = (0.0, -math.cos(ELEVATION), math.sin(ELEVATION))


def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def norm(v):
    length = math.sqrt(dot(v, v)) or 1.0
    return (v[0] / length, v[1] / length, v[2] / length)


def render(mesh, angle):
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

    for tri, albedo in mesh:
        w = [turn(p) for p in tri]
        nrm = norm(cross(sub(w[1], w[0]), sub(w[2], w[0])))
        if dot(nrm, VIEW) < 0:
            nrm = (-nrm[0], -nrm[1], -nrm[2])
        diffuse = max(0.0, dot(nrm, LIGHT))
        half = norm((LIGHT[0] + VIEW[0], LIGHT[1] + VIEW[1], LIGHT[2] + VIEW[2]))
        spec = max(0.0, dot(nrm, half)) ** 24
        shade = min(1.0, (0.30 + 0.62 * diffuse) * albedo + 0.35 * spec)

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
            out_a = a + ring * (1 - a)
            v = (cell_l[y][x] * a) / out_a if out_a > 0 else 0.0
            pixels.append((v, out_a))
    return pixels


def build(style):
    here = os.path.dirname(os.path.abspath(__file__))
    target = os.path.normpath(os.path.join(here, "..", "..", "ChairPlus", f"arrow3d_{style}.tga"))
    mesh = STYLES[style]()
    side = CELL * GRID
    sheet = bytearray(side * side * 4)
    for i in range(FRAMES):
        pixels = render(mesh, 2 * math.pi * i / FRAMES)
        ox, oy = (i % GRID) * CELL, (i // GRID) * CELL
        for y in range(CELL):
            for x in range(CELL):
                v, a = pixels[y * CELL + x]
                g = int(round(max(0.0, min(1.0, v)) * 255))
                off = ((oy + y) * side + (ox + x)) * 4
                sheet[off:off + 4] = bytes((g, g, g, int(round(a * 255))))
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, side, side, 32, 0x28)
    with open(target, "wb") as f:
        f.write(header)
        f.write(sheet)
    print("wrote", target)


if __name__ == "__main__":
    for name in (sys.argv[1:] or list(STYLES)):
        build(name)
