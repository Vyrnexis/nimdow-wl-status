#!/bin/sh
# command: temperature from wttr.in. Usage: weather.sh [location]  (default: wttr.in geolocates by IP)
curl -sf --max-time 10 "https://wttr.in/${1:-}?format=%t"
