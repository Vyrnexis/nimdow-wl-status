#!/bin/sh
# command: pending pacman updates (needs checkupdates from pacman-contrib; without it nothing
# is printed and the segment stays hidden).
# While pacman holds its lock, prints UPDATING in red (colour after a TAB).
# Usage: updates.sh [busy_colour]  ("#rrggbb" or a [colours] name, default #fb4934)
command -v checkupdates >/dev/null 2>&1 || exit 0
if [ -e /var/lib/pacman/db.lck ]; then
    printf 'UPDATING\t%s\n' "${1:-#fb4934}"
    exit 0
fi
out=$(checkupdates 2>/dev/null) && rc=0 || rc=$?
case $rc in
    0) printf 'Updates: %s\n' "$(printf '%s\n' "$out" | grep -c .)" ;;
    2) echo 0 ;;
    *) echo "N/A"; exit 1 ;;
esac
