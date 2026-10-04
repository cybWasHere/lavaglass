#!/usr/bin/env bash
# lavaglass installer. Everything goes into your home folder; nothing needs root.
#
#   ./install.sh                     the default set (see below)
#   ./install.sh wallpaper dock      only these parts
#   ./install.sh all                 every part, the opt-in ones too
#
# Parts, default set:
#   wallpaper     Lava Lamp wallpaper for Plasma
#   lamp-audio    the service that lets the lamp (and the dock) follow the music
#   dock          Glass Dock: time, weather, now playing in a glass pill
#   kwin-scripts  Gap Maximize and Panel Edge Reveal
#   corners       Klassy window decoration, no borders, corners rounded on every window
#   glass         see-through Konsole, Halloy, Chatterino and OBS over blur
#   themes        Ferra colours for Konsole, Halloy and Chatterino
# Opt-in:
#   round-tasks   round highlights behind the task manager's icons
#   firefox       glass toolbar and tabs in Firefox (edits userChrome.css)
#   see-through   firefox + a new tab page with no background shows the glass
#
# Options:
#   --link        symlink into this folder instead of copying (to work on the code)
#   --no-start    put the files in place but don't start services or reload KWin
#
# Config files that get edited are copied first to ~/.local/share/lavaglass/backups/<time>/.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
CONF=${XDG_CONFIG_HOME:-$HOME/.config}
PREFIX=$DATA/lavaglass
BACKUPS=$PREFIX/backups/$(date +%Y-%m-%d-%H%M%S)
DEFAULT=(wallpaper lamp-audio dock kwin-scripts corners glass themes)
OPTIN=(round-tasks firefox see-through)
LINK=0 START=1 PARTS=() NOTES=() KWIN_DIRTY=0 BLUR_DIRTY=0

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { NOTES+=("$*"); }
have() { command -v "$1" >/dev/null 2>&1; }
kread()  { kreadconfig6 --file "$1" --group "$2" --key "$3"; }
kwrite() { kwriteconfig6 --file "$1" --group "$2" --key "$3" "$4"; }

declare -A SEEN
backup() { # copy a config file aside, before this run's first edit of it
    [[ -n ${SEEN[$1]:-} ]] && return 0
    SEEN[$1]=1
    [[ -f $1 ]] || return 0
    local to=$BACKUPS/${1#"$HOME"/}
    mkdir -p "$(dirname "$to")"
    cp -a "$1" "$to"
}

put() { # put <source> <target>: copy, or symlink with --link; replaces what was there
    local src=$1 dst=$2
    [[ $dst == "$DATA"/* || $dst == "$CONF"/* ]] || { echo "refusing to write $dst" >&2; exit 1; }
    mkdir -p "$(dirname "$dst")"
    if [[ -L $dst || -f $dst ]]; then rm -f "$dst"; elif [[ -d $dst ]]; then rm -rf "$dst"; fi
    if ((LINK)); then ln -s "$src" "$dst"; else cp -r "$src" "$dst"; fi
}

unit() { # install a user unit and (re)start it
    put "$1" "$CONF/systemd/user/$(basename "$1")"
    ((START)) || return 0
    systemctl --user daemon-reload
    systemctl --user enable "$(basename "$1")" >/dev/null 2>&1
    systemctl --user restart "$(basename "$1")"
}

blur_class() { # add window classes to Better Blur DX's list, keeping what is there
    local list c
    list=$(kread kwinrc Effect-better-blur-dx WindowClasses)
    for c in "$@"; do
        grep -qxF "$c" <<<"$list" || list+=${list:+$'\n'}$c
    done
    kwrite kwinrc Effect-better-blur-dx WindowClasses "$list"
    BLUR_DIRTY=1
}

opacity_rule() { # opacity_rule <id> <window class contains> <description>
    local id=$1 rules count
    # a rule of your own that already sets this app's opacity wins: leave it be
    if awk -v id="[$1]" -v pat="$2" '
            /^\[/ { if (hit && op) found = 1; grp = $0; hit = op = 0; next }
            grp != id && /^wmclass=/ && index(tolower($0), pat) { hit = 1 }
            /^opacityactiverule=/ { op = 1 }
            END { exit !(found || (hit && op)) }' "$CONF/kwinrulesrc" 2>/dev/null; then
        return 0
    fi
    rules=$(kread kwinrulesrc General rules)
    if [[ ,$rules, != *,$id,* ]]; then
        count=$(kread kwinrulesrc General count)
        kwrite kwinrulesrc General rules "${rules:+$rules,}$id"
        kwrite kwinrulesrc General count $(( ${count:-0} + 1 ))
    fi
    kwrite kwinrulesrc "$id" Description "$3"
    kwrite kwinrulesrc "$id" wmclass "$2"
    kwrite kwinrulesrc "$id" wmclassmatch 2
    kwrite kwinrulesrc "$id" types 1
    kwrite kwinrulesrc "$id" opacityactive 80
    kwrite kwinrulesrc "$id" opacityactiverule 2
    kwrite kwinrulesrc "$id" opacityinactive 80
    kwrite kwinrulesrc "$id" opacityinactiverule 2
    KWIN_DIRTY=1
}

klassy_exception() { # klassy_exception <window class pattern> <program name pattern>
    local rc=$CONF/klassy/klassyrc n=0
    grep -qxF "ExceptionWindowPropertyPattern=$1" "$rc" 2>/dev/null && return 0
    while grep -qxF "[Windeco Exception $n]" "$rc" 2>/dev/null; do n=$((n + 1)); done
    cat >>"$rc" <<EOF

[Windeco Exception $n]
Enabled=true
ExceptionBorder=false
ExceptionMatchTitleBarToApplicationColor=false
ExceptionPreset=Lavaglass
ExceptionProgramNamePattern=$2
ExceptionWindowPropertyPattern=$1
ExceptionWindowPropertyType=0
HideTitleBar=0
OpaqueTitleBar=false
PreventApplyOpacityToHeader=false
EOF
}

plugin() { compgen -G "/usr/lib*/qt6/plugins/$1" >/dev/null || compgen -G "/usr/lib/*/qt6/plugins/$1" >/dev/null; }
has_klassy() { plugin 'org.kde.kdecoration*/org.kde.klassy.so'; }
has_effect() { plugin "kwin/effects/plugins/$1.so"; }

# ── parts ────────────────────────────────────────────────────────────────────

do_wallpaper() {
    put "$HERE/wallpaper" "$DATA/plasma/wallpapers/org.cyb.lavalamp"
    note "Wallpaper: right-click the desktop > Desktop and Wallpaper > Wallpaper type: Lava Lamp."
}

do_lamp-audio() {
    local missing=()
    python3 -c 'import numpy' 2>/dev/null || missing+=(python-numpy)
    python3 -c 'from gi.repository import Gio' 2>/dev/null || missing+=(python-gobject)
    have pw-record && have pw-link || missing+=(pipewire)
    if ((${#missing[@]})); then
        note "lamp-audio skipped, it needs: ${missing[*]}. The lamp still drifts without it."
        return 0
    fi
    put "$HERE/lamp-audio" "$PREFIX/lamp-audio"
    unit "$HERE/lamp-audio/lamp-audio.service"
}

do_dock() {
    if ! have cmake; then note "Glass Dock skipped, it needs cmake and a C++ compiler to build."; return 0; fi
    if ! { cmake -S "$HERE/glass-dock" -B "$HERE/glass-dock/build" -DCMAKE_BUILD_TYPE=Release >/dev/null &&
           cmake --build "$HERE/glass-dock/build" >/dev/null; }; then
        note "Glass Dock skipped, the build failed. It needs Qt 6 (declarative), KWindowSystem and layer-shell-qt, with headers."
        return 0
    fi
    if ((LINK)); then
        put "$HERE/glass-dock" "$PREFIX/glass-dock"
    else
        rm -rf "$PREFIX/glass-dock"
        install -Dm755 "$HERE/glass-dock/build/glass-dock" "$PREFIX/glass-dock/build/glass-dock"
        install -m644 "$HERE/glass-dock/Dock.qml" "$HERE/glass-dock/icons.js" "$PREFIX/glass-dock/"
    fi
    if [[ ! -e $CONF/lavaglass/glass-dock.json ]]; then
        install -Dm644 "$HERE/glass-dock/config.example.json" "$CONF/lavaglass/glass-dock.json"
        note "Glass Dock: set your place (lat, lon) and screen in $CONF/lavaglass/glass-dock.json, then: systemctl --user restart glass-dock"
    fi
    unit "$HERE/glass-dock/glass-dock.service"
}

do_kwin-scripts() {
    local d id
    backup "$CONF/kwinrc"
    for d in "$HERE"/kwin-scripts/*/; do
        id=$(basename "$d")
        put "${d%/}" "$DATA/kwin/scripts/$id"
        kwrite kwinrc Plugins "${id}Enabled" true
    done
    KWIN_DIRTY=1
    note "Gap Maximize uses the tile gap: Meta+T on a landscape screen, one full-screen tile, set its padding."
}

do_corners() {
    backup "$CONF/kwinrc"
    if has_klassy; then
        backup "$CONF/klassy/klassyrc"
        kwrite kwinrc org.kde.kdecoration2 library org.kde.klassy
        kwrite kwinrc org.kde.kdecoration2 theme Klassy
        kwrite kwinrc org.kde.kdecoration2 BorderSize None
        kwrite kwinrc org.kde.kdecoration2 BorderSizeAuto false
        kwrite klassy/klassyrc Windeco WindowCornerRadius 10
    else
        note "Klassy is not installed: window decoration left as it is. https://github.com/paulmcauley/klassy"
    fi
    if has_effect kwin4_effect_shapecorners; then
        local k
        kwrite kwinrc Plugins kwin4_effect_shapecornersEnabled true
        kwrite kwinrc Round-Corners Size 10
        kwrite kwinrc Round-Corners InactiveCornerRadius 10
        for k in OutlineThickness InactiveOutlineThickness SecondOutlineThickness InactiveSecondOutlineThickness; do
            kwrite kwinrc Round-Corners "$k" 0
        done
    else
        note "KDE Rounded Corners is not installed: only title bars are rounded. https://github.com/matinlotfali/KDE-Rounded-Corners"
    fi
    KWIN_DIRTY=1
}

do_glass() {
    backup "$CONF/kwinrc"; backup "$CONF/kwinrulesrc"; backup "$CONF/konsolerc"
    if has_effect better_blur_dx; then
        kwrite kwinrc Plugins blurEnabled false
        kwrite kwinrc Plugins better_blur_dxEnabled true
        kwrite kwinrc Effect-better-blur-dx BlurMatching true
        blur_class org.squidowl.halloy com.chatterino.chatterino chatterino obs
    else
        note "Better Blur DX is not installed: Halloy, Chatterino and OBS will be see-through but not blurred. https://github.com/xarblu/kwin-effects-better-blur-dx"
    fi
    if has_klassy; then
        local presets=$CONF/klassy/windecopresetsrc
        backup "$presets"; backup "$CONF/klassy/klassyrc"
        mkdir -p "$CONF/klassy"
        grep -qxF '[Windeco Preset Lavaglass]' "$presets" 2>/dev/null || { echo; cat "$HERE/glass/klassy-preset.ini"; } >>"$presets"
        klassy_exception konsole konsole
        klassy_exception halloy ''
        kwrite konsolerc KDE widgetStyle klassy
    else
        note "Klassy is not installed: title bars stay opaque."
    fi
    opacity_rule lavaglass-chatterino chatterino "lavaglass: Chatterino at 80% (glass)"
    opacity_rule lavaglass-obs obs "lavaglass: OBS at 80% (glass)"
}

do_themes() {
    put "$HERE/themes/konsole/Ferra-Glass.colorscheme" "$DATA/konsole/Ferra-Glass.colorscheme"
    if [[ ! -e $DATA/konsole/Lavaglass.profile ]]; then
        printf '[Appearance]\nColorScheme=Ferra-Glass\n\n[General]\nName=Lavaglass\nParent=FALLBACK/\n' >"$DATA/konsole/Lavaglass.profile"
    fi
    if [[ -z $(kread konsolerc 'Desktop Entry' DefaultProfile) ]]; then
        backup "$CONF/konsolerc"
        kwrite konsolerc 'Desktop Entry' DefaultProfile Lavaglass.profile
    else
        note "Konsole: pick the colour scheme 'Ferra Glass' in your profile (Settings > Edit Current Profile > Appearance)."
    fi

    put "$HERE/themes/halloy/ferra-glass.toml" "$CONF/halloy/themes/ferra-glass.toml"
    local hc=$CONF/halloy/config.toml
    if [[ -f $hc ]]; then
        if ! grep -qE '^theme[[:space:]]*=' "$hc"; then
            backup "$hc"
            sed -i '1i theme = "ferra-glass"' "$(readlink -f "$hc")"
        elif ! grep -qE '^theme[[:space:]]*=[[:space:]]*"ferra-glass"' "$hc"; then
            note "Halloy: set  theme = \"ferra-glass\"  in $hc"
        fi
    fi

    local dir found=0
    for dir in "$HOME/.var/app/com.chatterino.chatterino/data/chatterino" "$DATA/chatterino"; do
        [[ -d $dir ]] || continue
        mkdir -p "$dir/Themes"
        cp "$HERE/themes/chatterino/Ferra.json" "$dir/Themes/Ferra.json"
        found=1
    done
    ((found)) && note "Chatterino: pick the theme 'Ferra' in Settings > General > Theme."
    return 0
}

do_round-tasks() {
    local theme
    theme=$(kread plasmarc Theme name); theme=${theme:-default}
    if [[ ! -e /usr/share/plasma/desktoptheme/$theme && ! -e $DATA/plasma/desktoptheme/$theme/metadata.json ]]; then
        note "round-tasks skipped: Plasma style '$theme' not found."
        return 0
    fi
    if ! python3 "$HERE/tools/rounded-tasks-svg.py" 7 4 "$theme" >/dev/null; then
        note "round-tasks failed, see the error above; the rest went on."
        return 0
    fi
    note "Round task highlights: restart Plasma to see them (systemctl --user restart plasma-plasmashell)."
}

ff_profiles() { # the profile each Firefox install starts with, else the default one
    local base
    for base in "$HOME/.mozilla/firefox" "$CONF/mozilla/firefox" "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"; do
        [[ -f $base/profiles.ini ]] || continue
        awk -F= -v base="$base" '
            function full(p) { return p ~ /^\// ? p : base "/" p }
            /^\[/ { sec = $0; next }
            sec ~ /^\[Install/ && $1 == "Default" { used[$2] = 1; n++ }
            sec ~ /^\[Profile/ && $1 == "Path" { path = $2 }
            sec ~ /^\[Profile/ && $1 == "Default" && $2 == "1" { def = path }
            END { if (n) { for (p in used) print full(p) } else if (def) print full(def) }' "$base/profiles.ini"
    done
}

ff_block() { # ff_block <profile> <name>: put glass/firefox/<name>.css between markers in userChrome.css
    local css=$1/chrome/userChrome.css begin="/* lavaglass:$2 begin */" end="/* lavaglass:$2 end */" tmp
    mkdir -p "$1/chrome"; touch "$css"; backup "$css"
    tmp=$(mktemp)
    awk -v b="$begin" -v e="$end" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$css" >"$tmp"
    { cat "$tmp"; echo "$begin"; cat "$HERE/glass/firefox/$2.css"; echo "$end"; } >"$css"
    rm -f "$tmp"
}

ff_pref() { # ff_pref <profile> <pref>: set it to true in user.js
    local js=$1/user.js
    grep -qF "\"$2\"" "$js" 2>/dev/null && return 0
    backup "$js"
    echo "user_pref(\"$2\", true);" >>"$js"
}

do_firefox() {
    local p n=0
    while IFS= read -r p; do
        [[ -d $p ]] || continue
        n=$((n + 1))
        if grep -q -- '--glass-tint' "$p/chrome/userChrome.css" 2>/dev/null &&
           ! grep -qF '/* lavaglass:glass begin */' "$p/chrome/userChrome.css"; then
            note "Firefox: $p already has its own glass block in userChrome.css, left alone."
            continue
        fi
        ff_block "$p" glass
        ff_pref "$p" toolkit.legacyUserProfileCustomizations.stylesheets
        if [[ ${1:-} == see-through ]]; then
            ff_block "$p" see-through
            ff_pref "$p" browser.tabs.allow_transparent_browser
        fi
    done < <(ff_profiles)
    if ((n == 0)); then note "Firefox: no profile found, nothing done."; return 0; fi
    backup "$CONF/kwinrc"
    has_effect better_blur_dx && blur_class firefox
    note "Firefox: restart it. Its glass tint matches Breeze Dark; change --glass-tint in userChrome.css for another theme."
    [[ ${1:-} == see-through ]] && note "See-through: pages with no background of their own are now drawn on the dark tab backdrop, not white."
    return 0
}

do_see-through() { do_firefox see-through; }

# ── run ──────────────────────────────────────────────────────────────────────

for a in "$@"; do
    case $a in
        --link) LINK=1 ;;
        --no-start) START=0 ;;
        -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
        all) PARTS+=("${DEFAULT[@]}" round-tasks see-through) ;;
        *) if declare -F "do_$a" >/dev/null; then PARTS+=("$a"); else echo "unknown part: $a (try --help)" >&2; exit 2; fi ;;
    esac
done
((${#PARTS[@]})) || PARTS=("${DEFAULT[@]}")

for c in kreadconfig6 kwriteconfig6; do
    have "$c" || { echo "$c not found: this needs KDE Plasma 6." >&2; exit 1; }
done

for p in "${PARTS[@]}"; do
    say "· $p"
    "do_$p"
done

if ((START)); then
    QDBUS=$(command -v qdbus6 || command -v qdbus-qt6 || command -v qdbus || true)
    if [[ -n $QDBUS ]]; then
        ((KWIN_DIRTY || BLUR_DIRTY)) && "$QDBUS" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
        ((BLUR_DIRTY)) && "$QDBUS" org.kde.KWin /Effects reconfigureEffect better_blur_dx >/dev/null 2>&1 || true
    fi
fi

echo
say "Done."
[[ -d $BACKUPS ]] && echo "Edited config files were first copied to $BACKUPS"
((${#NOTES[@]})) && printf ' - %s\n' "${NOTES[@]}"
((KWIN_DIRTY && START)) && echo " - New KWin scripts and effects are fully loaded after you log out and back in."
exit 0
