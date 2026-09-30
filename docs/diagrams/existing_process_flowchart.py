"""Draws the Existing Emergency Response Process flowchart as SVG (no dependencies).

Run:  python existing_process_flowchart.py
Then existing_process_flowchart.svg is turned into PNG/PDF with Edge (see build.ps1).
"""

from pathlib import Path

LANES = [
    "Reporting Citizen",
    "Emergency Operations Center (EOC)\nCall Taker / Dispatcher",
    "CDRRMO / BFP\nResponse Unit",
    "PNP Station\n(Own Chain of Command)",
]
LANE_W = 330
HEADER_H = 90
ROW_H = 100
TOP = HEADER_H + 40
BOX_W, BOX_H = 240, 62
DEC_W, DEC_H = 210, 92

ORANGE = "#FF6B00"
INK = "#1E293B"
LINE = "#334155"
LANE_BG = ["#FFF7ED", "#FFFFFF", "#FFF7ED", "#FFFFFF"]

# id: (lane, row, shape, text)
NODES = {
    "start":    (0, 0, "terminal", "Emergency occurs"),
    "report":   (0, 1, "io", "Report by phone call,\nradio, text, or walk-in"),
    "receive":  (1, 2, "process", "Receive report and ask\nfor name, location, type"),
    "enough":   (1, 3, "decision", "Details complete\nand clear?"),
    "callback": (0, 3, "process", "Reporter is called back\nfor more details"),
    "identify": (1, 4, "process", "Identify type of emergency\nand agency needed"),
    "police":   (1, 5, "decision", "Police matter?\n(crime, accident)"),
    "pnprecv":  (3, 5, "process", "Station receives report\nrelayed by EOC"),
    "pnpchain": (3, 6, "process", "Report goes up the chain:\ndesk officer to duty /\nstation commander"),
    "pnpassign": (3, 7, "process", "Commander assigns\npatrol unit"),
    "pnprespond": (3, 8, "process", "Patrol responds\non scene"),
    "pnpresolve": (3, 9, "process", "Resolve incident and\nreturn to station"),
    "blotter":  (3, 10, "document", "Record incident in\npolice blotter (paper)"),
    "pnpend":   (3, 11, "terminal", "End"),
    "dispatch": (1, 6, "process", "Dispatch CDRRMO / BFP\nunit by radio"),
    "avail":    (1, 7, "decision", "Response unit\navailable?"),
    "travel":   (2, 8, "process", "Unit travels to scene\nusing verbal directions"),
    "monitor":  (1, 9, "process", "Monitor and coordinate\nunits by radio/phone"),
    "scene":    (2, 9, "process", "Respond on scene;\nupdates EOC by radio"),
    "support":  (2, 10, "decision", "Additional support\nneeded?"),
    "request":  (1, 10, "process", "Dispatch additional\nunits"),
    "resolve":  (2, 11, "process", "Resolve incident and\nreturn to station"),
    "paper":    (2, 12, "document", "Agency writes paper\nincident report / logbook"),
    "end":      (2, 13, "terminal", "End"),
}

# (from, to, label, style)  style: solid | dashed
EDGES = [
    ("start", "report", "", "solid"),
    ("report", "receive", "", "solid"),
    ("receive", "enough", "", "solid"),
    ("enough", "callback", "No", "solid"),
    ("callback", "receive", "", "solid"),
    ("enough", "identify", "Yes", "solid"),
    ("identify", "police", "", "solid"),
    ("police", "pnprecv", "Yes: relay by radio/phone", "solid"),
    ("pnprecv", "pnpchain", "", "solid"),
    ("pnpchain", "pnpassign", "", "solid"),
    ("pnpassign", "pnprespond", "", "solid"),
    ("pnprespond", "pnpresolve", "", "solid"),
    ("pnpresolve", "blotter", "", "solid"),
    ("blotter", "pnpend", "", "solid"),
    ("police", "dispatch", "No (fire, medical, rescue)", "solid"),
    ("dispatch", "avail", "", "solid"),
    ("avail", "dispatch", "No", "solid"),
    ("avail", "travel", "Yes", "solid"),
    ("travel", "scene", "", "solid"),
    ("scene", "monitor", "radio updates", "dashed"),
    ("scene", "support", "", "solid"),
    ("support", "request", "Yes", "solid"),
    ("request", "monitor", "", "solid"),
    ("support", "resolve", "No", "solid"),
    ("resolve", "paper", "", "solid"),
    ("paper", "end", "", "solid"),
]

ROWS = max(r for _, r, _, _ in NODES.values()) + 1
WIDTH = LANE_W * len(LANES)
HEIGHT = TOP + ROWS * ROW_H + 30


def center(node_id):
    lane, row, _, _ = NODES[node_id]
    return lane * LANE_W + LANE_W / 2, TOP + row * ROW_H + ROW_H / 2


def half_size(node_id):
    shape = NODES[node_id][2]
    return (DEC_W / 2, DEC_H / 2) if shape == "decision" else (BOX_W / 2, BOX_H / 2)


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text_block(x, y, text, size=13.5, weight=500, color=INK):
    lines = text.split("\n")
    lh = size * 1.25
    y0 = y - (len(lines) - 1) * lh / 2
    tspans = "".join(
        f'<tspan x="{x:.1f}" y="{y0 + i * lh:.1f}">{esc(l)}</tspan>' for i, l in enumerate(lines)
    )
    return (f'<text font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="middle" '
            f'dominant-baseline="middle">{tspans}</text>')


def shape_svg(node_id):
    lane, row, shape, text = NODES[node_id]
    x, y = center(node_id)
    w, h = BOX_W, BOX_H
    stroke = f'stroke="{LINE}" stroke-width="1.6"'
    if shape == "terminal":
        s = f'<rect x="{x - 90}" y="{y - 24}" width="180" height="48" rx="24" fill="{ORANGE}" stroke="none"/>'
        return s + text_block(x, y, text, 15, 700, "#FFFFFF")
    if shape == "process":
        s = f'<rect x="{x - w / 2}" y="{y - h / 2}" width="{w}" height="{h}" rx="6" fill="#FFFFFF" {stroke}/>'
    elif shape == "decision":
        s = (f'<polygon points="{x},{y - DEC_H / 2} {x + DEC_W / 2},{y} {x},{y + DEC_H / 2} {x - DEC_W / 2},{y}" '
             f'fill="#FFEDD5" {stroke}/>')
        return s + text_block(x, y, text, 12.5, 600)
    elif shape == "io":
        k = 16
        s = (f'<polygon points="{x - w / 2 + k},{y - h / 2} {x + w / 2 + k},{y - h / 2} '
             f'{x + w / 2 - k},{y + h / 2} {x - w / 2 - k},{y + h / 2}" fill="#FFFFFF" {stroke}/>')
    elif shape == "document":
        top, bot, l, r = y - h / 2, y + h / 2 - 6, x - w / 2, x + w / 2
        s = (f'<path d="M{l},{top} H{r} V{bot} C{r - w * 0.25},{bot + 14} {x},{bot - 12} {x - w * 0.2},{bot + 2} '
             f'S{l + 20},{bot + 10} {l},{bot} Z" fill="#FFFFFF" {stroke}/>')
        return s + text_block(x, y - 3, text)
    return s + text_block(x, y, text)


def edge_svg(a, b, label, style):
    (ax, ay), (bx, by) = center(a), center(b)
    (aw, ah), (bw, bh) = half_size(a), half_size(b)
    dash = ' stroke-dasharray="7 5"' if style == "dashed" else ""
    same_lane = NODES[a][0] == NODES[b][0]
    same_row = NODES[a][1] == NODES[b][1]

    if same_lane and by > ay:                       # straight down
        pts = [(ax, ay + ah), (bx, by - bh)]
        lx, ly = ax + 10, ay + ah + 14
        anchor = "start"
    elif same_row:                                  # straight across
        sx = ax + aw if bx > ax else ax - aw
        ex = bx - bw if bx > ax else bx + bw
        if NODES[b][2] == "io":
            ex += -12 if bx > ax else 12
        pts = [(sx, ay), (ex, by)]
        lx, ly = (sx + ex) / 2, ay - 9
        anchor = "middle"
    elif not same_lane and by > ay:                 # across then down
        sx = ax + aw if bx > ax else ax - aw
        pts = [(sx, ay), (bx, ay), (bx, by - bh)]
        lx, ly = (sx + bx) / 2, ay - 9
        anchor = "middle"
    else:                                           # loop back up into the side of b
        side = -1 if bx < ax or (same_lane) else 1
        gx = bx + side * (bw + 22) if not same_lane else ax - aw - 22
        if not same_lane:
            gx = (ax + bx) / 2 if abs(ax - bx) > LANE_W / 2 else gx
        # leave a from its top, go up to b's row, enter b from the side facing a
        enter_x = bx + bw if ax > bx else bx - bw
        pts = [(ax, ay - ah), (ax, by + ROW_H * 0.0), (enter_x, by)] if not same_lane else \
              [(ax - aw, ay), (gx, ay), (gx, by), (bx - bw, by)]
        if not same_lane:
            pts = [(ax, ay - ah), (ax, by), (enter_x, by)]
        if same_lane:  # label sits outside the shape, left of where the loop leaves it
            lx, ly, anchor = pts[0][0] - 6, pts[0][1] - 8, "end"
        else:
            lx, ly, anchor = pts[0][0] + 8, pts[0][1] - 8, "start"

    d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    out = (f'<path d="{d}" fill="none" stroke="{LINE}" stroke-width="1.6"{dash} '
           f'marker-end="url(#arrow)"/>')
    if label:
        out += (f'<text x="{lx:.1f}" y="{ly:.1f}" font-size="12" font-weight="700" fill="{ORANGE}" '
                f'text-anchor="{anchor}">{esc(label)}</text>')
    return out


def build():
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" '
        f'viewBox="0 0 {WIDTH} {HEIGHT}" font-family="Segoe UI, Arial, sans-serif">',
        f'<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" '
        f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{LINE}"/></marker></defs>',
        f'<rect width="{WIDTH}" height="{HEIGHT}" fill="#FFFFFF"/>',
        text_block(WIDTH / 2, 26, "Existing Emergency Response Process", 22, 800),
    ]
    for i, name in enumerate(LANES):
        x = i * LANE_W
        parts.append(f'<rect x="{x}" y="{HEADER_H - 40}" width="{LANE_W}" height="{HEIGHT - HEADER_H + 40}" '
                     f'fill="{LANE_BG[i]}" stroke="#CBD5E1"/>')
        parts.append(f'<rect x="{x}" y="{HEADER_H - 40}" width="{LANE_W}" height="70" fill="{INK}" stroke="#CBD5E1"/>')
        parts.append(text_block(x + LANE_W / 2, HEADER_H - 5, name, 14, 700, "#FFFFFF"))
    for a, b, label, style in EDGES:
        parts.append(edge_svg(a, b, label, style))
    for node_id in NODES:
        parts.append(shape_svg(node_id))
    parts.append("</svg>")
    return "\n".join(parts)


if __name__ == "__main__":
    out = Path(__file__).with_suffix(".svg")
    out.write_text(build(), encoding="utf-8")
    print(f"wrote {out} ({WIDTH}x{HEIGHT})")
