// Gap Maximize: on the landscape screen, a maximize (button, double-click, shortcut, window rule)
// is turned into "put the window in the full-screen custom tile", whose padding leaves a gap.
// Maximizing a window that already sits in that tile restores its size from before it went in.
// The landscape screen is found by shape, not by DP name, because the connector names swap.
// The gap is the tile's padding: [Tiling] in kwinrc, or the Meta+T editor.

const MAX_FULL = 3; // KWin::MaximizeFull
const saved = new Map(); // window -> geometry before it was put in the tile
const wasInTile = new Map(); // window -> tile membership just before a maximize request
const pending = new Map(); // window -> geometry just before a maximize request
let busy = false;

function log(msg) { console.info("gap-maximize: " + msg); }

function fullTile(out) {
    if (!out || out.geometry.width <= out.geometry.height) return null;
    const root = workspace.tilingForScreen(out).rootTile;
    if (root.tiles.length === 0) return root;
    return root.tiles.length === 1 ? root.tiles[0] : null; // a real split layout: leave it alone
}

function eligible(w) {
    return w && w.normalWindow && !w.transient && !w.fullScreen && w.resizeable && !w.deleted;
}

function onAboutToChange(w, mode) {
    if (busy) return;
    const t = fullTile(w.output);
    wasInTile.set(w, !!t && w.tile === t);
    // maximizedChanged comes too late for this: a Wayland window already has the maximized geometry
    const g = w.frameGeometry;
    if (mode === MAX_FULL) pending.set(w, { x: g.x, y: g.y, width: g.width, height: g.height });
    else pending.delete(w);
}

function onChanged(w) {
    if (busy || w.maximizeMode !== MAX_FULL || !eligible(w)) return;
    const t = fullTile(w.output);
    if (!t) return;
    const restore = wasInTile.get(w);
    wasInTile.delete(w);
    const before = pending.get(w);
    pending.delete(w);
    busy = true;
    try {
        w.setMaximize(false, false);
        if (restore) {
            w.tile = null;
            const g = saved.get(w);
            saved.delete(w);
            if (g) w.frameGeometry = g;
            log("restored " + w.resourceClass);
        } else {
            // always the latest: the window may have left the tile by other means and been resized
            const g = before || w.frameGeometry;
            // a window that opened maximized has no useful size; fall back to 70% centred
            const a = t.absoluteGeometry;
            saved.set(w, (g.width >= a.width - 1 && g.height >= a.height - 1)
                ? { x: a.x + a.width * 0.15, y: a.y + a.height * 0.15, width: a.width * 0.7, height: a.height * 0.7 }
                : { x: g.x, y: g.y, width: g.width, height: g.height });
            w.tile = t;
            log("tiled " + w.resourceClass);
        }
    } finally {
        busy = false;
    }
}

function watch(w) {
    if (!w || !w.normalWindow) return;
    w.maximizedAboutToChange.connect(mode => onAboutToChange(w, mode));
    w.maximizedChanged.connect(() => onChanged(w));
    onChanged(w); // opened maximized (e.g. the Firefox placement rule)
}

workspace.windowAdded.connect(watch);
workspace.windowRemoved.connect(w => { saved.delete(w); wasInTile.delete(w); pending.delete(w); });
workspace.stackingOrder.forEach(watch);
