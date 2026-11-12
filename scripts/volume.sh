#!/bin/bash
# stream: "<icon> <volume>" at start and whenever the default sink or server changes.
# Usage: volume.sh [volume_icon] [mute_icon]
# Needs pactl (without it the script idles and the segment stays hidden).
# stdin is a pipe that closes when nimdow-wl-status exits; the guard below then takes
# `pactl subscribe` down too (the parent-death signal only reaches this shell). The group
# is $$'s only when nimdow-wl-status started us; run by hand, the kill finds nothing.
export LC_ALL=C                       # pactl's output is parsed in English
command -v pactl >/dev/null 2>&1 || exec sleep infinity
on=${1:-" "}
muted=${2:-"󰖁 "}
tab=$'\t'
sink=                                 # default sink name, looked up again after a server event

show() {
    # One `pactl list sinks` gives volume and mute of the default sink; parsed without forks.
    local l cur= vol= mute=
    [ -n "$sink" ] || sink=$(pactl get-default-sink 2>/dev/null)
    while IFS= read -r l; do
        case $l in
            "${tab}Name: "*) cur=${l#*: } ;;
            "${tab}Mute: "*) [ "$cur" = "$sink" ] && mute=${l#*: } ;;
            "${tab}Volume: "*)
                if [ "$cur" = "$sink" ] && [ -z "$vol" ]; then
                    vol=${l#*/ }; vol=${vol%%\%*}; vol=${vol##* }
                fi ;;
        esac
    done < <(pactl list sinks 2>/dev/null)
    if [ -z "$vol" ]; then echo; return; fi        # no sink: hide the segment
    if [ "$vol" = 0 ] || [ "$mute" = yes ]; then printf '%s%s%%\n' "$muted" "$vol"
    else printf '%s%s%%\n' "$on" "$vol"; fi
}

show
exec 3<&0    # a background job gets /dev/null as stdin; keep the real one on fd 3
( cat <&3 >/dev/null; kill -- "-$$" ) >/dev/null 2>&1 &
pactl subscribe | while IFS= read -r line; do
    case $line in
        *" on sink #"*|*" on server"*) ;;
        *) continue ;;
    esac
    [[ $line == *" on server"* ]] && sink=
    # Coalesce a burst (one volume step is several events): wait for 20 ms of quiet.
    while IFS= read -r -t 0.02 line; do [[ $line == *" on server"* ]] && sink=; done
    show
done
