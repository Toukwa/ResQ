"""Draws the ResQ Entity Relationship Diagram (crow's foot notation) as SVG.

Entities and fields follow the Firebase Realtime Database structure the app uses.
Render to PNG/PDF with:  .\\build.ps1 erd
"""

from pathlib import Path

W, H = 2010, 1330
ENT_W = 300
HEAD_H, ROW_H = 40, 23

ORANGE = "#FF6B00"
INK = "#1E293B"
LINE = "#334155"
MUTED = "#64748B"

# name: (x, y, [(field, type, key)])   key: PK | FK | PK,FK | ""
ENTITIES = {
    "USER_SETTINGS": (40, 70, [
        ("uid", "string", "PK,FK"),
        ("theme_mode", "string", ""),
        ("mfa_enabled", "int (0/1)", ""),
        ("sound_alerts", "int (0/1)", ""),
        ("map_display_style", "string", ""),
        ("session_timeout", "string", ""),
        ("… other preferences", "", ""),
    ]),
    "LOGIN_CODE (OTP)": (40, 330, [
        ("uid", "string", "PK,FK"),
        ("codeHash", "string", ""),
        ("expiresAt", "timestamp", ""),
        ("attempts", "int", ""),
    ]),
    "TRUSTED_DEVICES": (40, 510, [
        ("tokenHash", "string", "PK"),
        ("uid", "string", "FK"),
        ("label", "string", ""),
        ("expiresAt", "timestamp", ""),
    ]),
    "USERS": (500, 250, [
        ("uid", "string", "PK"),
        ("id", "int (unique)", ""),
        ("fullName", "string", ""),
        ("email", "string", ""),
        ("contactNo", "string", ""),
        ("role", "Citizen / Responder /\nAdmin / Superadmin", ""),
        ("deptID", "int", "FK"),
        ("disabled", "boolean", ""),
        ("createdAt", "timestamp", ""),
    ]),
    "DEPARTMENTS": (900, 60, [
        ("dept_ID", "int", "PK"),
        ("deptName", "PNP / BFP / CDRRMO", ""),
        ("agencyType", "string", ""),
        ("deptLocation", "string", ""),
        ("contactInfo", "string", ""),
    ]),
    "INCIDENTS": (900, 420, [
        ("Req_ID", "int", "PK"),
        ("citizenUid", "string", "FK"),
        ("incType", "string", ""),
        ("description", "string", ""),
        ("latitude", "double", ""),
        ("longitude", "double", ""),
        ("image_path", "photo URLs", ""),
        ("reqStatus", "string", ""),
        ("dept_status", "map: dept → status", ""),
        ("SOS_timeStamp", "timestamp", ""),
    ]),
    "VEHICLES": (1300, 60, [
        ("vehicle_ID", "int", "PK"),
        ("plate_no", "string", ""),
        ("vehicle_type", "string", ""),
        ("dept_ID", "int", "FK"),
        ("trackerUid", "string", "FK"),
        ("HardwareID_mapping", "MAC address", ""),
        ("status", "Available / En Route", ""),
    ]),
    "GPS_TRACKERS": (1690, 60, [
        ("trackerUid", "string", "PK"),
        ("hardwareId", "MAC address", ""),
        ("latitude", "double", ""),
        ("longitude", "double", ""),
        ("speed_kph", "double", ""),
        ("satellites", "int", ""),
        ("hasFix", "boolean", ""),
        ("source", "wifi / cellular", ""),
        ("received_at", "timestamp", ""),
    ]),
    "DISPATCHES": (1300, 450, [
        ("Disp_ID", "int", "PK"),
        ("Req_ID", "int", "FK"),
        ("Vehicle_ID", "int", "FK"),
        ("Admin_ID", "int", "FK"),
        ("status", "En Route / Completed", ""),
        ("Dispatch_timeStamp", "timestamp", ""),
    ]),
    "NOTIFICATIONS": (1300, 810, [
        ("notification_ID", "int", "PK"),
        ("req_ID", "int", "FK"),
        ("disp_ID", "int", "FK"),
        ("recipient_ID", "int (null = all staff)", "FK"),
        ("title", "string", ""),
        ("message", "string", ""),
        ("notification_type", "EMERGENCY / DISPATCH", ""),
        ("readBy", "map: uid → time", ""),
        ("timestamp", "timestamp", ""),
    ]),
    "SYSTEM_LOGS": (500, 830, [
        ("log_key", "string", "PK"),
        ("uid", "string", "FK"),
        ("role", "string", ""),
        ("action", "string", ""),
        ("entity_type", "string", ""),
        ("entity_id", "int", ""),
        ("status", "string", ""),
        ("details", "text", ""),
        ("timestamp", "timestamp", ""),
    ]),
}

# (entity A, side, entity B, side, card at A, card at B, label, label (x, y))
# cardinality: "1" one and only one | "01" zero or one | "0N" zero or many | "1N" one or many
# side: "l" "r" "t" "b" with optional ":fraction" along the side (default 0.5)
RELATIONS = [
    ("USERS", "l:0.12", "USER_SETTINGS", "r:0.3", "1", "01", "has", (386, 121)),
    ("USERS", "l:0.35", "LOGIN_CODE (OTP)", "r", "1", "01", "verifies", (386, 388)),
    ("USERS", "l:0.6", "TRUSTED_DEVICES", "r", "1", "0N", "remembers", (386, 568)),
    ("DEPARTMENTS", "l", "USERS", "t", "01", "0N", "employs", (760, 129)),
    ("DEPARTMENTS", "r", "VEHICLES", "l", "1", "0N", "owns", (1225, 129)),
    ("GPS_TRACKERS", "l:0.8", "VEHICLES", "r:0.7", "1", "01", "tracks", (1622, 194)),
    ("USERS", "r:0.55", "INCIDENTS", "l:0.3", "1", "0N", "reports", (857, 420, "start")),
    ("INCIDENTS", "r:0.3", "DISPATCHES", "l:0.35", "1", "0N", "is served by", (1250, 487)),
    ("VEHICLES", "b", "DISPATCHES", "t", "1", "0N", "is assigned in", (1462, 400, "start")),
    ("USERS", "r:0.9", "DISPATCHES", "l:0.8", "1", "0N", "dispatches (admin)", (925, 733),
     [(840, None), (840, 745), (1262, 745), (1262, None)]),
    ("INCIDENTS", "b", "NOTIFICATIONS", "l:0.25", "1", "0N", "triggers", (1062, 830, "start")),
    ("DISPATCHES", "b", "NOTIFICATIONS", "t", "01", "0N", "triggers", (1462, 770, "start")),
    ("USERS", "b", "SYSTEM_LOGS", "t", "1", "0N", "generates", (662, 700, "start")),
]

def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size=13, weight=500, color=INK, anchor="start"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" font-weight="{weight}" fill="{color}" '
            f'text-anchor="{anchor}" dominant-baseline="middle">{esc(s)}</text>')


def rows(name):
    """Each field row; a type with a newline takes two lines."""
    return [(f, t, k, 2 if "\n" in t else 1) for f, t, k in ENTITIES[name][2]]


def ent_height(name):
    return HEAD_H + sum(n for *_, n in rows(name)) * ROW_H + 8


def entity_svg(name):
    x, y, _ = ENTITIES[name]
    h = ent_height(name)
    out = [
        f'<rect x="{x + 5}" y="{y + 5}" width="{ENT_W}" height="{h}" rx="8" fill="#E2E8F0"/>',
        f'<rect x="{x}" y="{y}" width="{ENT_W}" height="{h}" rx="8" fill="#FFFFFF" stroke="{INK}" stroke-width="1.8"/>',
        f'<path d="M{x + 8},{y} H{x + ENT_W - 8} Q{x + ENT_W},{y} {x + ENT_W},{y + 8} V{y + HEAD_H} H{x} V{y + 8} Q{x},{y} {x + 8},{y} Z" fill="{ORANGE}"/>',
        text(x + ENT_W / 2, y + HEAD_H / 2, name, 15, 800, "#FFFFFF", "middle"),
    ]
    cy = y + HEAD_H + 4
    for field, ftype, key, n in rows(name):
        mid = cy + n * ROW_H / 2
        if key:
            out.append(text(x + 10, mid, key, 10.5, 800, ORANGE))
        weight = 700 if "PK" in key else 500
        out.append(text(x + 58, mid, field, 13, weight, INK if not field.startswith("…") else MUTED))
        for i, part in enumerate(ftype.split("\n")):
            out.append(text(x + ENT_W - 10, mid + (i - (n - 1) / 2) * 15, part, 11.5, 500, MUTED, "end"))
        if "PK" in key:
            out.append(f'<line x1="{x}" y1="{cy + n * ROW_H}" x2="{x + ENT_W}" y2="{cy + n * ROW_H}" stroke="#CBD5E1"/>')
        cy += n * ROW_H
    return "\n".join(out)


def anchor(name, spec):
    side, _, frac = spec.partition(":")
    f = float(frac) if frac else 0.5
    x, y, _ = ENTITIES[name]
    h = ent_height(name)
    return {
        "l": ((x, y + h * f), (-1, 0)),
        "r": ((x + ENT_W, y + h * f), (1, 0)),
        "t": ((x + ENT_W * f, y), (0, -1)),
        "b": ((x + ENT_W * f, y + h), (0, 1)),
    }[side]


def cardinality(p, d, card):
    """Crow's foot symbol at point p on an entity edge; d points away from the entity."""
    (x, y), (dx, dy) = p, d
    px, py = -dy, dx
    s = f'stroke="{LINE}" stroke-width="1.8" fill="none"'
    out = []

    def bar(t):
        cx, cy = x + dx * t, y + dy * t
        out.append(f'<line x1="{cx + px * 9}" y1="{cy + py * 9}" x2="{cx - px * 9}" y2="{cy - py * 9}" {s}/>')

    def circle(t):
        out.append(f'<circle cx="{x + dx * t}" cy="{y + dy * t}" r="6" fill="#FFFFFF" stroke="{LINE}" stroke-width="1.8"/>')

    def crow():
        tip_x, tip_y = x + dx * 16, y + dy * 16
        for k in (-1, 0, 1):
            out.append(f'<line x1="{tip_x}" y1="{tip_y}" x2="{x + px * 10 * k}" y2="{y + py * 10 * k}" {s}/>')

    if card == "1":
        bar(10); bar(17)
    elif card == "01":
        bar(10); circle(24)
    elif card == "0N":
        crow(); circle(24)
    elif card == "1N":
        crow(); bar(22)
    return "".join(out)


def relation_svg(a, sa, b, sb, ca, cb, label, lpos, via=None):
    (p1, d1), (p2, d2) = anchor(a, sa), anchor(b, sb)
    lead = 32
    if via:  # explicit route; None in a waypoint means "same y as the nearest end"
        mid = [(x, p1[1] if y is None and i == 0 else p2[1] if y is None else y) for i, (x, y) in enumerate(via)]
        pts = [p1, *mid, p2]
        return _path(pts, p1, d1, p2, d2, ca, cb, label, lpos)
    s = (p1[0] + d1[0] * lead, p1[1] + d1[1] * lead)
    e = (p2[0] + d2[0] * lead, p2[1] + d2[1] * lead)
    if d1[0] != 0 and d2[0] != 0:          # side to side: mid vertical
        mx = (s[0] + e[0]) / 2
        pts = [p1, s, (mx, s[1]), (mx, e[1]), e, p2]
    elif d1[1] != 0 and d2[1] != 0:        # top/bottom to top/bottom: mid horizontal
        my = (s[1] + e[1]) / 2
        pts = [p1, s, (s[0], my), (e[0], my), e, p2]
    elif d1[0] != 0:                       # side to top/bottom
        pts = [p1, s, (e[0], s[1]), e, p2]
    else:                                  # top/bottom to side
        pts = [p1, s, (s[0], e[1]), e, p2]
    return _path(pts, p1, d1, p2, d2, ca, cb, label, lpos)


def _path(pts, p1, d1, p2, d2, ca, cb, label, lpos):
    d = "M" + " L".join(f"{px:.1f},{py:.1f}" for px, py in pts)
    anchor_ = lpos[2] if len(lpos) > 2 else "middle"
    return (f'<path d="{d}" fill="none" stroke="{LINE}" stroke-width="1.8"/>'
            + cardinality(p1, d1, ca) + cardinality(p2, d2, cb)
            + text(lpos[0], lpos[1], label, 12.5, 700, "#1D4ED8", anchor_)
               .replace("<text ", '<text stroke="#FFFFFF" stroke-width="4" paint-order="stroke" ', 1))


def legend_svg():
    x, y = 40, 1040
    out = [f'<rect x="{x}" y="{y}" width="340" height="230" rx="8" fill="#FFFFFF" stroke="#CBD5E1"/>',
           text(x + 170, y + 22, "Legend (crow's foot)", 14, 800, INK, "middle")]
    for i, (card, desc) in enumerate([("1", "Exactly one"), ("01", "Zero or one"),
                                       ("0N", "Zero or many"), ("1N", "One or many")]):
        yy = y + 56 + i * 36
        out.append(f'<line x1="{x + 20}" y1="{yy}" x2="{x + 90}" y2="{yy}" stroke="{LINE}" stroke-width="1.8"/>')
        out.append(cardinality((x + 90, yy), (-1, 0), card))
        out.append(text(x + 110, yy, desc, 13))
    out.append(text(x + 16, y + 206, "PK = primary key   FK = foreign key", 12, 600, MUTED))
    return "\n".join(out)


def build():
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
        f'font-family="Segoe UI, Arial, sans-serif">',
        f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>',
        text(W / 2, 28, "Entity Relationship Diagram of ResQ", 24, 800, INK, "middle"),
        *(relation_svg(*r) for r in RELATIONS),
        *(entity_svg(n) for n in ENTITIES),
        legend_svg(),
        text(W - 40, H - 22, "Stored in Firebase Realtime Database. Internal ID counters and live-update signals are not shown.",
             12, 500, MUTED, "end"),
        "</svg>",
    ]
    return "\n".join(parts)


if __name__ == "__main__":
    out = Path(__file__).with_suffix(".svg")
    out.write_text(build(), encoding="utf-8")
    print(f"wrote {out} ({W}x{H})")
