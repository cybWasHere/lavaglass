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

kread() { kreadconfig6 --file "$1" --group "$2" --key "$3"; }
kdel()  { kwriteconfig6 --file "$1" --group "$2" --key "$3" --delete; }

for u in glass-dock lamp-audio; do
    ((START)) && systemctl --user disable --now "$u.service" >/dev/null 2>&1 || true
    rm -f "$CONF/systemd/user/$u.service"
done
((START)) && systemctl --user daemon-reload

rm -rf "$PREFIX/glass-dock" "$PREFIX/lamp-audio"
rm -rf "$DATA/plasma/wallpapers/org.cyb.lavalamp"
for d in "$HERE"/kwin-scripts/*/; do
    id=$(basename "$d")
    rm -rf "$DATA/kwin/scripts/$id"
    kdel kwinrc Plugins "${id}Enabled"
done

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

rm -f "$DATA/konsole/Ferra-Glass.colorscheme" "$DATA/konsole/Lavaglass.profile"
[[ $(kread konsolerc 'Desktop Entry' DefaultProfile) == Lavaglass.profile ]] && kdel konsolerc 'Desktop Entry' DefaultProfile
rm -f "$CONF/halloy/themes/ferra-glass.toml"
rm -f "$HOME/.var/app/com.chatterino.chatterino/data/chatterino/Themes/Ferra.json" "$DATA/chatterino/Themes/Ferra.json"

# Firefox: take our marked blocks out of userChrome.css
for css in "$HOME"/.mozilla/firefox/*/chrome/userChrome.css "$CONF"/mozilla/firefox/*/chrome/userChrome.css \
           "$HOME"/.var/app/org.mozilla.firefox/.mozilla/firefox/*/chrome/userChrome.css; do
    [[ -f $css ]] && grep -qF '/* lavaglass:' "$css" || continue
    tmp=$(mktemp)
    awk '/^\/\* lavaglass:[a-z-]+ begin \*\/$/ { skip = 1 } !skip { print } /^\/\* lavaglass:[a-z-]+ end \*\/$/ { skip = 0 }' "$css" >"$tmp"
    cat "$tmp" >"$css"; rm -f "$tmp"
done

if ((START)); then
    QDBUS=$(command -v qdbus6 || command -v qdbus-qt6 || command -v qdbus || true)
    [[ -n $QDBUS ]] && "$QDBUS" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
fi

echo "Removed. Left in place: the Klassy 'Lavaglass' preset and exceptions, your window decoration"
echo "and corner settings, Glass Dock's settings in $CONF/lavaglass, and Firefox's user.js prefs."
[[ -d $PREFIX/backups ]] && echo "Config copies from before each install: $PREFIX/backups"
exit 0
