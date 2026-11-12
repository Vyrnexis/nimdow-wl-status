# nimdow-wl-status design

An optional status feeder for nimdow-wl. nimdow-wl never depends on it; any script
calling `nimdow-wl --status` works too. Goals: tiny steady-state cost, small code,
user scripts as first-class citizens.

## Rule for built-in modules

A module is built in only if it reads kernel files with **no subprocess** (the one exception:
`net` asks `nmcli` for the SSID, asynchronously, when the link changes). Anything else that runs a
program is a user script (`command` or `stream`).

| Kind | Modules |
|---|---|
| built-in | `datetime`, `memory`, `cpu`, `battery`, `net` |
| generic | `command` (run every `interval`), `stream` (long-running, one line = one update) |

Shipped scripts (`scripts/`): `volume.sh` (stream, pactl subscribe), `updates.sh`
(command, checkupdates + pacman lock), `weather.sh` (command, curl wttr.in).

With no command/stream segments (and `show_ssid = false`), the process starts **zero** subprocesses
after start-up.

## File layout

```
src/nimdow_wl_status.nim        entry: args, wiring, main loop
src/nimdow_wl_status/
  loop.nim      selector, one BOOTTIME timerfd for all deadlines, signalfd, Seg
  child.nim     fork/exec (sh -c), PR_SET_PDEATHSIG, line reader, timeout, pidfd reaping
  ipc.nim       nimdow-wl socket transport (+ inotify on its dir) + --stdout
  procfs.nim    pread of a /proc file through one long-lived fd
  render.nim    styles (sides glyphs), colour -> SGR, segment text
  config.nim    TOML -> Config, validation, --check-config
  reload.nim    inotify on the config dir + SIGHUP -> validate -> re-exec
  modules/
    datetime.nim memory.nim cpu.nim battery.nim net.nim
    command.nim   (command + stream)
config.default.toml   built-in default (staticRead)
scripts/*.sh          volume.sh, updates.sh, weather.sh
tests/tmain.nim       unit tests (`nimble test`)
```

## Output

Per shown segment:
`SGR(fg=bg colour) left-side RESET SGR(bg) [SGR(fg=text_colour)] icon body \x1F RESET SGR(fg=bg) right-side RESET`
(sides with an empty right glyph omit the trailing part). `\x1F` (the WM's region separator, see
nimdow-wl's `bar/statusparse.nim`) ends each click region; region N = segment N.

A hidden segment (empty body, no `show_always`) is just its `\x1F`: an empty region, so the
numbering stays equal to the segment order whichever segments are hidden, including trailing
or all of them. `text_colour` (per segment, default `[bar] text_colour`) emits
`SGR(fg=text_colour)` after the background SGR; unset, nimdow-wl's `barForegroundColor` applies.

Sanitising: the WM treats only `ESC [ ... m` as colour and `\x1F` as a separator, so text from
outside (script lines, SSIDs) loses every byte < 0x20 and 0x7f and is cut at 256 bytes on a
character boundary (`render.sanitize`, applied in `setBody`). Only the escape sequences this
program generates itself reach the bar.

## Script protocol (command + stream)

Each stdout line is `text` or `text<TAB>colour` (colour = `#rrggbb` or a `[colours]`
name; overrides the segment colour until the next line). `command`: the first line of
output is used; non-zero exit -> `N/A` (or empty with `hide_on_error = true`).
`stream`: every line replaces the body; if the process exits it is restarted with
backoff (0.5s doubling to 30s, reset after 10s alive). Commands run via `sh -c` with
the config file's directory as cwd. Children die with nimdow-wl-status (PR_SET_PDEATHSIG).
A child is finished when its pidfd fires (not at stdout EOF): it is reaped at once, what is
left in the pipe is read, and a daemonised helper holding the pipe cannot keep a zombie or an fd.
PDEATHSIG only reaches the shell, so each child gets its own process group (killed as a
group on exit/reload) and stream children get a stdin pipe that hits EOF when the feeder
dies: a script with long-lived helpers can guard with
`exec 3<&0; ( cat <&3 >/dev/null; kill -- -$$ ) &` (see scripts/volume.sh).

## Config

First match wins: `--config <path>`, `$XDG_CONFIG_HOME/nimdow-wl/status.toml`, the first
`nimdow-wl/status.toml` in `$XDG_CONFIG_DIRS` (default `/etc/xdg`; the system config of the
desktop package), the built-in default. Without `--config` and without a user file the system
config is copied to the user path on first run (never overwriting; if the copy fails it is used
in place). A missing or empty file means the built-in default.

```toml
[bar]
style = "angle_b"              # arrow arrow_l arrow_r circle circle_l circle_r angle_a angle_b none
text_colour = "#ebdbb2"        # optional

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
- `memory`: `method = "htop" | "available"`, `decimals = 2`. /proc/meminfo is scanned once for
  the keys needed.
- `cpu`: `decimals = 0` (usage % from /proc/stat deltas of the first 8 fields; the baseline is
  taken at start).
- `battery`: `icons` (6: charging, empty, low, half, 3qtr, full), `name`. Interval 30 s.
  The first match by sorted name is used; with none the segment is hidden and not re-armed
  (a signal reruns it). A read error drops the cached dir, so the next run looks again.
- `net`: `icon_wifi`, `icon_ethernet`, `icon_disconnected`, `show_ssid = true`
  (SSID via async `nmcli ... wifi list --rescan no`, never a scan, when the link changes or
  every 2 min; an answer for a link that has changed meanwhile is dropped).
- `command`: `command`, `timeout = 10`, `hide_on_error = false`.
- `stream`: `command`.

Validation: unknown module / bad colour / bad style / wrong type = error (segment index
+ key); unknown key = warning. Invalid at start-up -> errors on stderr, built-in default
runs. Invalid on reload -> keep running; a deleted or emptied file also keeps the running
config. `--check-config` exits 0/1. An unknown argument prints the usage and exits 2.

## Runtime

- One `std/selectors` loop, no tick: every deadline is a `CLOCK_BOOTTIME` nanosecond value and
  the earliest one is loaded into a single timerfd. BOOTTIME counts suspend, so after a resume
  whatever is overdue (the clock first) fires at once instead of up to a minute late. A second
  timerfd (`CLOCK_REALTIME`, `TFD_TIMER_CANCEL_ON_SET`) reports a wall-clock step; the aligned
  (datetime) segments then re-arm. A timezone change does not set the clock: it shows at the
  next tick.
- Signals via `signalfd`: SIGUSR1 rerun all, SIGRTMIN+N rerun segment N, SIGHUP reload,
  SIGTERM/SIGINT exit (kill children). SIGPIPE is blocked in the feeder (a dead socket gives
  EPIPE) and restored to default in children.
- A segment's timer re-arms through `runSeg` even if its refresh raises (the body shows N/A).
  `setBody` returns at once when body, icon and colours are unchanged.
- Reload re-execs the real binary path (not /proc/self/exe, so the process name stays
  `nimdow-wl-statu`); every fd > 2 is CLOEXEC. The config dir is watched with inotify (its
  parent until it exists).
- IPC: `nimdow-ipc status <text>` to the newest live socket in the WM's socket dir,
  `$XDG_RUNTIME_DIR/nimdow-wl/ipc-socket.<pid>`, or `/tmp/nimdow-wl-<uid>/` when
  `XDG_RUNTIME_DIR` is unset (as the WM does). Connect and send carry a few ms
  `SO_SNDTIMEO`, so a stuck WM cannot stall the loop. Text is sent only on change. An inotify
  `IN_CREATE` watch on the socket dir (its parent until the dir exists) notices a WM
  (re)start; the current text is then resent, changed or not. A failed send forgets what was
  delivered and waits for the next new socket (or the next change). No polling timer.
  `--stdout` prints lines instead.
