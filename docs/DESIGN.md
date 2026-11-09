# nimdow-wl-status design

An optional status feeder for nimdow-wl. nimdow-wl never depends on it; any script
calling `nimdow-wl --status` works too. Goals: tiny steady-state cost, small code,
user scripts as first-class citizens.

## Rule for built-in modules

A module is built in only if it reads kernel files with **no subprocess**.
Anything that runs a program is a user script (`command` or `stream`).

| Kind | Modules |
|---|---|
| built-in | `datetime`, `memory`, `cpu`, `battery`, `net` |
| generic | `command` (run every `interval`), `stream` (long-running, one line = one update) |

Shipped scripts (`scripts/`): `volume.sh` (stream, pactl subscribe), `updates.sh`
(command, checkupdates + pacman lock), `weather.sh` (command, curl wttr.in).

With no command/stream segments, the process starts **zero** subprocesses after start-up.

## File layout

```
src/nimdow_wl_status.nim        entry: args, wiring, main loop
src/nimdow_wl_status/
  loop.nim      selector, segment deadlines, signalfd
  child.nim     fork/exec (sh -c), PR_SET_PDEATHSIG, line reader, timeout
  ipc.nim       nimdow-wl socket transport + --stdout
  render.nim    styles (sides glyphs), colour -> SGR, segment text
  config.nim    TOML -> Config, validation, --check-config
  reload.nim    inotify on config dir + SIGHUP -> validate -> re-exec
  modules/
    datetime.nim memory.nim cpu.nim battery.nim net.nim
    command.nim   (command + stream)
config.default.toml   built-in default (staticRead)
themes/*.toml         [colours] palettes (gruvbox, nord, dracula, catppuccin, rosepine)
scripts/*.sh          volume.sh, updates.sh, weather.sh
```

## Output (unchanged contract)

Per segment, exactly as before (byte-identical for the same body/icon/colour):
`SGR(fg=bg colour) left-side RESET SGR(bg) icon body \x1F RESET SGR(fg=bg) right-side RESET`
(sides with an empty right glyph omit the trailing part, as today). `\x1F` ends each
click region; region N = segment N. Empty body hides the segment unless `show_always`.

New: `text_colour` (per segment, default from `[bar] text_colour`, default unset).
When set, `SGR(fg=text_colour)` is emitted after the background SGR; when unset the
output is byte-identical to today and nimdow-wl's `barForegroundColor` applies.

## Script protocol (command + stream)

Each stdout line is `text` or `text<TAB>colour` (colour = `#rrggbb` or a `[colours]`
name; overrides the segment colour until the next line). `command`: the first line of
output is used; non-zero exit -> `N/A` (or empty with `hide_on_error = true`).
`stream`: every line replaces the body; if the process exits it is restarted with
backoff (0.5s doubling to 30s, reset after 10s alive). Commands run via `sh -c` with
the config file's directory as cwd. Children die with nimdow-wl-status (PR_SET_PDEATHSIG).
PDEATHSIG only reaches the shell, so each child gets its own process group (killed as a
group on exit/reload) and stream children get a stdin pipe that hits EOF when the feeder
dies: a script with long-lived helpers can guard with
`exec 3<&0; ( cat <&3 >/dev/null; kill -- -$$ ) &` (see scripts/volume.sh).

## Config

`~/.config/nimdow-wl/status.toml` (`$XDG_CONFIG_HOME`), `--config <path>`, else the
built-in default.

```toml
[bar]
style = "angle_b"              # arrow arrow_l arrow_r circle circle_l circle_r angle_a angle_b none
text_colour = "#ebdbb2"        # optional
colour_files = ["themes/gruvbox.toml"]   # optional, relative to config dir; their [colours] load first

[colours]                      # name = "#rrggbb" | other name
accent = "#689d6a"

[[segment]]                    # order = bar order = click region N = SIGRTMIN+N
module = "memory"
icon = " "
colour = "accent"              # alias: color
text_colour = "..."            # optional
style = "..."                  # optional override
interval = 2                   # seconds, fractions ok; 0 = only on signal
show_always = false
```

Module options:
- `datetime`: `format` (Nim times; minute-aligned, second-aligned if it contains `s`).
- `memory`: `method = "htop" | "available"`, `decimals = 2`.
- `cpu`: `decimals = 0` (usage % from /proc/stat deltas).
- `battery`: `icons` (6: charging, empty, low, half, 3qtr, full), `name`.
- `net`: `icon_wifi`, `icon_ethernet`, `icon_disconnected`, `show_ssid = true`
  (SSID via async `nmcli` only when the link changes or every 2 min).
- `command`: `command`, `timeout = 10`, `hide_on_error = false`.
- `stream`: `command`.

Validation: unknown module / bad colour / bad style / wrong type = error (segment index
+ key); unknown key = warning. Invalid at start-up -> errors on stderr, built-in default
runs. Invalid on reload -> keep running. `--check-config` exits 0/1.

## Runtime

- One `std/selectors` loop, no tick: sleep until the earliest segment deadline.
- Signals via `signalfd`: SIGUSR1 rerun all, SIGRTMIN+N rerun segment N, SIGHUP reload,
  SIGTERM/SIGINT exit (kill children). SIGPIPE is left at default for children.
- Reload re-execs the real binary path (not /proc/self/exe, so the process name stays
  `nimdow-wl-statu`); every fd > 2 is CLOEXEC.
- IPC: `nimdow-ipc status <text>` to the newest live
  `$XDG_RUNTIME_DIR/nimdow-wl/ipc-socket.<pid>`; send only on change; resend if the
  socket changed; retry every 2s while nimdow-wl is down. `--stdout` prints lines instead.

## Removed

pulse, archupdates, weather (-> scripts), reconnect checker, alsa, bluetooth, keyboard,
sensibo, compiled palettes (-> themes/), osproc runners, setpriv dependency.
