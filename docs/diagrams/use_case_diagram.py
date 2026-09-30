"""Draws the ResQ Use Case Diagram (UML) as SVG.

Render to PNG/PDF with:  .\\build.ps1 use_case_diagram
"""

import math
from pathlib import Path

W, H = 2020, 1560
BOUND = (470, 190, 1580, 1500)          # system boundary: left, top, right, bottom
UC_W, UC_H = 280, 62

ORANGE = "#FF6B00"
INK = "#1E293B"
LINE = "#475569"

# id: (label, x, y)   actors are drawn as stick figures, (x, y) = centre of the body
ACTORS = {
    "user":    ("User\n(all roles)", 1015, 92),
    "email":   ("Email Service\n(EmailJS)", 215, 380),
    "citizen": ("Citizen /\nResident", 215, 680),
    "tracker": ("GPS Tracker\n(ESP32)", 215, 1160),
    "admin":   ("Department Admin\n(BFP / PNP / CDRRMO)", 1805, 560),
    "staff":   ("Admin Staff", 1805, 1015),
    "super":   ("Super Admin\n(EOC)", 1805, 1335),
}

USE_CASES = {
    # common to every signed-in user
    "login":    ("Log In", 720, 260),
    "otp":      ("Verify Email Code\n(OTP)", 720, 380),
    "reset":    ("Reset Password", 1015, 260),
    "profile":  ("Update Profile &\nSettings", 1310, 260),
    # citizen
    "register": ("Register Account", 720, 520),
    "report":   ("Report Emergency", 720, 630),
    "photos":   ("Attach Photos", 1010, 715),
    "track":    ("Track Request Status", 720, 740),
    "unitloc":  ("View Dispatched\nUnit Location", 720, 850),
    # department admin
    "queue":    ("View Incident Queue", 1310, 400),
    "accept":   ("Accept / Decline\nIncident", 1310, 490),
    "dispatch": ("Dispatch Response Unit", 1310, 580),
    "status":   ("Update Incident Status", 1310, 670),
    "vehicles": ("Manage Vehicles", 1310, 760),
    # department admin + super admin
    "dashboard": ("View Dashboard", 1310, 880),
    "map":      ("Monitor Live\nVehicle Map", 1310, 970),
    "media":    ("View Evidence Photos", 1310, 1060),
    "logs":     ("View Activity Logs", 1310, 1150),
    # super admin
    "accounts": ("Manage User Accounts", 1310, 1270),
    "agencies": ("Manage Agencies", 1310, 1360),
    "export":   ("Export Audit Reports\n(PDF / ZIP / CSV)", 1310, 1450),
    # device
    "sendloc":  ("Send Vehicle Location", 720, 1160),
}

ASSOCIATIONS = [
    ("user", ["login", "reset", "profile"]),
    ("email", ["otp"]),
    ("citizen", ["register", "report", "track", "unitloc"]),
    ("tracker", ["sendloc"]),
    ("admin", ["queue", "accept", "dispatch", "status", "vehicles"]),
    ("staff", ["dashboard", "map", "media", "logs"]),
    ("super", ["accounts", "agencies", "export"]),
]

# (from use case, to use case, stereotype)  arrow points to the "to" end
DEPENDENCIES = [
    ("login", "otp", "«include»"),
    ("photos", "report", "«extend»"),
    ("map", "sendloc", "«include»"),
]


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text_block(x, y, text, size=14, weight=500, color=INK, anchor="middle"):
    lines = text.split("\n")
    lh = size * 1.22
    y0 = y - (len(lines) - 1) * lh / 2
    tspans = "".join(f'<tspan x="{x:.1f}" y="{y0 + i * lh:.1f}">{esc(l)}</tspan>' for i, l in enumerate(lines))
    return (f'<text font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}" '
            f'dominant-baseline="middle">{tspans}</text>')


def ellipse_edge(uc, tx, ty):
    _, x, y = USE_CASES[uc]
    a, b = UC_W / 2, UC_H / 2
    dx, dy = tx - x, ty - y
    t = 1 / math.sqrt((dx / a) ** 2 + (dy / b) ** 2)
    return x + dx * t, y + dy * t


def actor_anchor(actor, tx, ty):
    _, x, y = ACTORS[actor]
    if actor == "user":
        return x, y + 50                      # bottom of the top-centre actor's label
    return (x + 34, y) if tx > x else (x - 34, y)


def actor_svg(key):
    label, x, y = ACTORS[key]
    s = f'stroke="{INK}" stroke-width="2.6" fill="none" stroke-linecap="round"'
    return (f'<circle cx="{x}" cy="{y - 34}" r="13" fill="#FFFFFF" {s}/>'
            f'<path d="M{x},{y - 21} V{y + 10} M{x - 22},{y - 10} H{x + 22} '
            f'M{x},{y + 10} L{x - 17},{y + 36} M{x},{y + 10} L{x + 17},{y + 36}" {s}/>'
            + text_block(x, y + (60 if key != "user" else 0) + (label.count("\n") * 8), label, 14.5, 700)
            if key != "user" else
            f'<circle cx="{x}" cy="{y - 38}" r="11" fill="#FFFFFF" {s}/>'
            f'<path d="M{x},{y - 27} V{y - 2} M{x - 18},{y - 17} H{x + 18} '
            f'M{x},{y - 2} L{x - 14},{y + 18} M{x},{y - 2} L{x + 14},{y + 18}" {s}/>'
            + text_block(x, y + 36, label, 14, 700))


def use_case_svg(key):
    label, x, y = USE_CASES[key]
    return (f'<ellipse cx="{x}" cy="{y}" rx="{UC_W / 2}" ry="{UC_H / 2}" fill="#FFF7ED" stroke="{ORANGE}" stroke-width="2"/>'
            + text_block(x, y, label, 13.5, 600))


def associations_svg():
    out = []
    for actor, ucs in ASSOCIATIONS:
        for uc in ucs:
            _, ux, uy = USE_CASES[uc]
            ax, ay = actor_anchor(actor, ux, uy)
            ex, ey = ellipse_edge(uc, ax, ay)
            out.append(f'<line x1="{ax:.1f}" y1="{ay:.1f}" x2="{ex:.1f}" y2="{ey:.1f}" stroke="{LINE}" stroke-width="1.5"/>')
    return "\n".join(out)


def dependencies_svg():
    out = []
    for a, b, label in DEPENDENCIES:
        _, ax, ay = USE_CASES[a]
        _, bx, by = USE_CASES[b]
        s, e = ellipse_edge(a, bx, by), ellipse_edge(b, ax, ay)
        out.append(f'<line x1="{s[0]:.1f}" y1="{s[1]:.1f}" x2="{e[0]:.1f}" y2="{e[1]:.1f}" stroke="{ORANGE}" '
                   f'stroke-width="1.6" stroke-dasharray="7 5" marker-end="url(#open)"/>')
        mx, my = (s[0] + e[0]) / 2, (s[1] + e[1]) / 2
        vertical = abs(e[0] - s[0]) < abs(e[1] - s[1])
        out.append(text_block(mx + (10 if vertical else 0), my - (0 if vertical else 12), label, 12.5, 700, ORANGE,
                              "start" if vertical else "middle"))
    return "\n".join(out)


def generalization_svg():
    """Citizen and Admin Staff are kinds of User; both admin roles are kinds of Admin Staff."""
    ux, uy = ACTORS["user"][1], ACTORS["user"][2]
    cx, cy = ACTORS["citizen"][1], ACTORS["citizen"][2]
    ax, ay = ACTORS["admin"][1], ACTORS["admin"][2]
    tx, ty = ACTORS["staff"][1], ACTORS["staff"][2]
    sx, sy = ACTORS["super"][1], ACTORS["super"][2]
    left, right, top = 90, 1945, uy - 8
    st = f'fill="none" stroke="{INK}" stroke-width="1.8"'
    return "\n".join([
        f'<path d="M{cx - 30},{cy} H{left} V{top} H{ux - 34}" {st} marker-end="url(#triangle)"/>',
        f'<path d="M{tx + 34},{ty} H{right} V{top} H{ux + 34}" {st} marker-end="url(#triangle)"/>',
        f'<path d="M{ax},{ay + 90} V{ty - 52}" {st} marker-end="url(#triangle)"/>',
        f'<path d="M{sx},{sy - 50} V{ty + 78}" {st} marker-end="url(#triangle)"/>',
    ])

def legend_svg():
    x, y = 40, 1320
    return "\n".join([
        f'<rect x="{x}" y="{y}" width="340" height="170" rx="8" fill="#FFFFFF" stroke="#CBD5E1"/>',
        text_block(x + 170, y + 20, "Legend", 14, 800),
        f'<line x1="{x + 16}" y1="{y + 50}" x2="{x + 80}" y2="{y + 50}" stroke="{LINE}" stroke-width="1.5"/>',
        f'<text x="{x + 94}" y="{y + 54}" font-size="12.5" fill="{INK}">Actor uses the function</text>',
        f'<line x1="{x + 16}" y1="{y + 82}" x2="{x + 80}" y2="{y + 82}" stroke="{ORANGE}" stroke-width="1.6" stroke-dasharray="7 5" marker-end="url(#open)"/>',
        f'<text x="{x + 94}" y="{y + 86}" font-size="12.5" fill="{INK}">«include» / «extend»</text>',
        f'<path d="M{x + 16},{y + 116} H{x + 80}" fill="none" stroke="{INK}" stroke-width="1.8" marker-end="url(#triangle)"/>',
        f'<text x="{x + 94}" y="{y + 120}" font-size="12.5" fill="{INK}">Is a kind of (generalization)</text>',
        f'<text x="{x + 16}" y="{y + 152}" font-size="11.5" fill="#64748B">«include»: always part of it  «extend»: optional</text>',
    ])


def build():
    l, t, r, b = BOUND
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
        f'font-family="Segoe UI, Arial, sans-serif">',
        "<defs>"
        f'<marker id="open" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="9" markerHeight="9" orient="auto">'
        f'<path d="M0,0 L10,5 L0,10" fill="none" stroke="{ORANGE}" stroke-width="1.6"/></marker>'
        f'<marker id="triangle" viewBox="0 0 12 12" refX="11" refY="6" markerWidth="13" markerHeight="13" orient="auto">'
        f'<path d="M0,0 L12,6 L0,12 z" fill="#FFFFFF" stroke="{INK}" stroke-width="1.4"/></marker>'
        "</defs>",
        f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>',
        text_block(W / 2 - 330, 30, "Use Case Diagram of ResQ", 24, 800),
        f'<rect x="{l}" y="{t}" width="{r - l}" height="{b - t}" rx="10" fill="#FFFFFF" stroke="{INK}" stroke-width="2.2"/>',
        text_block(l + 20, t + 24, "ResQ Emergency Response System", 16, 800, INK, "start"),
        generalization_svg(),
        associations_svg(),
        *(use_case_svg(k) for k in USE_CASES),
        dependencies_svg(),
        *(actor_svg(k) for k in ACTORS),
        legend_svg(),
        "</svg>",
    ]
    return "\n".join(parts)


if __name__ == "__main__":
    out = Path(__file__).with_suffix(".svg")
    out.write_text(build(), encoding="utf-8")
    print(f"wrote {out} ({W}x{H})")
