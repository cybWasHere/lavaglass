#!/usr/bin/env python3
"""lamp-audio: listens to the music that's playing and tells the lava lamps what it hears.

Which apps count is decided by MPRIS, the desktop's media-key interface: whatever says "Playing"
there (Pear, a browser tab on YouTube or SoundCloud, a radio or music player) is followed, and
nothing else, so games and voice chat never move the lamp. Their audio is captured from PipeWire
(never the microphone: the recorder starts unlinked and is wired by hand to those apps' output
ports only), boiled down to five numbers 60 times a second, and streamed over a WebSocket on
loopback:

    "bass mid high kick level"      each 0..1, e.g. "0.412 0.220 0.105 0.870 0.630"

bass/mid/high follow the energy in three bands, kick jumps on a bass onset and falls off, level
is the overall loudness. All are normalised to the recent past, so the app's volume doesn't
matter. Silence sends one line of zeros and then nothing. It only records while a lamp listens.

The same port answers plain HTTP, for the colours:

    GET /query        what is playing, in the shape of Pear's Amuse API (player.hasSong,
                      player.seekbarCurrentPosition, track.id/title/author/url/cover)
                      + video.id/title while a YouTube video plays in a browser, music or not
                      (the portrait wallpaper then takes the colour of that video's window)
    GET /cover/<id>   that track's cover picture

YouTube in a browser is followed per video, not as a whole: the video's category is read off
its watch page (one request to youtube.com per video, remembered) and only "Music" moves the
lamp, so talk doesn't. If that can't be read, the video is followed as before.

LAMP_AUDIO_IGNORE: words (space separated) that, found in a player's page address or title,
keep it from being followed, e.g. "twitch.tv franceinfo". LAMP_AUDIO_MUSIC: words that, found in
the address, title or channel of a YouTube video, make it count as music whatever its category
(for mixes filed under "Entertainment"). LAMP_AUDIO_PREFER: the apps that win when several play
at once. LAMP_AUDIO_ORIGINS: web pages (space separated origins) that may read all this, e.g.
"http://127.0.0.1:9875" for a start page served there. Without it only programs get in (the
wallpaper, curl): a page opened from a file can't be told apart from any website's sandboxed
frame, both say "null", so it has to be served from an address to be let in.

Clients: the Plasma wallpaper (../wallpaper) and the startpage's lamp.
Run by the user unit lamp-audio.service; `lamp-audio.py --watch` prints what a lamp would get.
"""
import asyncio, base64, hashlib, http.client, json, os, re, struct, sys, threading, time, urllib.request
from urllib.parse import parse_qs, unquote, urlparse
import numpy as np
from gi.repository import Gio, GLib

HOST, PORT = "127.0.0.1", int(os.environ.get("LAMP_AUDIO_PORT", 9873))
PREFER = os.environ.get("LAMP_AUDIO_PREFER", "youtube-music").split()   # process names, best first
IGNORE = os.environ.get("LAMP_AUDIO_IGNORE", "").lower().split()
MUSIC = os.environ.get("LAMP_AUDIO_MUSIC", "").lower().split()
ORIGINS = {o.rstrip("/") for o in os.environ.get("LAMP_AUDIO_ORIGINS", "").replace(",", " ").split()}
RATE, HOP, WIN = 48000, 800, 2048                         # 60 lines a second, 43 ms analysis window
DT = HOP / RATE
BANDS = ((35, 150), (300, 2500), (5000, 14000))           # Hz: bass, mid, high
NODE = f"lamp-audio-{os.getpid()}"                         # per process: --watch next to the service wires its own recorder
IDLE_STOP = 30                                            # s without a listener before the recorder is stopped
LINGER = 3                                                # s a player stays wired after it stops playing
HUSH = 8                                                  # s of silence before "Playing" isn't believed


def fall(seconds):
    """Per-line factor for something that should halve in `seconds`."""
    return 0.5 ** (DT / seconds)


def toward(now, target, up, down):
    """Ease `now` to `target`, with separate time constants (s) for rising and falling."""
    tau = np.where(target > now, up, down)
    return now + (target - now) * (1 - np.exp(-DT / tau))


class Ears:
    FLOOR = 2e-4   # references never drop below this, so a quiet hiss isn't blown up into "music"
    GATE = 1e-4    # rms under this is silence (a paused Chromium sends exact zeros)

    def __init__(self):
        self.buf = np.zeros(WIN, np.float32)
        self.win = np.hanning(WIN).astype(np.float32)
        self.scale = 2 / self.win.sum()                    # a full-scale sine reads 1
        f = np.fft.rfftfreq(WIN, 1 / RATE)
        self.masks = [(f >= lo) & (f < hi) for lo, hi in BANDS]
        self.band_ref = np.full(3, self.FLOOR)
        self.band = np.zeros(3)
        self.bass_avg = 0.0
        self.flux_ref = self.FLOOR
        self.kick = 0.0
        self.level_ref = self.FLOOR
        self.level = 0.0
        self.quiet = 0.0

    def hear(self, x):
        """x: HOP mono samples. Returns (bass, mid, high, kick, level)."""
        self.buf = np.concatenate((self.buf[HOP:], x))
        rms = float(np.sqrt(np.mean(x * x)))
        self.quiet = self.quiet + DT if rms < self.GATE else 0.0
        if self.quiet > 0.3:                               # let everything ring out
            self.band = toward(self.band, 0.0, 0.02, np.array([0.15, 0.2, 0.12]))
            self.kick *= np.exp(-DT / 0.16)
            self.level = float(toward(self.level, 0.0, 0.1, 0.4))
            self.bass_avg = 0.0
            return self.out()

        spec = np.abs(np.fft.rfft(self.buf * self.win)) * self.scale
        vals = np.array([np.sqrt(np.mean(spec[m] ** 2)) for m in self.masks])

        # bands: against their loudest recent moment (10 s), squared so peaks stand out of a busy mix
        self.band_ref = np.maximum(np.maximum(vals, self.band_ref * fall(10)), self.FLOOR)
        self.band = toward(self.band, (vals / self.band_ref) ** 2, 0.02, np.array([0.15, 0.2, 0.12]))

        # kick: bass rising above its own last quarter second
        flux = max(vals[0] - self.bass_avg, 0.0)
        self.bass_avg += (vals[0] - self.bass_avg) * (1 - np.exp(-DT / 0.25))
        self.flux_ref = max(flux, self.flux_ref * fall(6), self.FLOOR)
        hit = min(max((flux / self.flux_ref - 0.3) / 0.7, 0.0), 1.0)
        self.kick = max(hit, self.kick * np.exp(-DT / 0.16))

        # level: loudness against the loudest of the last while, so a breakdown reads as one
        self.level_ref = max(rms, self.level_ref * fall(20), self.FLOOR)
        loud = min(max((rms / self.level_ref - 0.25) / 0.7, 0.0), 1.0)   # mastered music lives in the top third: spread it out
        self.level = float(toward(self.level, loud, 0.1, 0.4))
        return self.out()

    def out(self):
        v = [*self.band, self.kick, self.level]
        return tuple(0.0 if a < 0.004 else min(float(a), 1.0) for a in v)


# --- MPRIS: who is playing ---------------------------------------------------------------------

MPRIS, DBUS = "org.mpris.MediaPlayer2", "org.freedesktop.DBus"


def binary(pid):
    try:
        return os.path.basename(os.readlink(f"/proc/{pid}/exe"))
    except OSError:
        return ""


def family(pid):
    """pid and its ancestors (a browser's audio may come from a child process)."""
    out = []
    try:
        while pid > 1 and len(out) < 8:
            out.append(pid)
            with open(f"/proc/{pid}/stat") as f:
                pid = int(f.read().rsplit(")", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return out


def youtube_id(url):
    """The video a YouTube page address points to, or "" (YouTube Music is music: not asked)."""
    u = urlparse(url)
    host = (u.hostname or "").removeprefix("www.").removeprefix("m.")
    if host == "youtu.be":
        return u.path[1:]
    if host != "youtube.com":
        return ""
    if u.path == "/watch":
        return parse_qs(u.query).get("v", [""])[0]
    part = u.path.split("/")
    return part[2] if len(part) > 2 and part[1] in ("shorts", "live", "embed") else ""


def youtube_category(vid):
    """"Music", "Entertainment"... as YouTube files that video; "" if it can't be read."""
    try:
        req = urllib.request.Request("https://www.youtube.com/watch?v=" + vid, headers={
            "Cookie": "SOCS=CAI", "Accept-Language": "en",      # the cookie skips the EU consent page
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0"})
        with urllib.request.urlopen(req, timeout=8) as r:
            m = re.search(rb'"category":"([^"]*)"', r.read(4 << 20))
        return m.group(1).decode() if m else ""
    except (OSError, ValueError, http.client.HTTPException):   # a body cut short is not an OSError
        return ""


class Players:
    """The apps that say "Playing" on the session bus, one entry per process:
    {pid, app, id, title, author, url, art, since}. read() runs in a worker thread."""

    def __init__(self, loop):
        self.playing = []
        self.video = None               # the YouTube video playing in a browser, whatever its category
        self.seen = {}                  # pid -> (app, when it last said Playing): wired until LINGER later
        self.since = {}                 # pid -> when it started playing
        self.covers = {}                # track id -> local file, for GET /cover/<id>
        self.kinds = {}                 # YouTube video id -> its category (None while being asked)
        self.changed = asyncio.Event()  # a player said something: read again now
        self.rewire = False             # the set of players changed: wire() now
        self.lock = threading.Lock()    # seen and rewire: read() writes them from its thread, listen() reads them
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        poke = self.poke = lambda *a: loop.call_soon_threadsafe(self.changed.set)
        self.bus.signal_subscribe(None, DBUS + ".Properties", "PropertiesChanged", "/org/mpris/MediaPlayer2",
                                  None, Gio.DBusSignalFlags.NONE, poke)
        self.bus.signal_subscribe(DBUS, DBUS, "NameOwnerChanged", None, MPRIS,
                                  Gio.DBusSignalFlags.MATCH_ARG0_NAMESPACE, poke)
        threading.Thread(target=GLib.MainLoop().run, daemon=True).start()   # delivers those signals

    def call(self, dest, path, iface, method, *args):
        sig = GLib.Variant("(" + "s" * len(args) + ")", args) if args else None
        return self.bus.call_sync(dest, path, iface, method, sig, None, Gio.DBusCallFlags.NONE, 500, None).unpack()[0]

    def music(self, said):
        """Is this worth following? Anything but YouTube: yes. YouTube: videos filed under Music."""
        vid = youtube_id(said["url"])
        if not vid or any(w in " ".join((said["url"], said["title"], said["author"])).lower() for w in MUSIC):
            return True
        if vid not in self.kinds:
            self.kinds[vid] = None      # not followed until the answer is in (about a second)
            def ask():
                self.kinds[vid] = youtube_category(vid)
                self.poke()
            threading.Thread(target=ask, daemon=True).start()
            for k in list(self.kinds)[:-200]:
                del self.kinds[k]
        return self.kinds[vid] in ("Music", "")

    def read(self):
        found, video = {}, None
        try:
            names = [n for n in self.call(DBUS, "/org/freedesktop/DBus", DBUS, "ListNames") if n.startswith(MPRIS + ".")]
        except GLib.Error:
            names = []
        for name in names:
            try:
                p = self.call(name, "/org/mpris/MediaPlayer2", DBUS + ".Properties", "GetAll", MPRIS + ".Player")
                if p.get("PlaybackStatus") != "Playing":
                    continue
                meta = p.get("Metadata") or {}
                # Plasma's browser integration speaks for the browser, and says which one
                pid = meta.get("kde:pid") or self.call(DBUS, "/org/freedesktop/DBus", DBUS, "GetConnectionUnixProcessID", name)
            except GLib.Error:
                continue
            art = str(meta.get("mpris:artUrl") or "")
            said = {"title": str(meta.get("xesam:title") or ""), "url": str(meta.get("xesam:url") or ""), "art": art,
                    "author": ", ".join(a for a in meta.get("xesam:artist") or [] if a)}
            # the integration knows the tab that plays; Firefox itself may name the page it first loaded
            if youtube_id(said["url"]) and (video is None or "kde:pid" in meta):
                video = {"id": youtube_id(said["url"]), "title": said["title"]}
            if any(w in (said["url"] + " " + said["title"]).lower() for w in IGNORE) or not self.music(said):
                continue
            # a browser shows up twice (itself + the integration): the one with a picture speaks first
            mine = found.setdefault(pid, {"pid": pid, "app": binary(pid)})
            for k, v in said.items():
                if v and (art or not mine.get(k)):
                    mine[k] = v
        now = time.monotonic()
        self.since = {pid: self.since.get(pid, now) for pid in found}
        for pid, t in found.items():
            for k in ("title", "author", "url", "art"):
                t.setdefault(k, "")
            t["since"] = self.since[pid]
            t["id"] = hashlib.sha1("|".join((t["app"], t["title"], t["author"], t["url"], t["art"])).encode()).hexdigest()[:16]
            if t["art"].startswith("file://"):
                self.covers[t["id"]] = unquote(urlparse(t["art"]).path)
        for k in list(self.covers)[:-8]:
            del self.covers[k]
        rank = lambda t: (PREFER.index(t["app"]) if t["app"] in PREFER else len(PREFER), -t["since"])
        playing = sorted(found.values(), key=rank)
        with self.lock:
            for pid, t in found.items():
                self.seen[pid] = (t["app"], now)
            if {t["pid"] for t in playing} != {t["pid"] for t in self.playing}:
                self.rewire = True
        self.playing = playing
        self.video = video

    def wired(self):
        """(pids, app names) whose audio the lamp should hear right now."""
        now = time.monotonic()
        for pid in [p for p, (_, at) in list(self.seen.items()) if now - at > LINGER]:
            del self.seen[pid]
            self.rewire = True
        return set(self.seen), {app for app, _ in self.seen.values() if app}

    async def follow(self):
        while True:
            await asyncio.to_thread(self.read)
            try:
                await asyncio.wait_for(self.changed.wait(), 1 if self.seen else 5)
                await asyncio.sleep(0.05)       # a track change is a burst of signals
            except asyncio.TimeoutError:
                pass
            self.changed.clear()


# --- PipeWire -------------------------------------------------------------------------------

async def run(*cmd):
    p = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    out, _ = await p.communicate()
    return out


async def wire(pids, apps):
    """Link the output ports of those players' streams to the recorder, and unlink everyone else."""
    try:
        dump = json.loads(await run("pw-dump"))
    except ValueError:
        return
    props = lambda o: (o.get("info") or {}).get("props") or {}
    nodes = [o for o in dump if o["type"].endswith(":Node")]
    me = next((o["id"] for o in nodes if props(o).get("node.name") == NODE), None)

    def theirs(o):
        p = props(o)
        if p.get("media.class") != "Stream/Output/Audio":
            return False
        try:
            kin = family(int(p.get("application.process.id") or 0))
        except ValueError:
            kin = []
        return bool(pids.intersection(kin)) or p.get("application.process.binary") in apps

    players = {o["id"] for o in nodes if theirs(o)}
    ports = [o for o in dump if o["type"].endswith(":Port")]
    mine = next((o["id"] for o in ports if props(o).get("node.id") == me and o["info"]["direction"] == "input"), None)
    if me is None or mine is None:
        return
    want = {o["id"] for o in ports if props(o).get("node.id") in players and o["info"]["direction"] == "output"}
    linked = {o["info"]["output-port-id"] for o in dump if o["type"].endswith(":Link") and o["info"]["input-port-id"] == mine}
    for port in want - linked:
        await run("pw-link", str(port), str(mine))
    for port in linked - want:
        await run("pw-link", "-d", str(port), str(mine))


class Recorder:
    """pw-record, started unlinked (--target 0) so the session manager never wires it to a microphone.
    The odd media.class keeps it out of the "an app is recording" tray indicator."""

    def __init__(self):
        self.proc = None
        self.heard = 0.0                        # when it last heard anything but silence

    async def start(self):
        self.proc = await asyncio.create_subprocess_exec(
            "pw-record", "--target", "0", "--raw", "--rate", str(RATE), "--channels", "1", "--format", "f32",
            "--latency", "20ms", "-P",
            f'{{ node.name = "{NODE}" node.description = "Lava lamp (listens to the music playing)" media.class = "Stream/Input/Audio/Internal" }}',
            "-", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        self.heard = time.monotonic()           # HUSH counts from here, not from before it was stopped

    async def stop(self):
        if self.proc and self.proc.returncode is None:
            self.proc.terminate()
            await self.proc.wait()
        self.proc = None

    @property
    def alive(self):
        return self.proc is not None and self.proc.returncode is None


async def listen(emit, wanted, players, rec):
    """Record while wanted() says a lamp is listening; emit(values) for every line."""
    ears = Ears()
    zeros = (0.0,) * 5
    last, idle_since, next_wire = zeros, None, 0.0
    while True:
        if not wanted():
            idle_since = idle_since or time.monotonic()
            if rec.alive and time.monotonic() - idle_since > IDLE_STOP:
                await rec.stop()
            if not rec.alive:
                await asyncio.sleep(0.5)
                continue
        else:
            idle_since = None
        if not rec.alive:
            await rec.start()
            ears, next_wire = Ears(), time.monotonic() + 0.5
        try:
            raw = await asyncio.wait_for(rec.proc.stdout.readexactly(HOP * 4), 1.0)
            v = ears.hear(np.frombuffer(raw, "<f4"))
        except asyncio.TimeoutError:            # nothing linked, or the player's stream is corked
            v = zeros
        except asyncio.IncompleteReadError:     # pw-record died (PipeWire restarted?)
            await rec.stop()
            await asyncio.sleep(2)
            v = zeros
        if v != zeros:
            rec.heard = time.monotonic()
        if v != zeros or last != zeros:
            emit(v)
        last = v
        # streams come and go (and may be replaced): look at once when the players change, often
        # while it's silent, now and then otherwise. Nobody playing and nothing wired: nothing to do.
        with players.lock:                      # not while read() is adding a player
            pids, apps = players.wired()
            if rec.alive and (players.rewire or time.monotonic() >= next_wire):
                next_wire = time.monotonic() + (2 if v == zeros else 10)
                if pids or players.rewire:
                    asyncio.ensure_future(wire(pids, apps))
                players.rewire = False


# --- HTTP: what is playing, for the colours ----------------------------------------------------

def now_playing(players, rec):
    """Amuse's /query shape, so a lamp written for Pear reads it unchanged. The seekbar is the clock:
    those lamps only believe a position that moves."""
    t = players.playing[0] if players.playing else None
    video = {"video": players.video} if players.video else {}   # sound or not, music or not
    # a muted tab or a stalled stream still says Playing: believe it only while there is sound
    if not t or (rec.alive and clients and time.monotonic() - rec.heard > HUSH):
        return {"player": {"hasSong": False, "isPaused": True}, **video}
    cover = f"http://{HOST}:{PORT}/cover/{t['id']}" if t["id"] in players.covers else t["art"]
    return {"player": {"hasSong": True, "isPaused": False, "seekbarCurrentPosition": int(time.time())},
            "track": {"id": t["id"], "title": t["title"], "author": t["author"], "url": t["url"], "cover": cover,
                      "app": t["app"], "isAdvertisement": False}, **video}


def picture(path):
    try:
        with open(path, "rb") as f:
            body = f.read(8 << 20)
    except OSError:
        return None, None
    kind = ("image/png" if body[:4] == b"\x89PNG" else "image/webp" if body[8:12] == b"WEBP"
            else "image/gif" if body[:3] == b"GIF" else "image/jpeg")
    return body, kind


def page(path, players, rec):
    """(status, content type, body) for a plain GET."""
    path = path.split("?", 1)[0]
    if path == "/query":
        return "200 OK", "application/json", json.dumps(now_playing(players, rec)).encode()
    if path.startswith("/cover/"):
        body, kind = picture(players.covers.get(path[7:], ""))   # only covers of what's playing, never a path from the request
        if body:
            return "200 OK", kind, body
    return "404 Not Found", "text/plain", b""


# --- WebSocket (server to client only) ---------------------------------------------------------

clients = set()


def frame(text):
    b = text.encode()
    return bytes([0x81, len(b)]) + b            # lines are far under 126 bytes


async def client(reader, writer, players, rec):
    try:
        head = (await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 5)).decode("latin1")
        request = head.split("\r\n", 1)[0].split(" ")
        h = {k.strip().lower(): v.strip() for k, v in (l.split(":", 1) for l in head.split("\r\n")[1:] if ":" in l)}
        # Qt and curl send no Origin; a web page always does on the calls that would let it read
        # the answer, and it gets in only if it is listed. "null" is never trusted: a file:// page
        # says it, but so does a sandboxed frame on any website. And the Host must be ours, or a
        # site that renamed itself to 127.0.0.1 after loading would count as the same origin.
        origin = h.get("origin")
        if (origin is not None and origin not in ORIGINS) or h.get("host", "").rsplit(":", 1)[0] not in ("127.0.0.1", "localhost"):
            writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            return
        if "sec-websocket-key" not in h:
            status, kind, body = page(request[1], players, rec) if len(request) > 1 and request[0] == "GET" else ("400 Bad Request", "text/plain", b"")
            cors = f"Access-Control-Allow-Origin: {origin}\r\nVary: Origin\r\n" if origin else ""
            writer.write((f"HTTP/1.1 {status}\r\nContent-Type: {kind}\r\nContent-Length: {len(body)}\r\n"
                          f"Cache-Control: no-store\r\n{cors}Connection: close\r\n\r\n").encode() + body)
            await writer.drain()
            return
        accept = base64.b64encode(hashlib.sha1((h["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        writer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        clients.add(writer)
        while True:                             # nothing to hear from a lamp; just notice it leaving
            b0, b1 = await reader.readexactly(2)
            n = b1 & 127
            if n == 126: n = struct.unpack(">H", await reader.readexactly(2))[0]
            elif n == 127: n = struct.unpack(">Q", await reader.readexactly(8))[0]
            await reader.readexactly((4 if b1 & 128 else 0) + n)
            if b0 & 15 == 8:
                writer.write(b"\x88\x00")
                break
    except (asyncio.IncompleteReadError, asyncio.TimeoutError, asyncio.LimitOverrunError, ConnectionError, ValueError):
        pass
    finally:
        clients.discard(writer)
        writer.close()


def broadcast(v):
    f = frame("%.3f %.3f %.3f %.3f %.3f" % v)
    for w in list(clients):
        if w.transport.get_write_buffer_size() > 4096:   # a stalled lamp gets the next line instead of a backlog
            continue
        w.write(f)


def watch(v):
    bar = lambda x: ("#" * round(x * 12)).ljust(12)
    sys.stdout.write("\rbass %s mid %s high %s kick %s level %s" % tuple(map(bar, v)))
    sys.stdout.flush()


async def main():
    players, rec = Players(asyncio.get_running_loop()), Recorder()
    following = asyncio.ensure_future(players.follow())
    if "--watch" in sys.argv:
        return await listen(watch, lambda: True, players, rec)
    server = await asyncio.start_server(lambda r, w: client(r, w, players, rec), HOST, PORT)
    async with server:
        await listen(broadcast, lambda: bool(clients), players, rec)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
