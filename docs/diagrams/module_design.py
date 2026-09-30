"""Draws the ResQ Module Design (hierarchy chart) as SVG.

Render to PNG/PDF with:  .\\build.ps1 module_design
"""

from pathlib import Path

ORANGE = "#FF6B00"
INK = "#1E293B"
LINE = "#475569"

MODULES = [
    ("User\nAuthentication", [
        "Register citizen account",
        "Log in",
        "Email login code (OTP)",
        "Remember this device\n(30 days)",
        "Reset password",
        "Log out",
    ]),
    ("Emergency Reporting\n(Citizen)", [
        "Report emergency\n(type, description)",
        "Auto-detect GPS location",
        "Attach evidence photos",
        "Track request status",
        "View dispatched unit\nand live location",
    ]),
    ("Incident Management\n& Dispatch", [
        "View incident queue",
        "Route to involved\ndepartments",
        "Accept / decline incident",
        "Dispatch response unit",
        "Update incident status",
        "Search incidents",
    ]),
    ("Vehicle & GPS\nTracking", [
        "Manage vehicles\n(plate, type, department)",
        "Auto-register new\nGPS trackers",
        "Receive ESP32 location\n(Wi-Fi / SIM data)",
        "Live vehicle map",
        "Vehicle status (Available,\nEn Route, Offline)",
    ]),
    ("Notifications &\nReal-Time Updates", [
        "Real-time incident alerts",
        "Live screen updates",
        "Notification bell &\nunread count",
        "Mark as read",
    ]),
    ("Evidence\nMedia", [
        "Evidence photo gallery",
        "Filter by incident type",
        "View photo details",
        "Download photos",
    ]),
    ("Reports &\nAudit Logs", [
        "Dashboard metrics",
        "Activity / audit logs",
        "Audit package (PDF report\n+ photos, ZIP)",
        "Export logs (CSV)",
    ]),
    ("Administration\n& Settings", [
        "Manage user accounts\n(create, edit, disable)",
        "Manage agencies",
        "Profile & change password",
        "Appearance (light / dark)",
        "Security settings\n(login code on/off)",
    ]),
]

PER_ROW = 4                      # two rows of four, sized for a portrait page
COL_W, GAP = 252, 30
MOD_H, FN_H, FN_GAP = 74, 56, 14
LEFT = 40
TOP_ROOT, ROOT_H = 80, 70
ROW_GAP = 60                     # space between the bottom of row 1 and row 2's bus


def rows():
    return [MODULES[i:i + PER_ROW] for i in range(0, len(MODULES), PER_ROW)]


def row_height(mods):
    return 34 + MOD_H + 26 + max(len(f) for _, f in mods) * (FN_H + FN_GAP)


W = LEFT * 2 + PER_ROW * COL_W + (PER_ROW - 1) * GAP
BUS_YS = []
_y = TOP_ROOT + ROOT_H + 40
for _mods in rows():
    BUS_YS.append(_y)
    _y += row_height(_mods) + ROW_GAP
H = int(_y - ROW_GAP + 30)

def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text_block(x, y, text, size=13, weight=500, color=INK, anchor="middle"):
    lines = text.split("\n")
    lh = size * 1.25
    y0 = y - (len(lines) - 1) * lh / 2
    tspans = "".join(f'<tspan x="{x:.1f}" y="{y0 + i * lh:.1f}">{esc(l)}</tspan>' for i, l in enumerate(lines))
    return (f'<text font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}" '
            f'dominant-baseline="middle">{tspans}</text>')


def build():
    cx = W / 2
    centers = [LEFT + i * (COL_W + GAP) + COL_W / 2 for i in range(PER_ROW)]
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
        f'font-family="Segoe UI, Arial, sans-serif">',
        f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>',
        text_block(cx, 34, "Module Design of ResQ", 24, 800),
        f'<rect x="{cx - 210}" y="{TOP_ROOT}" width="420" height="{ROOT_H}" rx="12" fill="{ORANGE}"/>',
        text_block(cx, TOP_ROOT + ROOT_H / 2, "ResQ Emergency Response System", 19, 800, "#FFFFFF"),
        # trunk from the root down to the last row's bus, running in the middle gap
        f'<line x1="{cx}" y1="{TOP_ROOT + ROOT_H}" x2="{cx}" y2="{BUS_YS[-1]}" stroke="{LINE}" stroke-width="2"/>',
    ]

    n = 0
    for r, mods in enumerate(rows()):
        bus_y = BUS_YS[r]
        mod_y = bus_y + 34
        fn_top = mod_y + MOD_H + 26
        parts.append(f'<line x1="{centers[0]}" y1="{bus_y}" x2="{centers[len(mods) - 1]}" y2="{bus_y}" '
                     f'stroke="{LINE}" stroke-width="2"/>')
        for i, (name, functions) in enumerate(mods):
            n += 1
            mx = centers[i]
            left = mx - COL_W / 2
            parts.append(f'<line x1="{mx}" y1="{bus_y}" x2="{mx}" y2="{mod_y}" stroke="{LINE}" stroke-width="2"/>')
            parts.append(f'<rect x="{left}" y="{mod_y}" width="{COL_W}" height="{MOD_H}" rx="8" fill="{INK}"/>')
            parts.append(text_block(left + 14, mod_y + 16, f"{n}.0", 12, 800, ORANGE, "start"))
            parts.append(text_block(mx, mod_y + MOD_H / 2 + 6, name, 15, 700, "#FFFFFF"))

            spine_x = left + 16
            last_y = fn_top + (len(functions) - 1) * (FN_H + FN_GAP) + FN_H / 2
            parts.append(f'<line x1="{spine_x}" y1="{mod_y + MOD_H}" x2="{spine_x}" y2="{last_y}" stroke="{LINE}" stroke-width="1.6"/>')
            for j, fn in enumerate(functions):
                y = fn_top + j * (FN_H + FN_GAP)
                bx, bw = left + 34, COL_W - 34
                parts.append(f'<line x1="{spine_x}" y1="{y + FN_H / 2}" x2="{bx}" y2="{y + FN_H / 2}" stroke="{LINE}" stroke-width="1.6"/>')
                parts.append(f'<rect x="{bx}" y="{y}" width="{bw}" height="{FN_H}" rx="6" fill="#FFF7ED" stroke="{ORANGE}" stroke-width="1.5"/>')
                parts.append(text_block(bx + 10, y + 12, f"{n}.{j + 1}", 11, 800, ORANGE, "start"))
                parts.append(text_block(bx + bw / 2 + 8, y + FN_H / 2 + 4, fn, 13, 600))

    parts.append("</svg>")
    return "\n".join(parts)

if __name__ == "__main__":
    out = Path(__file__).with_suffix(".svg")
    out.write_text(build(), encoding="utf-8")
    print(f"wrote {out} ({W}x{H})")
