#!/usr/bin/env python3
"""Write a round (circle) task manager highlight (widgets/tasks.svgz) into a user Plasma theme.

Usage: rounded-tasks-svg.py [icon-margin=7] [gap=4] [theme=the Plasma style in use]
gap = transparent inset around each circle (units of a 32-unit task item); icon-margin should stay a
few units above it so icons sit inside the circle.
The file goes to ~/.local/share/plasma/desktoptheme/<theme>/widgets/tasks.svgz. Plasma resolves the
theme folder once (via metadata.json), so a lone tasks.svgz there is ignored: the whole system theme is
copied to ~/.local first and then shadows the system one. Delete that local theme folder to undo.
"""
import gzip, os, subprocess, sys

MARGIN = int(sys.argv[1]) if len(sys.argv) > 1 else 7
GAP = float(sys.argv[2]) if len(sys.argv) > 2 else 4
THEME = sys.argv[3] if len(sys.argv) > 3 else (subprocess.run(
    ["kreadconfig6", "--file", "plasmarc", "--group", "Theme", "--key", "name"],
    capture_output=True, text=True).stdout.strip() or "default")

# state -> (colour class, opacity); same tints as Breeze, minus its edge line
STATES = {
    "normal": ("ColorScheme-Text", .15),
    "focus": ("ColorScheme-ButtonFocus", .45),
    "hover": ("ColorScheme-ButtonHover", .34),
    "attention": ("ColorScheme-NeutralText", .35),
    "minimized": ("ColorScheme-Text", .08),
    "progress": ("ColorScheme-PositiveText", .31),
}
PREFIXES = ["", "north-", "west-", "east-"]

out = ['<svg xmlns="http://www.w3.org/2000/svg" version="1.1" viewBox="0 0 {w} {h}">',
       '<style id="current-color-scheme" type="text/css">'
       '.ColorScheme-Text{color:#232629}.ColorScheme-PositiveText{color:#27ae60}'
       '.ColorScheme-NeutralText{color:#f67400}.ColorScheme-ButtonFocus{color:#3daee9}'
       '.ColorScheme-ButtonHover{color:#93cee9}</style>']

# One stretched "center" element per state and no border slices: a circle inset GAP units inside a
# transparent square, so on the (square) task items it draws a circle with a gap to its neighbours.
S = 32
cell = S + 4
row = 0
for prefix in PREFIXES:
    for col, (state, (cls, op)) in enumerate(STATES.items()):
        x0, y0 = col * cell, row * cell
        out.append(f'<g id="{prefix}{state}-center"><rect x="{x0}" y="{y0}" width="{S}" height="{S}" fill="none"/>'
                   f'<circle cx="{x0+S/2}" cy="{y0+S/2}" r="{S/2-GAP}" class="{cls}" fill="currentColor" opacity="{op}"/></g>')
    row += 1

# content margins = icon padding inside the item (Breeze uses 4; 5 keeps icons inside the circle)
my = row * cell
# only top/bottom: icons-only tasks are (height + left + right margins) wide, so any left/right margin
# makes the item wider than tall and the circle an oval
for i, side in enumerate(["top", "bottom"]):
    out.append(f'<rect id="normal-hint-{side}-margin" x="{i*6}" y="{my}" width="{MARGIN}" height="{MARGIN}" fill="#f0f"/>')
out.append("</svg>")

svg = "\n".join(out).replace("{w}", str(len(STATES) * cell)).replace("{h}", str(my + 8))
local = os.path.expanduser(f"~/.local/share/plasma/desktoptheme/{THEME}")
if not os.path.exists(os.path.join(local, "metadata.json")):
    os.makedirs(local, exist_ok=True)
    subprocess.run(["cp", "-rn", f"/usr/share/plasma/desktoptheme/{THEME}/.", local + "/"], check=True)
dest = os.path.join(local, "widgets")
os.makedirs(dest, exist_ok=True)
with gzip.open(os.path.join(dest, "tasks.svgz"), "wb") as f:
    f.write(svg.encode())
print(f"wrote {dest}/tasks.svgz (circles, icon margin {MARGIN}, gap {GAP})")
# KSvg caches rendered theme pixmaps; drop the cache so plasmashell redraws from the new file
for c in ["plasma_theme_" + THEME + ".kcache", "ksvg-elements"]:
    p = os.path.expanduser(f"~/.cache/{c}")
    if os.path.exists(p):
        os.remove(p)
