# lavaglass

A KDE Plasma 6 desktop in a box: a lava lamp wallpaper that moves to your music and takes its
colours from the cover (or from the video you are watching), see-through windows over blur,
rounded corners everywhere, the warm Ferra palette, and a small glass dock.

Wayland, Plasma 6. Everything installs into your home folder; nothing needs root.

## Install

```sh
git clone https://github.com/cybWasHere/lavaglass
cd lavaglass
./install.sh              # the default set
./install.sh all          # the opt-in parts too
./install.sh wallpaper    # or just the parts you name
```

Every config file the installer edits is copied first to
`~/.local/share/lavaglass/backups/<time>/`. Running it again is safe. `./uninstall.sh` takes it
out again.

## What is in it

| Part | What you get | Needs |
|---|---|---|
| `wallpaper` | **Lava Lamp**: slow wax blobs drifting through palettes. With `lamp-audio` it moves to the music and takes the cover's colours. On a portrait screen it takes the main colour of the YouTube video on screen, as it plays. | Plasma 6 |
| `lamp-audio` | A small service that works out what music is playing (any MPRIS player: a music app, a browser tab) and streams its bass, mids, highs and kick to the lamp. It never touches the microphone, and games and voice chat don't count. | `python-numpy`, `python-gobject`, PipeWire |
| `dock` | **Glass Dock**: time, date, weather and now playing in a glass pill at the top of a screen. Hover for seconds, a calendar and the week's forecast. | `cmake`, Qt 6, KWindowSystem, `layer-shell-qt` |
| `kwin-scripts` | **Gap Maximize**: on a landscape screen, maximize leaves a gap around the window. **Panel Edge Reveal**: a short centred auto-hiding panel comes up from the whole bottom edge. | |
| `corners` | Klassy window decoration without borders, and 10 px rounded corners on every window. | [Klassy](https://github.com/paulmcauley/klassy), [KDE Rounded Corners](https://github.com/matinlotfali/KDE-Rounded-Corners) |
| `glass` | Konsole, Halloy, Chatterino and OBS at 80% over blur, title bars included. | Klassy, [Better Blur DX](https://github.com/xarblu/kwin-effects-better-blur-dx) |
| `themes` | Ferra colours (peach on dark plum, from [Halloy](https://halloy.chat)) for Konsole, Halloy and Chatterino. | |
| `round-tasks` *(opt-in)* | Round highlights behind the task manager's icons. | |
| `firefox` *(opt-in)* | Glass toolbar and tabs in Firefox; pages stay opaque. Edits `userChrome.css`. | Better Blur DX |
| `see-through` *(opt-in)* | `firefox`, plus a new tab page with no background shows the glass. Pairs with the See-through mode of [startpage](https://github.com/cybWasHere/startpage). | |

A part whose needs are missing is skipped with a note; the rest still installs.

On Arch and CachyOS the three extras are in the AUR:

```sh
paru -S klassy-bin kwin-effect-rounded-corners-git kwin-effects-better-blur-dx
```

The icon theme that goes with it is [Tela](https://github.com/vinceliuice/Tela-icon-theme).

## After installing

- **Wallpaper**: right-click the desktop, Desktop and Wallpaper, Wallpaper type: Lava Lamp. Its
  settings have the palette, speed, frame rate, and "Two waxes merging make a new colour", which
  is off by default and rather wild.
- **Glass Dock**: put your coordinates and, if you have several, a word from your screen's model
  name in `~/.config/lavaglass/glass-dock.json`, then `systemctl --user restart glass-dock`.
- **Gap Maximize**: press Meta+T on the landscape screen, keep one full-screen tile and give it
  some padding. That padding is the gap.
- Log out and back in once so KWin loads the new scripts and effects.

If blur disappears after a KWin update, rebuild Better Blur DX: it is compiled against KWin.

## Tuning lamp-audio

Set these in a drop-in (`systemctl --user edit lamp-audio`):

```ini
[Service]
Environment=LAMP_AUDIO_IGNORE="twitch.tv"       # never follow these (address or title)
Environment=LAMP_AUDIO_MUSIC="lofi mix"         # YouTube videos to count as music anyway
```

YouTube videos move the lamp only when they are filed under Music, so talk doesn't. Reading that
takes one request to youtube.com per video. `lamp-audio.py --watch` prints what a lamp would get.

## Working on it

`./install.sh --link` symlinks into this folder instead of copying, so edits are live after a
restart of the service or of Plasma. After changing `wallpaper/contents/shaders/lava.frag`:

```sh
/usr/lib/qt6/bin/qsb --qt6 -o lava.frag.qsb lava.frag
```

## Licence

MIT. The Ferra palette is Halloy's.
