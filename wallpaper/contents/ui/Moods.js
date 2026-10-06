.pragma library
// [name, base, A, B, C] - all dark, mid saturation, tuned against Breeze Dark greys + blue accent
var list = [
    ["Nebula",        "#100f2a", "#7a2a9e", "#c2306a", "#2a6f9e"],
    ["Deep Sea",      "#0a1422", "#1e5f8c", "#2a86b8", "#264a8a"],
    ["Aurora",        "#0a161a", "#1b7f86", "#3fa36b", "#4a3f9e"],
    ["Twilight",      "#141024", "#5a3fae", "#2f6fb8", "#a0407a"],
    ["Ember",         "#150c14", "#a8321e", "#c0602a", "#7a1f4c"],
    ["Rose Dusk",     "#160e1c", "#b0406a", "#7d3f9e", "#c0664a"],
    ["Midnight Teal", "#081418", "#1f7a8a", "#1e4f7a", "#2e8f80"],
    ["Ultraviolet",   "#0f0c20", "#6a2ab8", "#3a3aa8", "#b0308a"],
    ["Smoke & Ice",   "#0e1013", "#3a5a78", "#5a5a80", "#2a6f8a"]
];

function names() { return list.map(function (m) { return m[0]; }); }

function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
}

// hoursNow: wall-clock hours; cycleHours: one loop through every mood
function drift(hoursNow, cycleHours) {
    var pos = (hoursNow / cycleHours) * list.length;
    var i = Math.floor(pos) % list.length;
    var t = pos - Math.floor(pos);
    t = t * t * t * (t * (t * 6 - 15) + 10); // smootherstep: no visible start/stop of a fade
    var a = list[i], b = list[(i + 1) % list.length], out = [];
    for (var k = 1; k <= 4; k++) out.push(mix(Qt.color(a[k]), Qt.color(b[k]), t));
    return out;
}

function fixed(i) {
    var m = list[i];
    return [Qt.color(m[1]), Qt.color(m[2]), Qt.color(m[3]), Qt.color(m[4])];
}

function hsl(h, s, l) {
    h = ((h % 1) + 1) % 1;
    function ch(n) {
        var k = (n + h * 12) % 12;
        return l - s * Math.min(l, 1 - l) * Math.max(-1, Math.min(k - 3, 9 - k, 1));
    }
    return [ch(0), ch(8), ch(4)];
}

// The cover's colours as a lamp palette [base, A, B, C]: its three strongest hues, brought to the
// moods' darkness and saturation so a neon cover doesn't light up the room. d: RGBA bytes of the
// cover scaled down. null for a cover with no colour to speak of. (Same maths as the startpage.)
function fromCover(d) {
    var hues = coverHues(d), j, n;
    if (!hues) return null;
    var turns = [0.08, -0.08, 0.16]; // fewer than three colours on the cover: neighbours of the main one
    for (n = 0; n < turns.length && hues.length < 3; n++) {
        var nh = hues[0][0] + turns[n], apart = true;
        for (j = 0; j < hues.length; j++)
            if (Math.abs((((hues[j][0] - nh) % 1) + 1.5) % 1 - 0.5) <= 0.05) apart = false;
        if (apart) hues.push([nh, hues[0][1]]);
    }
    return lamp(hues);
}

// A video's main colour as a lamp palette: the one strongest hue of its picture, the three waxes
// a few degrees apart so they still read as wax. A picture with no colour gives a grey lamp.
function fromMain(d) {
    var hues = coverHues(d);
    if (!hues) return lamp([[0, 0], [0, 0], [0, 0]]);
    var h = hues[0][0], s = hues[0][1];
    return lamp([[h, s], [h + 0.035, s], [h - 0.035, s]]);
}

// Two palettes too close to tell apart
function near(a, b) {
    for (var i = 0; i < 4; i++)
        if (Math.abs(a[i].r - b[i].r) + Math.abs(a[i].g - b[i].g) + Math.abs(a[i].b - b[i].b) > 0.03) return false;
    return true;
}

// [base, A, B, C] from three [hue, saturation]
function lamp(hues) {
    var s0 = hues[0][1] > 0 ? 0.42 : 0, n;
    var base = hsl(hues[0][0], s0, 0.085), out = [Qt.rgba(base[0], base[1], base[2], 1)];
    for (n = 0; n < 3; n++) {
        var w = hsl(hues[n][0], hues[n][1], hues[n][1] > 0 ? 0.42 : 0.3 + 0.06 * n);
        var y = 0.299 * w[0] + 0.587 * w[1] + 0.114 * w[2];
        var f = y > 0.4 ? 0.4 / y : 1; // yellows and greens read brighter: cap them
        out.push(Qt.rgba(w[0] * f, w[1] * f, w[2] * f, 1));
    }
    return out;
}

// The picture's strongest hues, up to three, as [hue 0..1, saturation]; null if it has no colour to speak of.
function coverHues(d) {
    var N = 24, bins = [], sat = [], total = 0, i, k, j, n;
    for (k = 0; k < N; k++) { bins.push(0); sat.push(0); }
    for (i = 0; i < d.length; i += 4) {
        var r = d[i] / 255, g = d[i + 1] / 255, b = d[i + 2] / 255;
        var mx = Math.max(r, g, b), mn = Math.min(r, g, b), c = mx - mn;
        total += c;
        if (c < 0.08) continue;
        var h = mx === r ? (g - b) / c : mx === g ? 2 + (b - r) / c : 4 + (r - g) / c;
        k = Math.floor((h / 6 + 1) % 1 * N) % N;
        bins[k] += c; sat[k] += c * c / (1 - Math.abs(mx + mn - 1) + 1e-3); // weighted by chroma: big vivid areas win
    }
    if (total / (d.length / 4) < 0.05) return null;
    if (Math.max.apply(null, bins) <= 0) return null; // tinted all over, but no pixel strong enough to count
    function at(k) { return bins[(k + N) % N]; }
    var left = [], hues = [], top = 0;
    for (k = 0; k < N; k++) left.push(at(k - 1) + 2 * at(k) + at(k + 1));
    for (n = 0; n < 3; n++) { // peaks at least 45 degrees apart, and not a stray speck of colour
        k = left.indexOf(Math.max.apply(null, left));
        if (n && (left[k] <= 0 || left[k] < 0.15 * top)) break;
        if (!n) top = left[k];
        var near = at(k - 1) + at(k) + at(k + 1);
        hues.push([(k + 0.5 + (at(k + 1) - at(k - 1)) / near) / N, Math.min(0.65, Math.max(0.4, sat[k] / bins[k]))]);
        for (j = -2; j <= 2; j++) left[(k + j + N) % N] = 0;
    }
    return hues;
}
