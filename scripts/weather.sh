#!/bin/sh
# command: temperature from wttr.in. Usage: weather.sh [location]  (default: wttr.in geolocates by IP)
# Needs curl (without it nothing is printed and the segment stays hidden).
command -v curl >/dev/null 2>&1 || exit 0
loc=$(printf %s "${1:-}" | od -An -v -tx1 | tr -d ' \n' | sed 's/../%&/g')   # every byte as %XX
curl -sf --max-time 10 "https://wttr.in/$loc?format=%t"
