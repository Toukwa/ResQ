"""Draws the ResQ Level 1 Data Flow Diagram (Gane & Sarson notation) as SVG.

Render to PNG/PDF with:  .\\build.ps1 dfd_level1
"""

import math
from pathlib import Path

W, H = 2420, 1720

ORANGE = "#FF6B00"
INK = "#1E293B"
LINE = "#334155"
FLOW = "#475569"
LABEL = "#1D4ED8"

# id: (kind, text, x, y)   kind: ext | proc | store
NODES = {
    # external entities (same as the context diagram)
    "email":   ("ext", "Email Service\n(EmailJS)", 220, 110),
    "fbemail": ("ext", "Firebase Auth\nEmail", 220, 330),
    "citizen": ("ext", "Citizen /\nResident", 220, 700),
    "photos":  ("ext", "Photo Storage\n(Cloudinary)", 220, 1080),
    "super":   ("ext", "Super Admin\n(EOC)", 2230, 220),
    "admin":   ("ext", "Department Admin\n(BFP / PNP / CDRRMO)", 2230, 700),
    "tracker": ("ext", "GPS Tracker\n(ESP32 in vehicle)", 2230, 1260),
    "maps":    ("ext", "Map Provider\n(OpenStreetMap)", 2230, 1580),
    # processes
    "p1": ("proc", "1.0|Authenticate &\nManage Users", 720, 220),
    "p2": ("proc", "2.0|Submit Emergency\nRequest", 720, 700),
    "p3": ("proc", "3.0|Manage & Dispatch\nIncidents", 1660, 700),
    "p4": ("proc", "4.0|Track Response\nVehicles", 1660, 1420),
    "p5": ("proc", "5.0|Send Notifications\n& Live Updates", 1170, 1030),
    "p6": ("proc", "6.0|Generate Reports\n& Logs", 1660, 220),
    # data stores
    "d1": ("store", "D1|Users", 1170, 220),
    "d2": ("store", "D2|Incidents", 1170, 700),
    "d3": ("store", "D3|Dispatches", 1660, 1030),
    "d4": ("store", "D4|Vehicles & Trackers", 1170, 1420),
    "d5": ("store", "D5|Notifications", 720, 1030),
    "d6": ("store", "D6|System Logs", 1660, 460),
}

SIZE = {"ext": (230, 84), "proc": (250, 116), "store": (250, 54)}

# (from, to, label, label (x, y, anchor), options)
#   options: off = shift a straight flow sideways (for in/out pairs), via = waypoints
FLOWS = [
    # 1.0 Authenticate & Manage Users
    ("citizen", "p1", "Registration & login\ndetails, OTP entered", None, {"off": -14}),
    ("p1", "citizen", "Login result", None, {"off": 14}),
    ("p1", "email", "Login code (OTP)", None, {}),
    ("p1", "fbemail", "Password reset request", None, {}),
    ("p1", "d1", "New / updated\nprofile, settings", None, {"off": -14}),
    ("d1", "p1", "User record, role", None, {"off": 14}),
    ("super", "p1", "Account & department changes", (1420, 58, "middle"),
     {"via": [(2230, 70), (720, 70)]}),
    ("p1", "d6", "Log entries", None, {}),

    # 2.0 Submit Emergency Request
    ("citizen", "p2", "Emergency report (type, location,\ndescription, photos)", None, {"off": -14}),
    ("p2", "citizen", "Request status", None, {"off": 14}),
    ("p2", "photos", "Incident photos", None, {"off": -14}),
    ("photos", "p2", "Photo URLs", None, {"off": 14}),
    ("d1", "p2", "Reporter details", None, {}),
    ("p2", "d2", "New incident record", None, {"off": -14}),
    ("d2", "p2", "Incident status", None, {"off": 14}),
    ("p2", "p5", "New-incident event", None, {}),
    ("p2", "d6", "Log entries", None, {}),

    # 3.0 Manage & Dispatch Incidents
    ("d2", "p3", "Pending incidents", None, {"off": -14}),
    ("p3", "d2", "Status updates", None, {"off": 14}),
    ("admin", "p3", "Accept / dispatch /\ncomplete decisions", None, {"off": -14}),
    ("p3", "admin", "Incident queue & details", None, {"off": 14}),
    ("p3", "d3", "Dispatch record", None, {}),
    ("p3", "d6", "Log entries", None, {}),
    ("d4", "p3", "Available vehicles", (1352, 1216, "start"), {"off": -14}),
    ("p3", "d4", "Vehicle status", (1250, 1216, "end"), {"off": 14}),
    ("p3", "p5", "Status & dispatch\nevents", None, {}),

    # 4.0 Track Response Vehicles
    ("tracker", "p4", "GPS location\n(lat, long, speed)", None, {}),
    ("admin", "p4", "Vehicle details &\nassignments", None, {}),
    ("maps", "p4", "Map tiles", None, {}),
    ("p4", "d4", "Tracker location,\nvehicle data", None, {"off": -14}),
    ("d4", "p4", "Vehicle list", None, {"off": 14}),

    # 5.0 Send Notifications & Live Updates
    ("d3", "p5", "Dispatched\nunits", (1532, 1066, "end"), {}),
    ("d4", "p5", "Live vehicle\nlocation", (1153, 1239, "end"), {}),
    ("p5", "d5", "Notification record", None, {}),
    ("p5", "admin", "Alerts & live updates", (1943, 818, "middle"), {}),
    ("p5", "citizen", "Dispatched unit &\nlive location", None, {}),

    # 6.0 Generate Reports & Logs
    ("d6", "p6", "Audit log entries", None, {}),
    ("d1", "p6", "User data", None, {}),
    ("d2", "p6", "Incident data", None, {}),
    ("p6", "super", "Dashboard, audit reports\n(PDF / ZIP / CSV)", None, {}),
    ("p6", "admin", "Dashboard &\nactivity logs", None, {}),
]


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text_block(x, y, text, size=14, weight=500, color=INK, anchor="middle"):
    lines = text.split("\n")
    lh = size * 1.25
    y0 = y - (len(lines) - 1) * lh / 2
    tspans = "".join(f'<tspan x="{x:.1f}" y="{y0 + i * lh:.1f}">{esc(l)}</tspan>' for i, l in enumerate(lines))
    return (f'<text font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}" '
            f'dominant-baseline="middle">{tspans}</text>')


def clip(node, tx, ty):
    """Where the line from the node centre toward (tx, ty) leaves the node's box."""
    kind, _, x, y = NODES[node]
    w, h = SIZE[kind]
    dx, dy = tx - x, ty - y
    if dx == 0 and dy == 0:
        return x, y
    sx = (w / 2) / abs(dx) if dx else math.inf
    sy = (h / 2) / abs(dy) if dy else math.inf
    s = min(sx, sy)
    return x + dx * s, y + dy * s


def flow_svg(a, b, label, pos, opts):
    ax, ay = NODES[a][2], NODES[a][3]
    bx, by = NODES[b][2], NODES[b][3]
    via = opts.get("via", [])
    off = opts.get("off", 0)

    if via:
        pts = [clip(a, *via[0]), *via, clip(b, *via[-1])]
        nx, ny, side = 0, -1, 1
    else:
        d = math.hypot(bx - ax, by - ay)
        # Normal based on a fixed ordering of the two nodes, so the "in" and "out"
        # flows of a pair land on opposite sides instead of on top of each other.
        (cx1, cy1), (cx2, cy2) = sorted([(ax, ay), (bx, by)])
        nx, ny = -(cy2 - cy1) / d, (cx2 - cx1) / d
        if ny > 0 or (ny == 0 and nx < 0):
            nx, ny = -nx, -ny           # normal points up (or right for vertical lines)
        side = -1 if off < 0 else 1
        shift = abs(off) * side
        sx, sy = nx * shift, ny * shift
        start = clip(a, bx, by)
        end = clip(b, ax, ay)
        pts = [(start[0] + sx, start[1] + sy), (end[0] + sx, end[1] + sy)]

    path = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    if pos is None:
        # beside the arrow's midpoint, on the side away from its partner
        (x1, y1), (x2, y2) = pts[0], pts[-1]
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        lines = label.count("\n") + 1
        gap = 10 + lines * 8
        lx, ly = mx + nx * side * gap, my + ny * side * gap
        if abs(nx) > 0.5:               # steep line: text to its left/right
            anchor = "start" if nx * side > 0 else "end"
            lx += 4 if anchor == "start" else -4
        else:
            anchor = "middle"
    else:
        lx, ly, anchor = pos
    return (f'<path d="{path}" fill="none" stroke="{FLOW}" stroke-width="1.8" marker-end="url(#arrow)"/>'
            + text_block(lx, ly, label, 12.5, 600, LABEL, anchor))

def node_svg(key):
    kind, text, x, y = NODES[key]
    w, h = SIZE[kind]
    l, t = x - w / 2, y - h / 2
    if kind == "ext":
        return (f'<rect x="{l + 6}" y="{t + 6}" width="{w}" height="{h}" fill="#CBD5E1"/>'
                f'<rect x="{l}" y="{t}" width="{w}" height="{h}" fill="#F8FAFC" stroke="{INK}" stroke-width="2"/>'
                + text_block(x, y, text, 15, 700))
    if kind == "proc":
        num, name = text.split("|")
        return (f'<rect x="{l}" y="{t}" width="{w}" height="{h}" rx="16" fill="#FFF7ED" stroke="{ORANGE}" stroke-width="2.5"/>'
                f'<path d="M{l},{t + 34} H{l + w}" stroke="{ORANGE}" stroke-width="2"/>'
                f'<path d="M{l + 16},{t} H{l + w - 16} Q{l + w},{t} {l + w},{t + 16} V{t + 34} H{l} V{t + 16} Q{l},{t} {l + 16},{t} Z" fill="{ORANGE}"/>'
                + text_block(x, t + 17, num, 15, 800, "#FFFFFF")
                + text_block(x, t + 34 + (h - 34) / 2, name, 15, 700))
    # data store: open-ended rectangle with an ID box on the left
    sid, name = text.split("|")
    return (f'<rect x="{l}" y="{t}" width="{w}" height="{h}" fill="#FFFFFF"/>'
            f'<path d="M{l + w},{t} H{l} V{t + h} H{l + w}" fill="none" stroke="{INK}" stroke-width="2"/>'
            f'<path d="M{l + 52},{t} V{t + h}" stroke="{INK}" stroke-width="2"/>'
            + text_block(l + 26, y, sid, 15, 800)
            + text_block(l + 52 + (w - 52) / 2, y, name, 14.5, 700))


def legend_svg():
    x, y = 40, H - 250
    return "\n".join([
        f'<rect x="{x}" y="{y}" width="360" height="225" rx="8" fill="#FFFFFF" stroke="#CBD5E1"/>',
        text_block(x + 180, y + 22, "Legend", 15, 800),
        f'<rect x="{x + 18}" y="{y + 44}" width="70" height="34" fill="#F8FAFC" stroke="{INK}" stroke-width="2"/>',
        f'<text x="{x + 104}" y="{y + 66}" font-size="13" fill="{INK}">External entity</text>',
        f'<rect x="{x + 18}" y="{y + 92}" width="70" height="40" rx="8" fill="#FFF7ED" stroke="{ORANGE}" stroke-width="2.5"/>',
        f'<text x="{x + 104}" y="{y + 116}" font-size="13" fill="{INK}">Process (numbered)</text>',
        f'<path d="M{x + 88},{y + 146} H{x + 18} V{y + 174} H{x + 88}" fill="none" stroke="{INK}" stroke-width="2"/>',
        f'<path d="M{x + 40},{y + 146} V{y + 174}" stroke="{INK}" stroke-width="2"/>',
        f'<text x="{x + 104}" y="{y + 164}" font-size="13" fill="{INK}">Data store (Firebase database)</text>',
        f'<path d="M{x + 18},{y + 200} H{x + 86}" stroke="{FLOW}" stroke-width="1.8" marker-end="url(#arrow)"/>',
        f'<text x="{x + 104}" y="{y + 204}" font-size="13" fill="{INK}">Data flow</text>',
    ])


def build():
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
        f'font-family="Segoe UI, Arial, sans-serif">',
        f'<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{FLOW}"/></marker></defs>',
        f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>',
        text_block(W / 2, 22, "Level 1 Data Flow Diagram of ResQ", 24, 800),
        *(flow_svg(*f) for f in FLOWS),
        *(node_svg(k) for k in NODES),
        legend_svg(),
        "</svg>",
    ]
    return "\n".join(parts)


if __name__ == "__main__":
    out = Path(__file__).with_suffix(".svg")
    out.write_text(build(), encoding="utf-8")
    print(f"wrote {out} ({W}x{H})")
