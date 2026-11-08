# nimdow-wl-status
An optional, event-driven status feeder for nimdow-wl. nimdow-wl works fine without it — any script that calls `nimdow-wl --status` will do; this is just a faster, batteries-included alternative.

## Design

nimdow-wl-status is an event-driven status feeder for [nimdow-wl](https://github.com/Vyrnexis/nimdow).
There is no fixed tick: the main loop `select`s on one selector and sleeps until the
earliest segment/timer is due. Whenever a segment's text changes the bar string is rebuilt
once and sent straight to nimdow-wl's IPC socket
(`$XDG_RUNTIME_DIR/nimdow-wl/ipc-socket.<pid>`, newest live one) - no `nimdow-wl --status`
process is spawned.

- Slow work (`checkupdates`, `curl` for weather, `nmcli`, `pactl`) runs as non-blocking
  child processes; the volume segment follows `pactl subscribe`.
- Pacman's `db.lck` is watched with inotify: "UPDATING" is shown while it exists and
  updates are re-checked when it goes away.
- Network state is read from `/sys/class/net` and `/proc/net/route` (no forks).
- The date/time segment wakes on the wall-clock minute.

Pure Nim plus [parsetoml](https://github.com/NimParsers/parsetoml) (a nimble dependency). Needs `pactl`, `nmcli`, `curl` and `checkupdates`
at runtime for the respective segments.

## Usage

    nimdow-wl-status            # send to nimdow-wl
    nimdow-wl-status --stdout   # print each new status as one line (dwl/somebar-style piping, testing)
    nimdow-wl-status --config ~/my-status.toml   # use another config file
    nimdow-wl-status --check-config              # validate the config, print problems, exit 0/1

## Signals

| Signal | Effect |
| --- | --- |
| `SIGUSR1` | refresh all segments |
| `SIGRTMIN+N` | refresh segment N (1-based, in bar order), e.g. `pkill -RTMIN+4 nimdow-wl-stat` after a volume keybind |
| `SIGHUP` | reload the config file |
| `SIGTERM` / `SIGINT` | clean exit |

The kernel truncates process names to 15 characters (`nimdow-wl-statu`), so `pkill nimdow-wl-status` matches nothing. Use a shorter pattern such as `nimdow-wl-stat`; avoid `pkill -f`, which also hits any shell whose command line contains the name (e.g. a keybind's `sh -c`).

## Configuration

Modules, their order, icons, colours and options are set in a TOML file, so nothing needs
recompiling. The file is read from, in order:

1. `--config <path>`
2. `$XDG_CONFIG_HOME/nimdow-wl/status.toml` (usually `~/.config/nimdow-wl/status.toml`)
3. the built-in default, which is [`config.default.toml`](config.default.toml) embedded at
   compile time. It reproduces the stock bar; copy it as a starting point. Every key is
   documented in it.

The order of the `[[segment]]` tables is the bar order, the nimdow-wl click region number
(1-based) and the signal number (`SIGRTMIN+N`) of each segment.

- `[bar] style` is the default shape: `arrow`, `arrow_l`, `arrow_r`, `circle`, `circle_l`,
  `circle_r`, `angle_a`, `angle_b`, `none`. A segment can override it with `style`.
- Colours (`colour`, alias `color`) are `"#rrggbb"`, `"<palette>.<name>"` (`gruvbox`, `nord`,
  `dracula`, `catppuccin`, `rosepine`, case-insensitive, e.g. `"gruvbox.aqua"`) or a name from `[colours]`.
- Common segment keys: `module`, `icon`, `colour`, `style`, `interval` (seconds, `0` = event
  driven only), `show_always`.
- Modules and their options: `archupdates` (`colour_busy`, `updating_text`, `timeout`),
  `weather` (`location`, `format`, `retry`), `memory` (`method` = `htop`|`available`, `decimals`),
  `pulse` (`icon_volume`, `icon_mute`), `battery` (`icons`, `name`), `wifi` (`icon_wifi`,
  `icon_ethernet`, `icon_disconnected`, `show_ssid`), `datetime` (`format`, Nim `times` format;
  aligned to the minute, or to the second if the format contains seconds) and `command`
  (`command`, `timeout`, `hide_on_error`). `archupdates`, `pulse` and `wifi` can be used once;
  `command`, `datetime`, `memory`, `battery` and `weather` any number of times.

Example, with a custom script segment:

```toml
[bar]
style = "arrow"

[colours]
accent = "#689d6a"

[[segment]]
module = "command"
icon = " "
colour = "accent"
command = "uptime -p | sed 's/^up //'"
interval = 30

[[segment]]
module = "memory"
colour = "nord.nord10"
method = "available"

[[segment]]
module = "datetime"
colour = "#d79921"
format = "ddd d MMM HH:mm:ss "
```

A `command` segment runs `sh -c`, asynchronously, and shows the first line of stdout. A
non-zero exit shows `N/A` (or nothing with `hide_on_error = true`).

Problems (unknown module, bad colour or style, wrong value type) are reported on stderr with
the segment number and key; unknown keys give a warning. If the config is invalid at start-up
the built-in default is used.

### Live reload

The config's directory is watched with inotify (in-place writes and editors that save via
rename both work, bursts are debounced by 200 ms) and `SIGHUP` also triggers a reload. The new
file is validated first: if it is invalid the error is logged and the running bar is left
alone; if it is valid the child processes are stopped and the program re-executes itself with
the same arguments. If the config directory does not exist yet, create it and send `SIGHUP`.
