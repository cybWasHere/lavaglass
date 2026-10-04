// A dodge-windows panel only reserves the screen edge under its own length, so a
// short centred panel can't be summoned from the rest of the edge. This reserves
// the whole bottom edge and, while the cursor stays near it, flips that screen's
// bottom panel to "windows go below" (visible, no strut), then back to dodge.

const BAND = 70; // px above the bottom edge in which the panel stays up

let shown = null; // geometry of the screen whose panel we raised

function plasma(script) {
    callDBus("org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell", "evaluateScript", script);
}

// Flipped panels are flagged in their own config: Plasma reads "windowsgobelow"
// back as "none", so they can't be found by mode, and the flag also lets a
// fresh script instance undo a reveal that a KWin restart left behind.
const RESTORE =
    "panels().forEach(function (p) {" +
    "  p.currentConfigGroup = ['EdgeReveal'];" +
    "  if (p.readConfig('flipped', false) == true || p.readConfig('flipped', '') == 'true') {" +
    "    p.hiding = 'dodgewindows'; p.writeConfig('flipped', false);" +
    "  }" +
    "});";

function hide() {
    if (!shown) return;
    shown = null;
    plasma(RESTORE);
}

registerScreenEdge(KWin.ElectricBottom, function () {
    const g = workspace.screenAt(workspace.cursorPos).geometry;
    if (shown && shown.x === g.x && shown.y === g.y) return;
    hide();
    shown = {x: g.x, y: g.y, width: g.width, height: g.height};
    plasma("panels().forEach(function (p) {" +
           "  var g = screenGeometry(p.screen);" +
           "  if (p.location == 'bottom' && g.x == " + g.x + " && g.y == " + g.y +
           "      && p.hiding == 'dodgewindows') {" +
           "    p.hiding = 'windowsgobelow';" +
           "    p.currentConfigGroup = ['EdgeReveal']; p.writeConfig('flipped', true);" +
           "  }" +
           "});");
});

workspace.cursorPosChanged.connect(function () {
    if (!shown) return;
    const x = workspace.cursorPos.x, y = workspace.cursorPos.y;
    if (x < shown.x || x >= shown.x + shown.width ||
        y < shown.y + shown.height - BAND || y >= shown.y + shown.height) hide();
});

plasma(RESTORE);
