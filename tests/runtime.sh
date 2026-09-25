#!/bin/bash
set -eu
[[ -f /etc/slackware-version ]] || exit 1
required=(foot niri scroll Xwayland xkbcomp xwayland-satellite pipewire
    pipewire-pulse wireplumber waybar dunst wl-copy wl-paste cliphist slurp grim
    micro yazi swayimg mpv aria2c htop walker elephant fd qalc owenctl)
optional=(ghostty firefox palemoon tele telegramtui)
failed=0
for name in "${required[@]}"; do
    if ! command -v "$name" >/dev/null; then
        printf '%s: missing executable\n' "$name"
        failed=1
    fi
done
for name in "${required[@]}" "${optional[@]}"; do
    binary=$(command -v "$name") || continue
    result=$(ldd "$binary" 2>&1) || :
    if [[ $result == *'not found'* ]]; then
        printf '%s:\n%s\n' "$name" "$result"
        failed=1
    fi
done
(( failed == 0 )) || exit 1
echo 'PASS installed desktop entry points and their shared libraries'
echo 'Application interaction, drivers and optional plug-ins require separate tests.'
