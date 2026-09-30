"""Draws the ResQ Context Diagram (DFD level 0) as SVG (no dependencies).

Render to PNG/PDF with:  .\\build.ps1 context_diagram
"""

import math
from pathlib import Path

W, H = 1700, 1300
CX, CY, R = W / 2, H / 2 + 20, 165
BOX_W, BOX_H = 250, 86

ORANGE = "#FF6B00"
INK = "#1E293B"
LINE = "#334155"
TO_SYS = "#FF6B00"     # data flowing into ResQ
FROM_SYS = "#2563EB"   # data flowing out of ResQ

# name, (x, y), kind  (kind: user | device | service)
ENTITIES = {
    "superadmin": ("Super Admin\n(EOC)", (CX, 150), "user"),
    "citizen": ("Citizen /\nResident", (190, CY), "user"),
    "admin": ("Department Admin\n(BFP / PNP / CDRRMO)", (W - 190, CY), "user"),
    "tracker": ("GPS Tracker\n(ESP32 in response vehicle)", (CX, H - 110), "device"),
    "email": ("Email Service\n(EmailJS)", (270, 200), "service"),
    "photos": ("Photo Storage\n(Cloudinary)", (270, H - 190), "service"),
    "maps": ("Map Provider\n(OpenStreetMap)", (W - 270, H - 190), "service"),
    "fbemail": ("Firebase Auth\nEmail", (W - 270, 200), "service"),
}

# (entity, direction, label, (label x, label y, text-anchor))
# direction: "in" = entity -> ResQ, "out" = ResQ -> entity
FLOWS = [
    ("citizen", "in", "Registration & login details\nEmergency report (type, location,\ndescription, photos)", (500, 600, "middle")),
    ("citizen", "out", "Incident status updates\nDispatched unit & live location\nNotifications", (500, 740, "middle")),
    ("admin", "in", "Accept / dispatch / complete incident\nVehicle assignments, settings", (1200, 730, "middle")),
    ("admin", "out", "Incident alerts & queue\nLive vehicle locations\nDashboard & activity logs", (1200, 600, "middle")),
    ("superadmin", "in", "Account & department\nmanagement, settings", (880, 330, "start")),
    ("superadmin", "out", "All incidents, dashboard metrics\nAudit logs & reports (PDF/ZIP/CSV)", (815, 330, "end")),
    ("tracker", "in", "GPS location (latitude, longitude,\nspeed, satellites), tracker ID", (868, 960, "start")),
    ("email", "out", "Login code (OTP)\nto send to user", (480, 410, "end")),
    ("photos", "out", "Incident photos", (470, 830, "end")),
    ("photos", "in", "Photo links (URLs)", (585, 930, "start")),
    ("maps", "in", "Map tiles", (1180, 860, "start")),
    ("fbemail", "out", "Password reset request", (1200, 430, "start")),
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


def box_edge(x, y, dx, dy):
    """Point where a ray from the box centre in direction (dx, dy) leaves the box."""
    tx = (BOX_W / 2) / abs(dx) if dx else math.inf
    ty = (BOX_H / 2) / abs(dy) if dy else math.inf
    t = min(tx, ty)
    return x + dx * t, y + dy * t


def flows_svg():
    out = []
    by_entity = {}
    for ent, direction, label, pos in FLOWS:
        by_entity.setdefault(ent, []).append((direction, label, pos))

    for ent, items in by_entity.items():
        _, (ex, ey), _ = ENTITIES[ent]
        dx, dy = CX - ex, CY - ey
        dist = math.hypot(dx, dy)
        ux, uy = dx / dist, dy / dist          # entity -> system
        px, py = -uy, ux                       # perpendicular
        start = box_edge(ex, ey, ux, uy)
        end = (CX - ux * R, CY - uy * R)

        for i, (direction, label, pos) in enumerate(items):
            off = 0 if len(items) == 1 else (-16 if i == 0 else 16)
            a = (start[0] + px * off, start[1] + py * off)
            b = (end[0] + px * off, end[1] + py * off)
            if direction == "out":
                a, b = b, a
            color = TO_SYS if direction == "in" else FROM_SYS
            out.append(f'<line x1="{a[0]:.1f}" y1="{a[1]:.1f}" x2="{b[0]:.1f}" y2="{b[1]:.1f}" '
                       f'stroke="{color}" stroke-width="2.2" marker-end="url(#arrow-{direction})"/>')

            lx, ly, anchor = pos
            out.append(text_block(lx, ly, label, 12.5, 600, color, anchor))
    return "\n".join(out)


def entity_svg(key):
    name, (x, y), kind = ENTITIES[key]
    fill = {"user": "#FFFFFF", "device": "#FFF7ED", "service": "#F1F5F9"}[kind]
    dash = ' stroke-dasharray="6 4"' if kind == "service" else ""
    return (f'<rect x="{x - BOX_W / 2}" y="{y - BOX_H / 2}" width="{BOX_W}" height="{BOX_H}" rx="4" '
            f'fill="{fill}" stroke="{INK}" stroke-width="2"{dash}/>' + text_block(x, y, name, 15, 700))


def legend_svg():
    x, y = 40, H - 120
    return "\n".join([
        f'<rect x="{x}" y="{y}" width="330" height="96" rx="8" fill="#FFFFFF" stroke="#CBD5E1"/>',
        f'<line x1="{x + 16}" y1="{y + 24}" x2="{x + 66}" y2="{y + 24}" stroke="{TO_SYS}" stroke-width="2.2" marker-end="url(#arrow-in)"/>',
        f'<text x="{x + 78}" y="{y + 28}" font-size="13" fill="{INK}">Data going into ResQ</text>',
        f'<line x1="{x + 16}" y1="{y + 50}" x2="{x + 66}" y2="{y + 50}" stroke="{FROM_SYS}" stroke-width="2.2" marker-end="url(#arrow-out)"/>',
        f'<text x="{x + 78}" y="{y + 54}" font-size="13" fill="{INK}">Data coming out of ResQ</text>',
        f'<rect x="{x + 16}" y="{y + 66}" width="50" height="18" fill="#F1F5F9" stroke="{INK}" stroke-dasharray="6 4"/>',
        f'<text x="{x + 78}" y="{y + 80}" font-size="13" fill="{INK}">External service</text>',
    ])


def build():
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
        f'font-family="Segoe UI, Arial, sans-serif">',
        "<defs>" + "".join(
            f'<marker id="arrow-{d}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
            f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>'
            for d, c in (("in", TO_SYS), ("out", FROM_SYS))) + "</defs>",
        f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>',
        text_block(W / 2, 40, "Context Diagram of ResQ", 26, 800),
        flows_svg(),
        f'<circle cx="{CX}" cy="{CY}" r="{R}" fill="{ORANGE}" stroke="#C2410C" stroke-width="3"/>',
        text_block(CX, CY - 88, "0", 20, 800, "#FFFFFF"),
        f'<line x1="{CX - 120}" y1="{CY - 62}" x2="{CX + 120}" y2="{CY - 62}" stroke="#FFFFFF" stroke-width="2" opacity="0.8"/>',
        text_block(CX, CY + 10, "ResQ\nEmergency Response\nSystem", 20, 800, "#FFFFFF"),
        *(entity_svg(k) for k in ENTITIES),
        legend_svg(),
        "</svg>",
    ]
    return "\n".join(parts)


if __name__ == "__main__":
    out = Path(__file__).with_suffix(".svg")
    out.write_text(build(), encoding="utf-8")
    print(f"wrote {out} ({W}x{H})")
