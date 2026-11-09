#!/bin/sh
# command: temperature from wttr.in. Usage: weather.sh [location]  (default Perth)
curl -sf --max-time 10 "https://wttr.in/${1:-Perth}?format=%t"
