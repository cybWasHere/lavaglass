.pragma library
// Weather icons, the start page's own (startpage/index.html), as SVG text for a QML Image.
const SUN = '<circle cx="24" cy="24" r="8" fill="#fdbc4b"/><g stroke="#fdbc4b" stroke-width="3" stroke-linecap="round">' +
    [0, 45, 90, 135, 180, 225, 270, 315].map(a => `<line x1="24" y1="7" x2="24" y2="11" transform="rotate(${a} 24 24)"/>`).join("") + "</g>";
const MOON = '<path d="M30 8a14 14 0 1 0 10 22A11 11 0 0 1 30 8z" fill="#c8d0e0"/>';
const CLOUD = (x = 0, y = 0, c = "#dfe5eb") => `<path transform="translate(${x} ${y})" d="M14 38h22a8 8 0 0 0 0-16 11 11 0 0 0-21-2 8 8 0 0 0-1 18z" fill="${c}"/>`;
const DROPS = c => [16, 24, 32].map(x => `<line x1="${x}" y1="39" x2="${x - 2}" y2="44" stroke="${c}" stroke-width="2.5" stroke-linecap="round"/>`).join("");
function icon(code, day) {
    const sky = day ? SUN : MOON;
    let g;
    if (code <= 1) g = code === 0 ? sky : `${sky}${CLOUD(10, 8, "#c3cbd3")}`;
    else if (code === 2) g = `<g transform="translate(-6 -6) scale(.85)">${sky}</g>${CLOUD(2, 4)}`;
    else if (code === 3) g = `${CLOUD(-6, -6, "#8f99a3")}${CLOUD(2, 2)}`;
    else if (code === 45 || code === 48) g = `${CLOUD(0, -4, "#aab3bc")}<g stroke="#aab3bc" stroke-width="2.5" stroke-linecap="round"><line x1="10" y1="40" x2="38" y2="40"/><line x1="14" y1="45" x2="34" y2="45"/></g>`;
    else if ((code >= 71 && code <= 77) || code === 85 || code === 86) g = `${CLOUD(0, -6)}<g fill="#fff">${[15, 24, 33].map((x, i) => `<circle cx="${x}" cy="${40 + (i % 2) * 3}" r="2.2"/>`).join("")}</g>`;
    else if (code >= 95) g = `${CLOUD(0, -6, "#8f99a3")}<path d="M25 33l-6 8h5l-3 7 8-10h-5l3-5z" fill="#fdbc4b"/>`;
    else if (code >= 51) g = `${CLOUD(0, -6, code >= 63 && code !== 80 ? "#aab3bc" : "#dfe5eb")}${DROPS("#3daee9")}`;
    else g = CLOUD();
    return "data:image/svg+xml;utf8," + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">${g}</svg>`);
}

const WMO = { 0: "Clear", 1: "Mostly clear", 2: "Partly cloudy", 3: "Overcast", 45: "Fog", 48: "Fog",
    51: "Light drizzle", 53: "Drizzle", 55: "Heavy drizzle", 56: "Freezing drizzle", 57: "Freezing drizzle",
    61: "Light rain", 63: "Rain", 65: "Heavy rain", 66: "Freezing rain", 67: "Freezing rain",
    71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains",
    80: "Showers", 81: "Showers", 82: "Violent showers", 85: "Snow showers", 86: "Snow showers",
    95: "Thunderstorm", 96: "Thunderstorm, hail", 99: "Thunderstorm, hail" };
function words(code) { return WMO[code] || ""; }

