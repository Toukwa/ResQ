"""Draws the ResQ Activity Diagram (UML, with swimlanes) as SVG.

Render to PNG/PDF with:  .\\build.ps1 activity_diagram
"""

from pathlib import Path

LANES = [
    "Citizen\n(ResQ Mobile App)",
    "ResQ System",
    "Department Admin\n(BFP / PNP / CDRRMO)",
    "Response Unit\n(vehicle + GPS tracker)",
    "Super Admin\n(EOC)",
]
LANE_W = 290
LEFT = 20
HEADER_TOP, HEADER_H = 56, 62
TOP = HEADER_TOP + HEADER_H + 34
ROW_H = 76
ACT_W, ACT_H = 232, 52
DEC_W, DEC_H = 190, 60

ORANGE = "#FF6B00"
INK = "#1E293B"
LINE = "#334155"
GUARD = "#C2410C"
LANE_BG = ["#FFF7ED", "#FFFFFF", "#FFF7ED", "#FFFFFF", "#FFF7ED"]

# id: (kind, lane, row, text)   kind: init | final | flowfinal | action | decision | bar
# bars use lane = (first lane, last lane)
NODES = {
    "init":     ("init", 0, 0, ""),
    "login":    ("action", 0, 1, "Log in (email code)"),
    "fill":     ("action", 0, 2, "Fill in emergency report\n(type, description)"),
    "gps":      ("action", 0, 3, "Capture GPS location,\nattach photos"),
    "valid":    ("decision", 0, 4, "Details\ncomplete?"),
    "submit":   ("action", 0, 5, "Submit request"),
    "upload":   ("action", 1, 6, "Upload photos"),
    "save":     ("action", 1, 7, "Save incident\n(status: Pending)"),
    "depts":    ("action", 1, 8, "Identify involved\ndepartments"),
    "fork1":    ("bar", (0, 2), 9, ""),
    "pending":  ("action", 0, 10, "Track status: Pending"),
    "alert":    ("action", 2, 10, "Receive real-time alert;\nreview details, photos, map"),
    "accept":   ("decision", 2, 11, "Accept?"),
    "declined": ("action", 1, 11, "Record Declined;\nnotify citizen"),
    "seedecl":  ("action", 0, 11, "View status: Declined"),
    "end1":     ("flowfinal", 0, 12, ""),
    "select":   ("action", 2, 12, "Select available unit\non live map"),
    "dispatch": ("action", 2, 13, "Dispatch unit"),
    "record":   ("action", 1, 13, "Create dispatch record;\nset unit En Route"),
    "fork2":    ("bar", (0, 3), 14, ""),
    "viewunit": ("action", 0, 15, "View dispatched unit\nand live location"),
    "livemap":  ("action", 1, 15, "Stream tracker GPS\nto live map"),
    "monitor":  ("action", 2, 15, "Monitor unit\non live map"),
    "travel":   ("action", 3, 15, "Receive order;\ntravel to scene"),
    "respond":  ("action", 3, 16, "Arrive and respond\non scene"),
    "join2":    ("bar", (0, 3), 17, ""),
    "more":     ("decision", 2, 18, "More units\nneeded?"),
    "complete": ("action", 2, 19, "Mark incident\nCompleted"),
    "finish":   ("action", 1, 19, "Set units Available;\nupdate overall status"),
    "audit":    ("action", 1, 20, "Save incident record\nand audit log"),
    "fork3":    ("bar", (0, 4), 21, ""),
    "resolved": ("action", 0, 22, "View status: Resolved"),
    "end2":     ("flowfinal", 0, 23, ""),
    "dash":     ("action", 4, 22, "Review dashboard\nand activity logs"),
    "export":   ("action", 4, 23, "Export audit report\n(PDF + photos ZIP / CSV)"),
    "end":      ("final", 4, 24, ""),
}

# (from, to, guard)
EDGES = [
    ("init", "login", ""), ("login", "fill", ""), ("fill", "gps", ""), ("gps", "valid", ""),
    ("valid", "fill", "[No]"), ("valid", "submit", "[Yes]"),
    ("submit", "upload", ""), ("upload", "save", ""), ("save", "depts", ""), ("depts", "fork1", ""),
    ("fork1", "pending", ""), ("fork1", "alert", ""),
    ("alert", "accept", ""),
    ("accept", "declined", "[No]"), ("declined", "seedecl", ""), ("seedecl", "end1", ""),
    ("accept", "select", "[Yes]"), ("select", "dispatch", ""), ("dispatch", "record", ""),
    ("record", "fork2", ""),
    ("fork2", "viewunit", ""), ("fork2", "livemap", ""), ("fork2", "monitor", ""), ("fork2", "travel", ""),
    ("travel", "respond", ""),
    ("viewunit", "join2", ""), ("livemap", "join2", ""), ("monitor", "join2", ""), ("respond", "join2", ""),
    ("join2", "more", ""),
    ("more", "select", "[Yes]"), ("more", "complete", "[No]"),
    ("complete", "finish", ""), ("finish", "audit", ""), ("audit", "fork3", ""),
    ("fork3", "resolved", ""), ("resolved", "end2", ""),
    ("fork3", "dash", ""), ("dash", "export", ""), ("export", "end", ""),
]

ROWS = max(n[2] for n in NODES.values()) + 1
W = LEFT * 2 + LANE_W * len(LANES)
H = TOP + ROWS * ROW_H + 30


def lane_x(lane):
    return LEFT + lane * LANE_W + LANE_W / 2


def row_y(row):
    return TOP + row * ROW_H + ROW_H / 2


def geom(nid):
    """Centre x, centre y, half width, half height."""
    kind, lane, row, _ = NODES[nid]
    y = row_y(row)
    if kind == "bar":
        x1, x2 = lane_x(lane[0]) - ACT_W / 2, lane_x(lane[1]) + ACT_W / 2
        return (x1 + x2) / 2, y, (x2 - x1) / 2, 4
    x = lane_x(lane)
    return x, y, *{"init": (13, 13), "final": (16, 16), "flowfinal": (15, 15),
                   "action": (ACT_W / 2, ACT_H / 2), "decision": (DEC_W / 2, DEC_H / 2)}[kind]


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text_block(x, y, text, size=13, weight=500, color=INK, anchor="middle"):
    lines = text.split("\n")
    lh = size * 1.22
    y0 = y - (len(lines) - 1) * lh / 2
    tspans = "".join(f'<tspan x="{x:.1f}" y="{y0 + i * lh:.1f}">{esc(l)}</tspan>' for i, l in enumerate(lines))
    return (f'<text font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}" '
            f'dominant-baseline="middle">{tspans}</text>')


def node_svg(nid):
    kind, _, _, label = NODES[nid]
    x, y, hw, hh = geom(nid)
    if kind == "init":
        return f'<circle cx="{x}" cy="{y}" r="13" fill="{INK}"/>'
    if kind == "final":
        return (f'<circle cx="{x}" cy="{y}" r="16" fill="#FFFFFF" stroke="{INK}" stroke-width="2.4"/>'
                f'<circle cx="{x}" cy="{y}" r="10" fill="{INK}"/>')
    if kind == "flowfinal":
        k = 10.5
        return (f'<circle cx="{x}" cy="{y}" r="15" fill="#FFFFFF" stroke="{INK}" stroke-width="2.4"/>'
                f'<path d="M{x - k},{y - k} L{x + k},{y + k} M{x + k},{y - k} L{x - k},{y + k}" stroke="{INK}" stroke-width="2.4"/>')
    if kind == "bar":
        return f'<rect x="{x - hw}" y="{y - hh}" width="{hw * 2}" height="{hh * 2}" rx="2" fill="{INK}"/>'
    if kind == "decision":
        return (f'<polygon points="{x},{y - hh} {x + hw},{y} {x},{y + hh} {x - hw},{y}" fill="#FFEDD5" '
                f'stroke="{ORANGE}" stroke-width="2"/>' + text_block(x, y, label, 12, 700))
    return (f'<rect x="{x - hw}" y="{y - hh}" width="{hw * 2}" height="{hh * 2}" rx="18" fill="#FFFFFF" '
            f'stroke="{ORANGE}" stroke-width="2"/>' + text_block(x, y, label, 12.5, 600))


def edge_svg(a, b, guard):
    ax, ay, aw, ah = geom(a)
    bx, by, bw, bh = geom(b)
    a_bar, b_bar = NODES[a][0] == "bar", NODES[b][0] == "bar"
    same_row = NODES[a][2] == NODES[b][2]
    lx = ly = None
    anchor = "start"

    if a_bar:                                   # fork: drop straight down at the target's x
        pts = [(bx, ay + ah), (bx, by - bh)]
    elif b_bar:                                 # join: drop straight down from the source's x
        pts = [(ax, ay + ah), (ax, by - bh)]
    elif same_row:                              # sideways
        sx = ax - aw if bx < ax else ax + aw
        ex = bx + bw if bx < ax else bx - bw
        pts = [(sx, ay), (ex, by)]
        lx, ly, anchor = (sx + ex) / 2, ay - 10, "middle"
    elif by > ay and abs(ax - bx) < 1:          # straight down
        pts = [(ax, ay + ah), (bx, by - bh)]
        lx, ly = ax + 8, (ay + ah + by - bh) / 2
    elif by > ay:                               # across, then down
        sx = ax + aw if bx > ax else ax - aw
        pts = [(sx, ay), (bx, ay), (bx, by - bh)]
    else:                                       # loop back up along the lane's left side
        gx = ax - max(aw, ACT_W / 2) - 20
        pts = [(ax - aw, ay), (gx, ay), (gx, by), (bx - bw, by)]
        lx, ly, anchor = ax - aw - 6, ay - 10, "end"

    d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    out = f'<path d="{d}" fill="none" stroke="{LINE}" stroke-width="1.7" marker-end="url(#arrow)"/>'
    if guard and lx is not None:
        out += text_block(lx, ly, guard, 12, 700, GUARD, anchor)
    return out


def legend_svg():
    x, y = W - 290 - LEFT, TOP + 1 * ROW_H + 10
    items = [
        (f'<circle cx="{x + 30}" cy="{{y}}" r="10" fill="{INK}"/>', "Start"),
        (f'<rect x="{x + 10}" y="{{y0}}" width="40" height="22" rx="10" fill="#FFFFFF" stroke="{ORANGE}" stroke-width="2"/>', "Activity / action"),
        (f'<polygon points="{x + 30},{{y0}} {x + 50},{{y}} {x + 30},{{y1}} {x + 10},{{y}}" fill="#FFEDD5" stroke="{ORANGE}" stroke-width="2"/>', "Decision [guard]"),
        (f'<rect x="{x + 6}" y="{{yb}}" width="48" height="7" fill="{INK}"/>', "Fork / join (parallel)"),
        (f'<circle cx="{x + 30}" cy="{{y}}" r="11" fill="#FFFFFF" stroke="{INK}" stroke-width="2"/><path d="M{x + 22},{{ya}} L{x + 38},{{yc}} M{x + 38},{{ya}} L{x + 22},{{yc}}" stroke="{INK}" stroke-width="2"/>', "Flow ends (this path)"),
        (f'<circle cx="{x + 30}" cy="{{y}}" r="11" fill="#FFFFFF" stroke="{INK}" stroke-width="2"/><circle cx="{x + 30}" cy="{{y}}" r="6.5" fill="{INK}"/>', "Activity ends"),
    ]
    out = [f'<rect x="{x}" y="{y}" width="270" height="{34 + len(items) * 34}" rx="8" fill="#FFFFFF" stroke="#CBD5E1"/>',
           text_block(x + 135, y + 18, "Legend", 13.5, 800)]
    for i, (shape, label) in enumerate(items):
        yy = y + 50 + i * 34
        out.append(shape.format(y=yy, y0=yy - 11, y1=yy + 11, yb=yy - 3.5, ya=yy - 8, yc=yy + 8))
        out.append(text_block(x + 66, yy, label, 12.5, 500, INK, "start"))
    return "\n".join(out)


def build():
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
        f'font-family="Segoe UI, Arial, sans-serif">',
        f'<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" '
        f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{LINE}"/></marker></defs>',
        f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>',
        text_block(W / 2, 28, "Activity Diagram of ResQ", 22, 800),
    ]
    for i, name in enumerate(LANES):
        x = LEFT + i * LANE_W
        parts.append(f'<rect x="{x}" y="{HEADER_TOP}" width="{LANE_W}" height="{H - HEADER_TOP - 14}" fill="{LANE_BG[i]}" stroke="#CBD5E1"/>')
        parts.append(f'<rect x="{x}" y="{HEADER_TOP}" width="{LANE_W}" height="{HEADER_H}" fill="{INK}" stroke="#CBD5E1"/>')
        parts.append(text_block(x + LANE_W / 2, HEADER_TOP + HEADER_H / 2, name, 13.5, 700, "#FFFFFF"))
    parts += [edge_svg(*e) for e in EDGES]
    parts += [node_svg(n) for n in NODES]
    parts.append(legend_svg())
    parts.append("</svg>")
    return "\n".join(parts)


if __name__ == "__main__":
    out = Path(__file__).with_suffix(".svg")
    out.write_text(build(), encoding="utf-8")
    print(f"wrote {out} ({W}x{H})")
