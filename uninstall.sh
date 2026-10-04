#!/usr/bin/env bash
# Remove what install.sh put in place. Your own settings that it edited (window decoration,
# corner radius, Konsole profile) are left as they are: the copies taken before each edit are
# in ~/.local/share/lavaglass/backups/, which this script keeps.
#
#   ./uninstall.sh              remove everything
#   ./uninstall.sh --no-start   same, without stopping services or reloading KWin
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
CONF=${XDG_CONFIG_HOME:-$HOME/.config}
PREFIX=$DATA/lavaglass
START=1
[[ ${1:-} == --no-start ]] && START=0

if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    BOLD=$'\e[1m' DIM=$'\e[2m' RESET=$'\e[0m' GREEN=$'\e[32m'
    case ${COLORTERM:-} in
        truecolor|24bit) PINK=$'\e[38;2;246;182;201m' CORAL=$'\e[38;2;255;160;122m' ;;
        *) PINK=$'\e[35m' CORAL=$'\e[33m' ;;
    esac
else
    BOLD="" DIM="" RESET="" GREEN="" PINK="" CORAL=""
fi
case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) OK_MARK=✓ DOT=● ;;
    *) OK_MARK=+ DOT='*' ;;
esac
row()   { printf '  %s%s%s %-18s %s%s%s\n' "$GREEN" "$OK_MARK" "$RESET" "$1" "$DIM" "${2:-}" "$RESET"; }
tilde() { printf '%s' "${1/#"$HOME"/\~}"; }

kread() { kreadconfig6 --file "$1" --group "$2" --key "$3"; }
kdel()  { kwriteconfig6 --file "$1" --group "$2" --key "$3" --delete; }

printf '\n  %s%s%s %s%slavaglass%s  %sKDE Plasma 6 uninstaller%s\n\n' "$CORAL" "$DOT" "$RESET" "$BOLD" "$PINK" "$RESET" "$DIM" "$RESET"

for u in glass-dock lamp-audio; do
    ((START)) && systemctl --user disable --now "$u.service" >/dev/null 2>&1 || true
    rm -f "$CONF/systemd/user/$u.service"
done
((START)) && systemctl --user daemon-reload
row "Services" "glass-dock and lamp-audio removed"

rm -rf "$PREFIX/glass-dock" "$PREFIX/lamp-audio"
rm -rf "$DATA/plasma/wallpapers/org.cyb.lavalamp"
row "Lava Lamp" "wallpaper removed"
for d in "$HERE"/kwin-scripts/*/; do
    id=$(basename "$d")
    rm -rf "$DATA/kwin/scripts/$id"
    kdel kwinrc Plugins "${id}Enabled"
done
row "KWin scripts" "Gap Maximize and Panel Edge Reveal removed"

# glass: stock blur back, our classes and rules out
if [[ $(kread kwinrc Plugins better_blur_dxEnabled) == true ]]; then
    kdel kwinrc Plugins blurEnabled
    kdel kwinrc Plugins better_blur_dxEnabled
fi
rules=$(kread kwinrulesrc General rules)
for id in lavaglass-chatterino lavaglass-obs; do
    [[ ,$rules, == *,$id,* ]] || continue
    for k in Description wmclass wmclassmatch types opacityactive opacityactiverule opacityinactive opacityinactiverule; do
        kdel kwinrulesrc "$id" "$k"
    done
    rules=$(sed -E "s/(^|,)$id(,|$)/\1/; s/,$//" <<<"$rules")
    kwriteconfig6 --file kwinrulesrc --group General --key rules "$rules"
    kwriteconfig6 --file kwinrulesrc --group General --key count "$(awk -F, '{ print NF }' <<<"$rules")"
done
row "Glass windows" "opacity rules out, KWin's own blur back"

rm -f "$DATA/konsole/Ferra-Glass.colorscheme" "$DATA/konsole/Lavaglass.profile"
[[ $(kread konsolerc 'Desktop Entry' DefaultProfile) == Lavaglass.profile ]] && kdel konsolerc 'Desktop Entry' DefaultProfile
rm -f "$CONF/halloy/themes/ferra-glass.toml"
rm -f "$HOME/.var/app/com.chatterino.chatterino/data/chatterino/Themes/Ferra.json" "$DATA/chatterino/Themes/Ferra.json"
row "Ferra themes" "Konsole, Halloy and Chatterino files removed"

# Firefox: take our marked blocks out of userChrome.css
for css in "$HOME"/.mozilla/firefox/*/chrome/userChrome.css "$CONF"/mozilla/firefox/*/chrome/userChrome.css \
           "$HOME"/.var/app/org.mozilla.firefox/.mozilla/firefox/*/chrome/userChrome.css; do
    [[ -f $css ]] && grep -qF '/* lavaglass:' "$css" || continue
    tmp=$(mktemp)
    awk '/^\/\* lavaglass:[a-z-]+ begin \*\/$/ { skip = 1 } !skip { print } /^\/\* lavaglass:[a-z-]+ end \*\/$/ { skip = 0 }' "$css" >"$tmp"
    cat "$tmp" >"$css"; rm -f "$tmp"
    row "Firefox glass" "taken out of $(basename "$(dirname "$(dirname "$css")")")"
done

if ((START)); then
    QDBUS=$(command -v qdbus6 || command -v qdbus-qt6 || command -v qdbus || true)
    [[ -n $QDBUS ]] && "$QDBUS" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
fi

printf '\n  %sLeft as they are%s\n' "$BOLD" "$RESET"
printf '  %s- %s%s\n' "$DIM" "your window decoration, corner radius and the Klassy Lavaglass preset" "$RESET"
printf '  %s- %s%s\n' "$DIM" "Glass Dock's settings in $(tilde "$CONF/lavaglass")" "$RESET"
printf '  %s- %s%s\n' "$DIM" "Firefox's user.js prefs" "$RESET"
printf '\n  %s%slavaglass is removed.%s\n' "$BOLD" "$PINK" "$RESET"
[[ -d $PREFIX/backups ]] && printf '  %sYour config files from before each install: %s%s\n' "$DIM" "$(tilde "$PREFIX/backups")" "$RESET"
echo
exit 0
