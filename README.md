# nimdow-wl-status

An optional status feeder for [nimdow-wl](https://github.com/Vyrnexis/nimdow). nimdow-wl never
depends on it; any script that calls `nimdow-wl --status` works too. This one is event-driven
(no fixed tick: it sleeps until the next deadline) and sends the bar straight to nimdow-wl's
IPC socket (`$XDG_RUNTIME_DIR/nimdow-wl/ipc-socket.<pid>`, newest live one), only when the text
changes.

Built-in modules read kernel files with no subprocess: `datetime`, `memory`, `cpu`, `battery`,
`net`. Anything that runs a program is a script: `command` (run every `interval`) or `stream`
(long-running). With no script segments it starts no subprocesses after start-up.

## Build

Needs Nim >= 2.0 and parsetoml (`nimble install parsetoml`).

    nimble build -d:release     # bin: nimdow-wl-status
    ./rebuild.sh                # kill the running instance, rebuild, start it

## Usage

    nimdow-wl-status                       # send to nimdow-wl
    nimdow-wl-status --stdout              # print each new status line instead
    nimdow-wl-status --config <path>       # another config file
    nimdow-wl-status --check-config        # validate, print problems, exit 0 / 1

## Config

Read from `--config`, else `$XDG_CONFIG_HOME/nimdow-wl/status.toml`, else the built-in
default. Copy [`config.default.toml`](config.default.toml): every key is documented there.
Saving the file reloads it; an invalid file is reported on stderr and the running
configuration is kept. At start-up an invalid file falls back to the built-in default.

Segment order = bar order = click region N = signal `SIGRTMIN+N`. Colours are `#rrggbb` or a
name from `[colours]`; `colour_files` loads palettes from `themes/` (gruvbox, nord, dracula,
catppuccin, rosepine) first. `text_colour` (per segment or in `[bar]`) sets the foreground;
unset, nimdow-wl's `barForegroundColor` applies.

## Script protocol

`command` and `stream` run through `sh -c` in the config file's directory. Each stdout line is
`text` or `text<TAB>colour` (`#rrggbb` or a `[colours]` name; it overrides the segment colour
until the next line).

- `command`: the first output line is the body. Non-zero exit or timeout shows `N/A`
  (empty with `hide_on_error = true`).
- `stream`: every line replaces the body. If the process exits it is restarted with backoff
  (0.5s doubling to 30s, reset after 10s alive).
- Children are killed with nimdow-wl-status (`PR_SET_PDEATHSIG`) and by process group on
  reload or exit. A stream's stdin is a pipe that closes when nimdow-wl-status dies; see
  `scripts/volume.sh` for taking helper processes down with it.

## Signals

| Signal | Effect |
| --- | --- |
| `SIGUSR1` | rerun all segments |
| `SIGRTMIN+N` | rerun segment N, e.g. `pkill -RTMIN+3 nimdow-wl-stat` |
| `SIGHUP` | reload the config |
| `SIGTERM` / `SIGINT` | exit |

Process names are cut to 15 characters (`nimdow-wl-statu`), so use `pkill -x nimdow-wl-statu` or
the pattern `nimdow-wl-stat`. Avoid `pkill -f`: it also matches shells whose command line
contains the name.

## Shipped scripts

- `scripts/volume.sh` - stream; default sink volume/mute via `pactl subscribe`.
- `scripts/updates.sh` - command; pending pacman updates (`checkupdates`), `UPDATING` in red while
  pacman holds its lock. Rerun with a signal or a short interval; it does not watch the lock.
- `scripts/weather.sh [location]` - command; `curl` of wttr.in (default Perth).

License: GPL-3.0-or-later.
