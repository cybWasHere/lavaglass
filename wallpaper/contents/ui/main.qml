import QtQuick
import QtWebSockets
import org.kde.plasma.plasmoid
import org.kde.pipewire as PipeWire
import org.kde.taskmanager as TaskManager
import "Moods.js" as Moods

WallpaperItem {
    id: wallpaper

    readonly property var cfg: wallpaper.configuration
    // Palette 0 = drift through every mood (or the playing album's colours), n = fixed mood n-1
    property var pal: Moods.fixed(0)
    // a change of source (new track, music stops, another mood picked) melts in from palFrom
    property var palFrom: pal
    property real melt: 1
    property var source: undefined
    NumberAnimation { id: melting; target: wallpaper; property: "melt"; from: 0; to: 1; duration: 3500; easing.type: Easing.InOutSine }
    function shown(i) { return Moods.mix(palFrom[i], pal[i], melt) }
    // slow structural wander; periods are unrelated so the combination doesn't repeat for days
    property real sizeScale: 1.0
    property real haze: 0.22
    property real flow: 1.0

    function evolve() {
        const h = Date.now() / 3600000
        const music = following && (videoPal || musicPal)
        const next = cfg.Palette > 0 ? Moods.fixed(cfg.Palette - 1) : music || Moods.drift(h, Math.max(0.1, cfg.CycleHours))
        const from = cfg.Palette > 0 ? cfg.Palette : music || 0
        if (source !== undefined && from !== source) {
            const now = [0, 1, 2, 3].map(shown)
            const tv = next === videoPal && videoPal !== null      // a video is followed closely, like light off a TV
            melting.stop(); melting.duration = tv ? 1500 : 3500; melting.easing.type = tv ? Easing.OutQuad : Easing.InOutSine
            melt = 0; palFrom = now; pal = next; melting.start()
        } else pal = next
        source = from
        const w = (period, phase) => Math.sin(2 * Math.PI * h / period + phase)
        sizeScale = 1.0 + 0.2 * w(2.3, 0.0) + 0.08 * w(0.77, 1.0)
        haze = 0.2 + 0.08 * w(3.1, 2.0)
        flow = 1.0 + 0.35 * w(1.7, 4.0)
    }
    Timer { interval: 2000; repeat: true; running: wallpaper.running; triggeredOnStart: true; onTriggered: wallpaper.evolve() }
    Connections { target: wallpaper.cfg; function onValueChanged() { wallpaper.evolve() } }

    // Follow the music: while something plays (Pear, a browser tab, any player: the lamp-audio service
    // says what), a drifting lamp takes its colours from the cover
    // and moves a touch livelier; a few seconds after the music stops it settles back into the moods.
    readonly property bool following: cfg.FollowMusic && cfg.Palette === 0
    property var musicPal: null
    property string trackId: ""
    property string lastPos: ""
    property int idle: 0
    property real live: cfg.FollowMusic && trackId !== "" ? 1 : 0
    Behavior on live { NumberAnimation { duration: 4000; easing.type: Easing.InOutSine } }

    // On a portrait screen a YouTube video (music or talk) that is on screen comes first: the lamp
    // takes the one main colour of its picture, as it plays. lamp-audio says a video is playing and its
    // title; its window (Picture-in-Picture, else the browser window showing that tab) is watched
    // through the stream the task bar's previews use. Colour only: the lamp still moves to music alone.
    readonly property bool videoColour: following && cfg.VideoColour && height > width && running
        && Qt.application.name === "plasmashell"            // not on the lock screen: it may not watch windows
    property var videoPal: null
    property string videoTitle: ""
    property string videoWindow: ""
    property int videoIdle: 0
    property var shots: []          // the last few looks at it, so one odd frame doesn't flip the colour
    property var shot: null         // keeps the grabbed picture alive until it's read

    function watched(v) {
        if (v && v.title) { videoIdle = 0; videoTitle = v.title }
        else if (videoTitle !== "" && ++videoIdle > 1) videoTitle = ""
        findVideo()
    }
    function findVideo() {
        let pip = "", page = ""
        for (let i = 0; videoTitle !== "" && i < windows.count; i++) {
            const idx = windows.index(i, 0), title = windows.data(idx, Qt.DisplayRole) || ""
            const ids = windows.data(idx, TaskManager.AbstractTasksModel.WinIdList)
            if (!ids || !ids.length) continue
            if (/^Picture.in.picture$/i.test(title)) pip = ids[0]
            else if (title.indexOf(videoTitle) >= 0 && title.indexOf("YouTube") >= 0) page = ids[0]
        }
        videoWindow = pip || page
    }
    TaskManager.TasksModel {
        id: windows
        groupMode: TaskManager.TasksModel.GroupDisabled
        activity: actInfo.currentActivity
        virtualDesktop: vdInfo.currentDesktop
        filterByActivity: true
        filterByVirtualDesktop: true
        filterMinimized: true
        onDataChanged: findVideoSoon.restart()
        onCountChanged: findVideoSoon.restart()
    }
    Timer { id: findVideoSoon; interval: 150; onTriggered: wallpaper.findVideo() }
    Loader {
        active: wallpaper.videoWindow !== ""
        onActiveChanged: if (!active) { wallpaper.shots = []; wallpaper.shot = null; wallpaper.videoPal = null; wallpaper.evolve() }
        sourceComponent: PipeWire.PipeWireSourceItem {      // it sits under the lamp, like the scratch canvases
            id: tv
            width: 64; height: 36
            nodeId: cast.nodeId
            TaskManager.ScreencastingRequest { id: cast; uuid: wallpaper.videoWindow }
            Timer {
                interval: 400; repeat: true
                running: cast.nodeId > 0 && wallpaper.videoColour
                onTriggered: if (tv.streamSize.width > 0)
                    tv.grabToImage(r => { wallpaper.shot = r; thumb.url = "" + r.url }, Qt.size(24, 24))
            }
        }
    }

    function heard(q) {
        watched(videoColour && q ? q.video : null)
        const has = q && q.player && q.player.hasSong && q.track
        const pos = has ? q.track.id + "@" + q.player.seekbarCurrentPosition : ""
        // only a moving seekbar means playing (Amuse, whose reply this is modelled on, never says paused)
        const moving = pos !== "" && lastPos !== "" && pos !== lastPos && !q.player.isPaused && !q.track.isAdvertisement
        lastPos = pos
        if (!moving) {
            // two polls of silence before letting go, so the gap between songs doesn't flash the mood
            idle += 1
            if (trackId !== "" && idle > 1) { trackId = ""; cover.url = ""; musicPal = null; evolve() }
            return
        }
        idle = 0
        if (q.track.id === trackId) return
        trackId = q.track.id
        cover.url = (q.track.cover || "").replace(/=w\d+-h\d+/, "=w96-h96")
        if (cover.url === "") { musicPal = null; evolve() }   // no picture (a radio, a bare tab): keep moving, in the moods' colours
    }
    Timer {
        interval: 2500; repeat: true; triggeredOnStart: true
        running: wallpaper.running && wallpaper.cfg.FollowMusic
        onTriggered: {
            const xhr = new XMLHttpRequest()
            xhr.onreadystatechange = () => {
                if (xhr.readyState !== XMLHttpRequest.DONE) return
                let q = null
                try { q = JSON.parse(xhr.responseText) } catch (e) {}
                wallpaper.heard(q)
            }
            xhr.open("GET", wallpaper.cfg.MusicUrl)
            xhr.send()
        }
    }
    // offscreen-sized scratch canvas (it sits under the lamp): the only way to read an image's pixels from QML
    component Pixels: Canvas {
        width: 24; height: 24
        property string url: ""
        signal read(var data)
        onUrlChanged: if (url !== "") { loadImage(url); if (isImageLoaded(url)) requestPaint() }   // a grab is there at once
        onImageLoaded: requestPaint()
        onPaint: {
            if (url === "" || !isImageLoaded(url)) return
            const ctx = getContext("2d")
            ctx.drawImage(url, 0, 0, width, height)
            read(ctx.getImageData(0, 0, width, height).data)
            unloadImage(url)
            wallpaper.evolve()
        }
    }
    Pixels { id: cover; onRead: data => wallpaper.musicPal = Moods.fromCover(data) }
    Pixels {
        id: thumb
        onRead: data => {
            wallpaper.shots = wallpaper.shots.slice(-2).concat([Array.prototype.slice.call(data)])
            const p = Moods.fromMain([].concat.apply([], wallpaper.shots))
            if (!wallpaper.videoPal || !Moods.near(p, wallpaper.videoPal)) wallpaper.videoPal = p
        }
    }

    // ...and move to the sound itself. The lamp-audio service (../lamp-audio in this repo) listens
    // to whatever is playing and sends "bass mid high kick level" 60 times a second, each 0..1, zeros in silence.
    property vector3d bands: Qt.vector3d(0, 0, 0)
    property real kick: 0
    property real level: 0
    readonly property bool hearing: kick > 0 || level > 0
    property bool retrying: false
    function deaf() { bands = Qt.vector3d(0, 0, 0); kick = 0; level = 0 }
    WebSocket {
        id: ears
        url: wallpaper.cfg.AudioUrl
        active: wallpaper.running && wallpaper.cfg.FollowMusic && wallpaper.cfg.AudioUrl !== "" && !wallpaper.retrying
        onTextMessageReceived: message => {
            const v = message.split(" ")
            wallpaper.bands = Qt.vector3d(+v[0], +v[1], +v[2]); wallpaper.kick = +v[3]; wallpaper.level = +v[4]
        }
        onStatusChanged: status => {
            if (status === WebSocket.Open) return
            wallpaper.deaf()
            if (status === WebSocket.Closed || status === WebSocket.Error) wallpaper.retrying = true
        }
    }
    Timer { interval: 5000; running: wallpaper.retrying; onTriggered: wallpaper.retrying = false }

    // pause while a maximized/fullscreen window covers this screen
    property bool covered: false
    readonly property bool running: !(cfg.PauseWhenCovered && covered)

    TaskManager.VirtualDesktopInfo { id: vdInfo }
    TaskManager.ActivityInfo { id: actInfo }
    TaskManager.TasksModel {
        id: tasks
        groupMode: TaskManager.TasksModel.GroupDisabled
        activity: actInfo.currentActivity
        virtualDesktop: vdInfo.currentDesktop
        screenGeometry: wallpaper.parent ? wallpaper.parent.screenGeometry : Qt.rect(0, 0, 0, 0)
        filterByActivity: true
        filterByVirtualDesktop: true
        filterByScreen: true
        filterMinimized: true
        onDataChanged: coverCheck.restart()
        onCountChanged: coverCheck.restart()
    }
    Timer {
        id: coverCheck
        interval: 150
        onTriggered: {
            let c = false
            for (let i = 0; i < tasks.count; i++) {
                const idx = tasks.index(i, 0)
                if (tasks.data(idx, TaskManager.AbstractTasksModel.IsMaximized)
                        || tasks.data(idx, TaskManager.AbstractTasksModel.IsFullScreen)) { c = true; break }
            }
            wallpaper.covered = c
        }
    }
    Component.onCompleted: coverCheck.start()

    Rectangle { anchors.fill: parent; color: wallpaper.shown(0) }

    ShaderEffect {
        id: lava
        anchors.fill: parent
        // random start so both screens don't mirror each other
        property real time: Math.random() * 1000
        property real brightness: wallpaper.cfg.Brightness
        property size resolution: Qt.size(width, height)
        property color base: wallpaper.shown(0)
        property color colA: wallpaper.shown(1)
        property color colB: wallpaper.shown(2)
        property color colC: wallpaper.shown(3)
        property real sizeScale: wallpaper.sizeScale
        property real haze: wallpaper.haze + 0.05 * wallpaper.live + 0.06 * wallpaper.level
        property real kick: wallpaper.kick
        property real fusion: wallpaper.cfg.Fusion ? wallpaper.live : 0
        property real fuseStyle: wallpaper.cfg.FusionStyle
        property vector3d bands: wallpaper.bands
        fragmentShader: Qt.resolvedUrl("../shaders/lava.frag.qsb")
    }

    Timer {
        // music gets 60 fps: a kick is over in a few frames
        interval: Math.round(1000 / Math.max(5, wallpaper.hearing ? 60 : 0, wallpaper.cfg.Fps))
        repeat: true
        running: wallpaper.running && wallpaper.visible
        onTriggered: lava.time += interval / 1000 * wallpaper.cfg.Speed * wallpaper.flow
            * (1 + 0.3 * wallpaper.live + 1.3 * wallpaper.level + 0.6 * wallpaper.kick)  // louder flows faster, a kick shoves
    }
}
