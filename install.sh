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
LINK=0 START=1 PARTS=() TODO=() EXTRAS=() SKIPPED=0 KWIN_DIRTY=0 BLUR_DIRTY=0

# Colours and the spinner only on a real terminal; NO_COLOR or a pipe gets plain lines.
# The Ferra pink and coral where the terminal has true colour, plain magenta and yellow elsewhere.
if [[ -t 1 && -t 2 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    FANCY=1
    BOLD=$'\e[1m' DIM=$'\e[2m' RESET=$'\e[0m' GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m'
    case ${COLORTERM:-} in
        truecolor|24bit) PINK=$'\e[38;2;246;182;201m' CORAL=$'\e[38;2;255;160;122m' ;;
        *) PINK=$'\e[35m' CORAL=$'\e[33m' ;;
    esac
else
    FANCY=0 BOLD="" DIM="" RESET="" GREEN="" YELLOW="" RED="" PINK="" CORAL=""
fi
case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) OK_MARK=✓ BAD_MARK=✗ DOT=● SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) ;;
    *) OK_MARK=+ BAD_MARK=x DOT='*' SPIN=('|' / - "\\") ;;
esac

die()   { printf '%s%s Error:%s %s\n' "$RED" "$BAD_MARK" "$RESET" "$*" >&2; exit 1; }
tilde() { printf '%s' "${1/#"$HOME"/\~}"; }
have()  { command -v "$1" >/dev/null 2>&1; }

banner() { printf '\n  %s%s%s %s%slavaglass%s  %sKDE Plasma 6 %s%s\n\n' "$CORAL" "$DOT" "$RESET" "$BOLD" "$PINK" "$RESET" "$DIM" "$1" "$RESET"; }

# One line of the checklist: row ok|todo|skip|fail LABEL [DETAIL]
row() {
    local mark colour
    case $1 in
        ok)   mark=$OK_MARK colour=$GREEN ;;
        todo) mark='!' colour=$YELLOW ;;
        fail) mark=$BAD_MARK colour=$RED; SKIPPED=$((SKIPPED + 1)) ;;
        *)    mark='-' colour=$DIM; SKIPPED=$((SKIPPED + 1)) ;;
    esac
    printf '  %s%s%s %-18s %s%s%s\n' "$colour" "$mark" "$RESET" "$2" "$DIM" "${3:-}" "$RESET"
}

# Something left for the person to do, listed at the end: todo TITLE [DETAIL]
todo() { TODO+=("$1"$'\t'"${2:-}"); }
# A missing extra (Klassy, ...): named once at the end, with where to get it
extra() { local e; for e in "${EXTRAS[@]}"; do [[ $e == "$1" ]] && return 0; done; EXTRAS+=("$1"); }

# Run a slow, quiet command behind a spinner with elapsed time; its output is shown only if
# it fails. The caller prints the row. Without a terminal it just runs.
run_step() {
    local label=$1 log pid rc=0 i=0 start=$SECONDS
    shift
    log=$(mktemp)
    if ((!FANCY)); then
        "$@" >"$log" 2>&1 </dev/null || rc=$?
    else
        "$@" >"$log" 2>&1 </dev/null &
        pid=$!
        # shellcheck disable=SC2064  # expand pid and log now
        trap "kill $pid 2>/dev/null; printf '\r\e[K\e[?25h  Interrupted.\n' >&2; rm -f '$log'; exit 130" INT TERM
        printf '\e[?25l'
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r  %s%s%s %s %s%ds%s' "$CORAL" "${SPIN[i++ % ${#SPIN[@]}]}" "$RESET" "$label" "$DIM" $((SECONDS - start)) "$RESET"
            sleep 0.1
        done
        wait "$pid" || rc=$?
        trap - INT TERM
        printf '\r\e[K\e[?25h'
    fi
    ((rc)) && sed 's/^/    /' "$log" >&2
    rm -f "$log"
    STEP_SECONDS=$((SECONDS - start))
    return "$rc"
}
kread()  { kreadconfig6 --file "$1" --group "$2" --key "$3"; }
kwrite() { kwriteconfig6 --file "$1" --group "$2" --key "$3" "$4"; }

declare -A SEEN
backup() { # copy a config file aside, before this run's first edit of it
    [[ -n ${SEEN[$1]:-} ]] && return 0
    SEEN[$1]=1
    [[ -f $1 ]] || return 0
    local to=$BACKUPS/${1#"$HOME"/}
    mkdir -p "$(dirname "$to")"
    cp -L --preserve=mode,timestamps "$1" "$to"   # the content, also when the config is a symlink (dotfiles)
}

put() { # put <source> <target>: copy, or symlink with --link; replaces what was there
    local src=$1 dst=$2
    [[ $dst == "$DATA"/* || $dst == "$CONF"/* ]] || die "refusing to write $dst"
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

opacity_rule() { # opacity_rule <id> <window class> <description> [<match: 2 contains (default), 3 regex>]
    local id=$1 match=${4:-2} rules count
    # a rule of your own that already sets this app's opacity wins: leave it be
    if awk -v id="[$1]" -v pat="$2" -v re="$((match == 3))" '
            /^\[/ { if (hit && op) found = 1; grp = $0; hit = op = 0; next }
            grp != id && /^wmclass=/ && (re ? tolower(substr($0, 9)) ~ tolower(pat) : index(tolower($0), pat)) { hit = 1 }
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
    kwrite kwinrulesrc "$id" wmclassmatch "$match"
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
    row ok "Lava Lamp" "wallpaper"
    todo "Pick the wallpaper" "right-click the desktop > Desktop and Wallpaper > Wallpaper type: Lava Lamp"
}

do_lamp-audio() {
    local missing=()
    python3 -c 'import numpy' 2>/dev/null || missing+=(python-numpy)
    python3 -c 'from gi.repository import Gio' 2>/dev/null || missing+=(python-gobject)
    have pw-record && have pw-link || missing+=(pipewire)
    if ((${#missing[@]})); then
        row skip "lamp-audio" "needs ${missing[*]}; the lamp still drifts without it"
        return 0
    fi
    put "$HERE/lamp-audio" "$PREFIX/lamp-audio"
    unit "$HERE/lamp-audio/lamp-audio.service"
    row ok "lamp-audio" "the lamp follows whatever music is playing"
}

build_dock() {
    cmake -S "$HERE/glass-dock" -B "$HERE/glass-dock/build" -DCMAKE_BUILD_TYPE=Release &&
    cmake --build "$HERE/glass-dock/build"
}

do_dock() {
    if ! have cmake; then row skip "Glass Dock" "needs cmake and a C++ compiler to build"; return 0; fi
    if ! run_step "Building Glass Dock" build_dock; then
        row fail "Glass Dock" "build failed: it needs Qt 6, KWindowSystem and layer-shell-qt, with headers"
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
        todo "Tell the dock where you live" "lat, lon and screen in $(tilde "$CONF/lavaglass/glass-dock.json"), then: systemctl --user restart glass-dock"
    fi
    unit "$HERE/glass-dock/glass-dock.service"
    row ok "Glass Dock" "built$( ((STEP_SECONDS > 1)) && echo " in ${STEP_SECONDS}s")"
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
    row ok "KWin scripts" "Gap Maximize, Panel Edge Reveal"
    todo "Set the gap for Gap Maximize" "Meta+T on the landscape screen, keep one full-screen tile, give it padding"
}

do_corners() {
    local lacks=()
    backup "$CONF/kwinrc"
    if has_klassy; then
        backup "$CONF/klassy/klassyrc"
        kwrite kwinrc org.kde.kdecoration2 library org.kde.klassy
        kwrite kwinrc org.kde.kdecoration2 theme Klassy
        kwrite kwinrc org.kde.kdecoration2 BorderSize None
        kwrite kwinrc org.kde.kdecoration2 BorderSizeAuto false
        kwrite klassy/klassyrc Windeco WindowCornerRadius 10
    else
        lacks+=("decoration left as it is (no Klassy)"); extra Klassy
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
        lacks+=("window content stays square (no KDE Rounded Corners)"); extra "KDE Rounded Corners"
    fi
    KWIN_DIRTY=1
    if ((${#lacks[@]})); then
        local d; printf -v d '%s; ' "${lacks[@]}"; row todo "Rounded corners" "${d%; }"
    else
        row ok "Rounded corners" "Klassy, no borders, 10 px on every window"
    fi
}

do_glass() {
    local lacks=()
    backup "$CONF/kwinrc"; backup "$CONF/kwinrulesrc"; backup "$CONF/konsolerc"
    if has_effect better_blur_dx; then
        kwrite kwinrc Plugins blurEnabled false
        kwrite kwinrc Plugins better_blur_dxEnabled true
        kwrite kwinrc Effect-better-blur-dx BlurMatching true
        blur_class org.squidowl.halloy com.chatterino.chatterino chatterino obs com.obsproject.Studio
    else
        lacks+=("see-through but not blurred (no Better Blur DX)"); extra "Better Blur DX"
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
        lacks+=("title bars stay opaque (no Klassy)"); extra Klassy
    fi
    opacity_rule lavaglass-chatterino chatterino "lavaglass: Chatterino at 80% (glass)"
    # OBS by its whole class, under either name: "contains obs" also caught Obsidian
    opacity_rule lavaglass-obs '^(obs|com[.]obsproject[.][Ss]tudio)$' "lavaglass: OBS at 80% (glass)" 3
    if ((${#lacks[@]})); then
        local d; printf -v d '%s; ' "${lacks[@]}"; row todo "Glass windows" "${d%; }"
    else
        row ok "Glass windows" "Konsole, Halloy, Chatterino and OBS at 80% over blur"
    fi
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
        todo "Konsole: pick the colour scheme Ferra Glass" "Settings > Edit Current Profile > Appearance"
    fi

    put "$HERE/themes/halloy/ferra-glass.toml" "$CONF/halloy/themes/ferra-glass.toml"
    local hc=$CONF/halloy/config.toml
    if [[ -f $hc ]]; then
        if ! grep -qE '^theme[[:space:]]*=' "$hc"; then
            backup "$hc"
            sed -i '1i theme = "ferra-glass"' "$(readlink -f "$hc")"
        elif ! grep -qE '^theme[[:space:]]*=[[:space:]]*"ferra-glass"' "$hc"; then
            todo "Halloy: switch the theme" "set  theme = \"ferra-glass\"  in $(tilde "$hc")"
        fi
    fi

    local dir found=0
    for dir in "$HOME/.var/app/com.chatterino.chatterino/data/chatterino" "$DATA/chatterino"; do
        [[ -d $dir ]] || continue
        mkdir -p "$dir/Themes"
        cp "$HERE/themes/chatterino/Ferra.json" "$dir/Themes/Ferra.json"
        found=1
    done
    ((found)) && todo "Chatterino: pick the theme Ferra" "Settings > General > Theme"
    row ok "Ferra themes" "Konsole, Halloy, Chatterino"
}

do_round-tasks() {
    local theme
    theme=$(kread plasmarc Theme name); theme=${theme:-default}
    if [[ ! -e /usr/share/plasma/desktoptheme/$theme && ! -e $DATA/plasma/desktoptheme/$theme/metadata.json ]]; then
        row skip "Round tasks" "Plasma style '$theme' not found"
        return 0
    fi
    if ! run_step "Drawing round task highlights" python3 "$HERE/tools/rounded-tasks-svg.py" 7 4 "$theme"; then
        row fail "Round tasks" "see the error above; the rest went on"
        return 0
    fi
    row ok "Round tasks" "for the Plasma style '$theme'"
    todo "Restart Plasma to see the round task highlights" "systemctl --user restart plasma-plasmashell"
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
    local p n=0 done=0
    while IFS= read -r p; do
        [[ -d $p ]] || continue
        n=$((n + 1))
        if grep -q -- '--glass-tint' "$p/chrome/userChrome.css" 2>/dev/null &&
           ! grep -qF '/* lavaglass:glass begin */' "$p/chrome/userChrome.css"; then
            row skip "Firefox glass" "$(basename "$p") already has its own glass block, left alone"
            continue
        fi
        done=$((done + 1))
        ff_block "$p" glass
        ff_pref "$p" toolkit.legacyUserProfileCustomizations.stylesheets
        if [[ ${1:-} == see-through ]]; then
            ff_block "$p" see-through
            ff_pref "$p" browser.tabs.allow_transparent_browser
        fi
    done < <(ff_profiles)
    if ((n == 0)); then row skip "Firefox glass" "no Firefox profile found"; return 0; fi
    backup "$CONF/kwinrc"
    if has_effect better_blur_dx; then blur_class firefox; else extra "Better Blur DX"; fi
    ((done)) || return 0
    row ok "Firefox glass" "toolbar and tabs, $done profile$( ((done > 1)) && echo s)"
    todo "Restart Firefox" "the tint matches Breeze Dark; for another theme change --glass-tint in userChrome.css"
    if [[ ${1:-} == see-through ]]; then
        row ok "See-through tab" "a new tab page with no background shows the glass"
        todo "See-through has a cost" "pages with no background of their own are now drawn on dark, not white"
    fi
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
        *) if declare -F "do_$a" >/dev/null; then PARTS+=("$a"); else die "unknown part: $a (try --help)"; fi ;;
    esac
done
((${#PARTS[@]})) || PARTS=("${DEFAULT[@]}")

banner installer
for c in kreadconfig6 kwriteconfig6; do
    have "$c" || die "$c not found: this needs KDE Plasma 6."
done

for p in "${PARTS[@]}"; do "do_$p"; done

if ((START)); then
    QDBUS=$(command -v qdbus6 || command -v qdbus-qt6 || command -v qdbus || true)
    if [[ -n $QDBUS ]]; then
        ((KWIN_DIRTY || BLUR_DIRTY)) && "$QDBUS" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
        ((BLUR_DIRTY)) && "$QDBUS" org.kde.KWin /Effects reconfigureEffect better_blur_dx >/dev/null 2>&1 || true
    fi
    ((KWIN_DIRTY)) && todo "Log out and back in once" "so KWin loads the new scripts and effects"
fi

if ((${#EXTRAS[@]})); then
    declare -A WHERE=([Klassy]="klassy-bin https://github.com/paulmcauley/klassy"
        ["KDE Rounded Corners"]="kwin-effect-rounded-corners-git https://github.com/matinlotfali/KDE-Rounded-Corners"
        ["Better Blur DX"]="kwin-effects-better-blur-dx https://github.com/xarblu/kwin-effects-better-blur-dx")
    pkgs=() links=()
    for e in "${EXTRAS[@]}"; do pkgs+=("${WHERE[$e]% *}"); links+=("${WHERE[$e]#* }"); done
    if have pacman; then
        todo "Install what was missing, then run this again" "paru -S ${pkgs[*]}"
    else
        todo "Install what was missing, then run this again" "${links[*]}"
    fi
fi

if ((${#TODO[@]})); then
    printf '\n  %sLeft for you%s\n' "$BOLD" "$RESET"
    n=0
    for t in "${TODO[@]}"; do
        n=$((n + 1))
        printf '  %s%2d%s %s\n' "$CORAL" "$n" "$RESET" "${t%%$'\t'*}"
        [[ -n ${t#*$'\t'} ]] && printf '     %s%s%s\n' "$DIM" "${t#*$'\t'}" "$RESET"
    done
fi

echo
if ((SKIPPED)); then
    printf '  %s%slavaglass is installed, minus the parts marked above.%s\n' "$BOLD" "$YELLOW" "$RESET"
else
    printf '  %s%slavaglass is installed.%s\n' "$BOLD" "$PINK" "$RESET"
fi
[[ -d $BACKUPS ]] && printf '  %sYour config files from before: %s%s\n' "$DIM" "$(tilde "$BACKUPS")" "$RESET"
echo
exit 0
