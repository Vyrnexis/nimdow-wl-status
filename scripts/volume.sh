#!/bin/sh
# stream: "<icon> <volume>" at start and whenever the default sink or server changes.
# Usage: volume.sh [volume_icon] [mute_icon]
# stdin is a pipe that closes when nimdow-wl-status exits; the guard below then takes
# `pactl subscribe` down too (the parent-death signal only reaches this shell). The group
# is $$'s only when nimdow-wl-status started us; run by hand, the kill finds nothing.
on=${1:-" "}
muted=${2:-"󰖁 "}

show() {
    vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | awk -F' / ' 'NR == 1 { gsub(/ /, "", $2); print $2 }')
    [ -n "$vol" ] || { echo "N/A"; return; }
    if [ "$vol" = 0% ] || pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -q yes; then
        printf '%s%s\n' "$muted" "$vol"
    else
        printf '%s%s\n' "$on" "$vol"
    fi
}

show
exec 3<&0    # a background job gets /dev/null as stdin; keep the real one on fd 3
( cat <&3 >/dev/null; kill -- "-$$" ) >/dev/null 2>&1 &
pactl subscribe | while IFS= read -r line; do
    case $line in
        *" on sink #"*|*" on server"*) show ;;
    esac
done
