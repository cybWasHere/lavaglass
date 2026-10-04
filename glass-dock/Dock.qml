// Glass Dock: time, date, weather and what is playing, in a glass pill at the top of the portrait
// screen. A layer-shell surface, so it keeps a strip of the screen to itself and windows start
// below it. Looks follow the start page (same colours, font and weather icons).
// Pointing at a part tells more: the date opens a calendar (the wheel turns the months), the
// weather opens the week, the track opens Pear Remote (pear-corner, its own window, right under
// that part); a click on the track is play/pause. A YouTube video playing in a browser is shown
// the same way, with its channel (Pear Remote still opens: the way to the music). With nothing playing, a play button stays for
// as long as some player can be started.
import QtQuick
import QtQuick.Effects
import QtQuick.Window
import org.kde.layershell as LayerShell
import "icons.js" as Icons

Window {
    id: win
    readonly property int pillHeight: 38
    readonly property int gap: 10          // above the pill, and between it and the windows below
    readonly property int tilePadding: 20  // KWin's own gap around tiles on this screen (kwinrc [Tiling] padding)
    readonly property int panelGap: 6      // between the pill and an open panel
    readonly property int pad: 28          // room around the glass, inside the surface, for its shadow
    readonly property color text: "#fcfcfc"
    readonly property color muted: "#a1a9b1"
    readonly property color dim: "#6c737a"
    readonly property color line: Qt.rgba(1, 1, 1, 0.1)
    readonly property color accent: "#3daee9"
    readonly property color glass: Qt.rgba(32 / 255, 35 / 255, 38 / 255, 0.8)
    readonly property var en: Qt.locale("en_GB")

    property date now: new Date()
    property var weather: null             // { temp, feels, code, day, days: [{ name, code, min, max, rain }], lo, hi }
    property var track: null               // { title, author, cover, video: true for a YouTube video }
    property bool paused: false            // the track's player is paused: still shown, so it can be resumed
    property double pausedAt: 0
    property bool canPlay: false           // nothing is playing, but a player is there to be started

    // which part the mouse is on ("date", "wx", "np"), and which panel that opens
    property string hot: CFG.hot ?? ""    // "hot" in config.json opens a panel at start, to look at it without a mouse
    readonly property string open: hot === "date" || (hot === "wx" && weather) ? hot : ""
    readonly property Item under: open === "date" ? dateSec : open === "wx" ? wxSec : null
    // The panel hangs centred under its part. The surface is centred on the screen, so to keep the
    // pill where it is the window is wider by the same amount on both sides. It has that room for
    // either panel all the time: growing only when one opens moved the pill inside the window for
    // a moment, which put the mouse on the part next door and closed the panel again.
    readonly property real pillW: row.implicitWidth + 4
    function panelLeft(sec, w) { return Math.round(row.x + sec.x + sec.width / 2 - w / 2); }
    function spill(sec, w) { const x = panelLeft(sec, w); return Math.max(0, -x, x + w - pillW); }
    readonly property real panelX: under ? panelLeft(under, panel.width) : 0
    readonly property real overhang: Math.max(spill(dateSec, calBody.implicitWidth + 28),
                                              wxSec.visible ? spill(wxSec, weekBody.implicitWidth + 28) : 0)

    width: pillW + 2 * (overhang + pad)
    height: gap + pillHeight + (open ? panelGap + panel.height : 0) + pad
    color: "transparent"
    flags: Qt.FramelessWindowHint
    visible: true
    screen: Qt.application.screens.find(s => s.model.indexOf(CFG.screen ?? "") >= 0) ?? Qt.application.screens[0]

    LayerShell.Window.scope: "glass-dock"
    LayerShell.Window.layer: LayerShell.Window.LayerTop
    LayerShell.Window.anchors: LayerShell.Window.AnchorTop
    // The gap above the pill is inside the surface (the shadow needs the room), and the surface
    // hangs lower than its zone for the same reason. KWin adds its tile padding below the zone.
    LayerShell.Window.exclusionZone: Math.max(0, pillHeight + 2 * gap - tilePadding)
    LayerShell.Window.keyboardInteractivity: LayerShell.Window.KeyboardInteractivityNone

    function reshape() {
        // the blur stops a pixel inside the glass too, for the same reason
        const rects = [Qt.rect(pill.x + 1, pill.y + 1, pillW - 2, pillHeight - 2)];
        let bridge = Qt.rect(0, 0, 0, 0);
        if (open) {
            rects.push(Qt.rect(panel.x + 1, panel.y + 1, panel.width - 2, panel.height - 2));
            const l = Math.max(pill.x, panel.x), r = Math.min(pill.x + pillW, panel.x + panel.width);
            bridge = Qt.rect(l, pill.y + pillHeight, r - l, panelGap);
        }
        Glass.shape(win, rects, 9, bridge);
    }
    onWidthChanged: Qt.callLater(reshape)
    onHeightChanged: Qt.callLater(reshape)
    onOpenChanged: Qt.callLater(reshape)
    Component.onCompleted: reshape()

    function hover(name, on) {
        if (on) { closeTimer.stop(); hot = name; }
        else if (hot === name) closeTimer.restart();
    }
    Timer { id: closeTimer; interval: 280; onTriggered: win.hot = "" }
    readonly property bool trackHot: hot === "np" && track !== null
    onTrackHotChanged: Media.remote(trackHot)

    function get(url, done) {
        const x = new XMLHttpRequest();
        x.onreadystatechange = () => {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            let j = null;
            try { if (x.status === 200) j = JSON.parse(x.responseText); } catch (e) {}
            done(j);
        };
        x.open("GET", url);
        x.send();
    }
    function loadWeather() {
        if (CFG.lat === undefined) return;
        get(`https://api.open-meteo.com/v1/forecast?latitude=${CFG.lat}&longitude=${CFG.lon}` +
            `&current=temperature_2m,apparent_temperature,weather_code,is_day` +
            `&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=7`, j => {
            weatherTimer.interval = j ? 15 * 60000 : 60000;  // offline at login: try again soon
            if (!j || !j.current || !j.daily) return;
            const d = j.daily, days = [];
            for (let i = 0; i < d.time.length; i++)
                days.push({ name: i === 0 ? "Today" : en.toString(new Date(d.time[i] + "T12:00"), "ddd"), code: d.weather_code[i],
                            min: Math.round(d.temperature_2m_min[i]), max: Math.round(d.temperature_2m_max[i]),
                            rain: d.precipitation_probability_max[i] ?? 0 });
            weather = { temp: Math.round(j.current.temperature_2m), feels: Math.round(j.current.apparent_temperature),
                        code: j.current.weather_code, day: j.current.is_day, days: days,
                        lo: Math.min(...days.map(x => x.min)), hi: Math.max(...days.map(x => x.max)) };
        });
    }
    function loadTrack() {
        if (!CFG.nowPlaying) return;
        get(CFG.nowPlaying, j => {
            const on = j && j.player && j.player.hasSong && !j.player.isPaused && j.track && j.track.title;
            if (on) {
                Media.sync(j.track.title);
                paused = false; pausedAt = 0;
                if (!track || track.title !== j.track.title || track.cover !== j.track.cover)
                    track = { title: j.track.title, author: j.track.author || "", cover: j.track.cover || "" };
                return;
            }
            const v = Media.video();
            if (v.id) { showVideo(v); return; }
            const state = Media.sync("");
            canPlay = state !== "" && state !== "Playing";
            if (track && state === "Paused" && (!pausedAt || Date.now() - pausedAt < 10 * 60000)) {
                if (!pausedAt) pausedAt = Date.now();
                paused = true;      // stays up for ten minutes, then only the play button is left
            } else {
                track = null; paused = false; pausedAt = 0;
            }
        });
    }
    // A YouTube video, shown like a track: the browser only says "<title> - YouTube", so the title
    // and the channel are asked from YouTube, once per video.
    property var videos: ({})              // video id -> { title, author }; null while asked or if it failed
    function showVideo(v) {
        paused = false; pausedAt = 0;
        const known = videos[v.id];
        const title = known ? known.title : v.title.replace(/^\(\d+\) /, "").replace(/ - YouTube$/, "");
        const author = known ? known.author : v.author;
        const cover = `https://i.ytimg.com/vi/${v.id}/mqdefault.jpg`;
        if (!track || track.title !== title || track.author !== author || track.cover !== cover)
            track = { title: title, author: author, cover: cover, video: true };
        if (known !== undefined) return;
        videos[v.id] = null;
        get("https://www.youtube.com/oembed?format=json&url=" + encodeURIComponent("https://www.youtube.com/watch?v=" + v.id), j => {
            if (!j || !j.title) return;
            videos[v.id] = { title: j.title, author: j.author_name || "" };
            loadTrack();
        });
    }
    function media(method) {
        Media.cmd(method);
        if (method === "PlayPause") { paused = !paused; pausedAt = paused ? Date.now() : 0; }
        trackSoon.restart();
    }
    Timer { interval: 1000; running: true; repeat: true; onTriggered: win.now = new Date() }
    Timer { id: weatherTimer; interval: 60000; running: true; repeat: true; triggeredOnStart: true; onTriggered: win.loadWeather() }
    Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true; onTriggered: win.loadTrack() }
    Timer { id: trackSoon; interval: 700; onTriggered: win.loadTrack() }

    component Sep: Item {
        width: 1; height: win.pillHeight
        Rectangle { width: 1; height: 16; color: win.line; anchors.centerIn: parent }
    }
    // one part of the pill: as tall as the pill and edge to edge with its neighbours, so the
    // mouse is always on exactly one of them
    component Section: Item {
        id: sec
        property string name
        default property alias content: inner.data
        readonly property bool hot: win.hot === name
        height: win.pillHeight
        width: inner.implicitWidth + 24
        Rectangle { anchors.fill: parent; anchors.margins: 4; radius: 7; color: Qt.rgba(1, 1, 1, sec.hot ? 0.07 : 0) }
        Row { id: inner; anchors.centerIn: parent; spacing: 6; height: parent.height }
        HoverHandler { onHoveredChanged: win.hover(sec.name, hovered) }
    }
    component Label: Text {
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        color: win.text
        font { family: "Noto Sans"; pixelSize: 13 }
    }
    component Cover: Item {
        id: cv
        property string source
        property real radius: 6
        readonly property bool ready: img.status === Image.Ready
        Image { id: img; anchors.fill: parent; source: cv.source; sourceSize: Qt.size(cv.width * 2, cv.height * 2); fillMode: Image.PreserveAspectCrop; visible: false }
        Rectangle { id: mask; anchors.fill: parent; radius: cv.radius; visible: false; layer.enabled: true }
        MultiEffect { anchors.fill: parent; source: img; maskEnabled: true; maskSource: mask }
    }

    // The soft drop shadow windows get from their decoration, for a piece of glass. It is cut out
    // under the glass itself: seen through it, the shadow would only darken the blur.
    component Shade: Item {
        id: shade
        required property Item of
        readonly property int reach: win.pad
        x: of.x - reach; y: of.y - reach
        width: of.width + 2 * reach; height: of.height + 2 * reach
        visible: of.visible
        Item {
            id: cast
            anchors.fill: parent; visible: false; layer.enabled: true
            RectangularShadow {
                x: shade.reach; y: shade.reach + 4
                width: shade.of.width; height: shade.of.height
                radius: 10; blur: 22; color: Qt.rgba(0, 0, 0, 0.6)
            }
        }
        Item {
            id: hole
            anchors.fill: parent; visible: false; layer.enabled: true
            // a pixel inside the glass edge: cut flush, the two soft edges leave a light rim between them
            Rectangle { x: shade.reach + 1; y: shade.reach + 1; width: shade.of.width - 2; height: shade.of.height - 2; radius: 9 }
        }
        MultiEffect { anchors.fill: parent; source: cast; maskEnabled: true; maskSource: hole; maskInverted: true }
    }
    Shade { of: pill }
    Shade { of: panel }

    Item {
        id: pill
        x: win.pad + win.overhang; y: win.gap
        width: win.pillW; height: win.pillHeight
        Rectangle { anchors.fill: parent; radius: 10; color: win.glass }

        Row {
            id: row
            x: 2

            Section {  // the time, with the date tucked in under it
                id: dateSec
                name: "date"
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: -3
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Qt.formatTime(win.now, "HH:mm:ss")
                        color: win.text
                        font { family: "Noto Sans"; pixelSize: 15; features: { "tnum": 1 } }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: win.en.toString(win.now, "ddd d MMM")
                        color: win.muted
                        font { family: "Noto Sans"; pixelSize: 10 }
                    }
                }
            }

            Sep { visible: wxSec.visible }
            Section {
                id: wxSec
                name: "wx"
                visible: win.weather !== null
                Image {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 22; height: 22; sourceSize: Qt.size(44, 44)
                    source: win.weather ? Icons.icon(win.weather.code, win.weather.day) : ""
                }
                Label { text: win.weather ? win.weather.temp + "°" : ""; font.pixelSize: 14; font.weight: Font.Medium }
            }

            Sep { visible: npSec.visible }
            Section {
                id: npSec
                name: "np"
                visible: win.track !== null || win.canPlay
                Cover {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 24; height: 24
                    visible: ready && win.track !== null
                    opacity: win.paused ? 0.55 : 1
                    source: win.track ? win.track.cover : ""
                }
                Label {
                    visible: win.track !== null
                    opacity: win.paused ? 0.55 : 1
                    width: Math.min(implicitWidth, 380)
                    elide: Text.ElideRight
                    textFormat: Text.StyledText
                    text: win.track ? `<b>${esc(win.track.title)}</b>` + (win.track.author ? `<font color="${win.muted}"> · ${esc(win.track.author)}</font>` : "") : ""
                    function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;"); }
                }
                Row {  // the equaliser: sixteen slices of whatever the speakers play, low notes on the left
                    id: eq
                    property var levels: []
                    anchors.verticalCenter: parent.verticalCenter
                    visible: win.track !== null && !win.paused
                    height: 18; spacing: 2
                    onVisibleChanged: { levels = []; Spectrum.listen(visible); }
                    Component.onCompleted: Spectrum.listen(visible)
                    Connections { target: Spectrum; function onHeard(v) { eq.levels = v; } }
                    Repeater {
                        model: 16
                        Rectangle {
                            required property int index
                            width: 3; radius: 1; color: win.accent
                            anchors.bottom: parent.bottom
                            height: Math.max(2, Math.round(eq.height * (eq.levels[index] ?? 0)))
                        }
                    }
                }
                Canvas {  // play: in place of the equaliser while nothing is playing
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !eq.visible
                    width: 10; height: 12
                    onPaint: {
                        const c = getContext("2d");
                        c.fillStyle = win.text;
                        c.beginPath(); c.moveTo(0, 0); c.lineTo(width, height / 2); c.lineTo(0, height); c.closePath(); c.fill();
                    }
                }
                TapHandler { onTapped: win.media(win.track ? "PlayPause" : "Play") }
            }
        }
    }

    Rectangle {
        id: panel
        // both panels are loaded from the start, so the window knows how wide either will be
        readonly property Item body: win.open === "date" ? calBody : win.open === "wx" ? weekBody : null
        visible: body !== null
        x: win.pad + win.overhang + win.panelX
        y: win.gap + win.pillHeight + win.panelGap
        width: body ? body.implicitWidth + 28 : 0
        height: body ? body.implicitHeight + 26 : 0
        onXChanged: Qt.callLater(win.reshape)
        onWidthChanged: Qt.callLater(win.reshape)
        radius: 10; color: win.glass
        HoverHandler { onHoveredChanged: hovered ? closeTimer.stop() : closeTimer.restart() }
        Loader { id: calBody; anchors.centerIn: parent; visible: win.open === "date"; sourceComponent: calendar }
        Loader { id: weekBody; anchors.centerIn: parent; visible: win.open === "wx"; active: win.weather !== null; sourceComponent: week }
    }

    Component {
        id: calendar
        Column {
            id: cal
            property int turn: 0   // months from this one; the wheel turns it
            readonly property date first: new Date(win.now.getFullYear(), win.now.getMonth() + turn, 1)
            spacing: 8
            onVisibleChanged: if (!visible) turn = 0
            Row {
                width: grid.width
                Label { text: win.en.toString(cal.first, "MMMM yyyy"); font.pixelSize: 14; font.weight: Font.DemiBold; leftPadding: 7 }
            }
            Grid {
                id: grid
                columns: 7
                Repeater {
                    model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
                    Text { required property string modelData; width: 34; height: 22; horizontalAlignment: Text.AlignHCenter; text: modelData; color: win.dim; font { family: "Noto Sans"; pixelSize: 11 } }
                }
                Repeater {
                    model: 42
                    Item {
                        id: cell
                        required property int index
                        readonly property date day: new Date(cal.first.getFullYear(), cal.first.getMonth(), 1 - (cal.first.getDay() + 6) % 7 + index)
                        readonly property bool today: day.toDateString() === win.now.toDateString()
                        width: 34; height: 30
                        Rectangle { anchors.centerIn: parent; width: 26; height: 26; radius: 13; color: win.accent; visible: cell.today }
                        Text {
                            anchors.centerIn: parent
                            text: cell.day.getDate()
                            color: cell.today ? "#202326" : cell.day.getMonth() === cal.first.getMonth() ? win.text : win.dim
                            font { family: "Noto Sans"; pixelSize: 13; weight: cell.today ? Font.DemiBold : Font.Normal; features: { "tnum": 1 } }
                        }
                    }
                }
            }
            WheelHandler { onWheel: e => cal.turn += e.angleDelta.y < 0 ? 1 : -1 }
        }
    }

    Component {
        id: week
        Column {
            spacing: 4
            Row {
                spacing: 8; bottomPadding: 4
                Label { text: Icons.words(win.weather.code); font.pixelSize: 14; font.weight: Font.DemiBold }
                Label { text: "feels " + win.weather.feels + "°"; color: win.muted }
            }
            Repeater {
                model: win.weather.days
                Row {
                    id: dayRow
                    required property var modelData
                    height: 26; spacing: 8
                    Label { width: 42; text: dayRow.modelData.name; color: win.muted }
                    Image { anchors.verticalCenter: parent.verticalCenter; width: 22; height: 22; sourceSize: Qt.size(44, 44); source: Icons.icon(dayRow.modelData.code, 1) }
                    Label { width: 34; horizontalAlignment: Text.AlignRight; text: dayRow.modelData.rain >= 20 ? dayRow.modelData.rain + "%" : ""; color: win.accent; font.pixelSize: 11 }
                    Label { width: 28; horizontalAlignment: Text.AlignRight; text: dayRow.modelData.min + "°"; color: win.muted }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 90; height: 5; radius: 3; color: Qt.rgba(1, 1, 1, 0.1)
                        Rectangle {
                            readonly property real span: Math.max(1, win.weather.hi - win.weather.lo)
                            x: (dayRow.modelData.min - win.weather.lo) / span * parent.width
                            width: Math.max(6, (dayRow.modelData.max - dayRow.modelData.min) / span * parent.width)
                            height: 5; radius: 3
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0; color: "#3daee9" }
                                GradientStop { position: 0.6; color: "#fdbc4b" }
                                GradientStop { position: 1; color: "#f67400" }
                            }
                        }
                    }
                    Label { width: 28; text: dayRow.modelData.max + "°" }
                }
            }
        }
    }
}
