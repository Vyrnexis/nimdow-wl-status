# nimdow-wl-status

A small, fast status bar feeder for [nimdow-wl](https://github.com/Vyrnexis/nimdow).

It fills the right-hand side of the nimdow-wl bar with things like memory, battery, network,
date and time, and the output of your own scripts. Everything is set in one TOML file, and
changes show up the moment you save it. You never need to recompile.

> **This is optional.** nimdow-wl works fine without it. Any script that runs
> `nimdow-wl --status "text"` can drive the bar. nimdow-wl-status is just a faster,
> ready-made alternative.

**Why use it instead of a shell loop?**

- **Light:** it sleeps until something actually needs updating. There is no constant polling loop.
- **No extra processes:** the built-in modules read straight from the kernel, so nothing is started every few seconds.
- **Direct:** it talks to nimdow-wl's socket itself, only sends when the text changes, and resends when nimdow-wl restarts.
- **Hard to break:** a typo in your config never takes the bar down.

---

## Contents

1. [Install](#install)
2. [Start it with nimdow-wl](#start-it-with-nimdow-wl)
3. [Your first config](#your-first-config)
4. [How the config works](#how-the-config-works)
5. [Built-in modules](#built-in-modules)
6. [Your own scripts](#your-own-scripts)
7. [Shipped scripts](#shipped-scripts)
8. [Clicking on the bar](#clicking-on-the-bar)
9. [Refreshing a segment from a keybind](#refreshing-a-segment-from-a-keybind)
10. [Troubleshooting](#troubleshooting)

---

## Install

You need [Nim](https://nim-lang.org) 2.0 or newer and the `parsetoml` package. nimdow-wl
already uses `parsetoml`, so you probably have it.

```sh
git clone https://github.com/Vyrnexis/nimdow-wl-status.git
cd nimdow-wl-status
nimble install parsetoml          # skip if already installed
nimble build -d:release           # produces ./nimdow-wl-status
```

Put the binary somewhere on your `PATH`, for example `~/.local/bin/`.

On Arch, install the AUR package `nimdow-wl-status-git` instead; it puts the default config and the
scripts in `/usr/share/nimdow-wl-status/`.

Optional tools, only needed by the features that use them:

| Tool | Used by |
|---|---|
| `nmcli` (NetworkManager) | the wifi name in the `net` module |
| `pactl` | `scripts/volume.sh` |
| `checkupdates` (pacman-contrib) | `scripts/updates.sh` |
| `curl` | `scripts/weather.sh` |

## Start it with nimdow-wl

Add it to `autostart` in `~/.config/nimdow-wl/config.toml`:

```toml
[autostart]
exec = [
  "nimdow-wl-status",
]
```

Log out and back in, or just run `nimdow-wl-status &` from a terminal inside nimdow-wl.

## Your first config

nimdow-wl-status looks for its config in this order:

1. `--config <file>`, if given
2. `${XDG_CONFIG_HOME:-~/.config}/nimdow-wl/status.toml`
3. the first `nimdow-wl/status.toml` in `${XDG_CONFIG_DIRS:-/etc/xdg}` (installed by `nimdow-wl-desktop-git`)
4. the built-in default (`config.default.toml`)

If you gave no `--config` and the user file does not exist, the file from step 3 is copied to the user path on
first run (an existing file is never overwritten; if the copy fails the system file is used as is). With no system
file the built-in default is used and nothing is written. An existing but empty file counts as no file: the built-in
default runs.

With no config file you get a sensible default bar. To customise it, copy the default into place:

```sh
mkdir -p ~/.config/nimdow-wl
cp config.default.toml ~/.config/nimdow-wl/status.toml
cp -r scripts ~/.config/nimdow-wl/          # only if you want the example scripts
```

Open `~/.config/nimdow-wl/status.toml`, change something, and save. The bar updates right away.

A complete small example:

```toml
[bar]
style = "angle_b"

[colours]
bg     = "#3c3836"
accent = "#689d6a"

[[segment]]
module = "memory"
icon = "󰍛 "
colour = "bg"

[[segment]]
module = "battery"
colour = "bg"

[[segment]]
module = "datetime"
icon = " "
colour = "accent"
format = "ddd d MMM HH:mm "
```

That gives you three segments, `memory`, `battery` and `datetime`, from left to right.

## How the config works

The file is `~/.config/nimdow-wl/status.toml`. It has three parts.

### `[bar]`: settings for the whole bar

| Key | What it does | Default |
|---|---|---|
| `style` | Shape of each segment's edges (see below) | `"angle_b"` |
| `text_colour` | Text colour for every segment | nimdow-wl's `barForegroundColor` |

Styles: `arrow`, `arrow_l`, `arrow_r`, `circle`, `circle_l`, `circle_r`, `angle_a`,
`angle_b`, `none`. These are Nerd Font glyphs, so you need a Nerd Font set as your bar font.

### `[colours]`: your own colour names (optional)

Give hex colours a name once and use the name everywhere. Change it in one place and the whole bar follows.

```toml
[colours]
bg    = "#3c3836"
alert = "#fb4934"
```

A colour is always written as `"#rrggbb"`, or as a name from this section.

### `[[segment]]`: one block per item on the bar

**Order matters.** Segments appear left to right in the order they're written. Their
position is also their number: the first segment is 1, the second is 2, and so on. That
number is used for [clicking](#clicking-on-the-bar) and
[refreshing](#refreshing-a-segment-from-a-keybind).

Keys every segment accepts:

| Key | What it does | Default |
|---|---|---|
| `module` | **Required.** What to show (see [modules](#built-in-modules)) | |
| `icon` | Text shown before the value, usually a Nerd Font icon | none |
| `colour` | Background colour (`color` also works) | `"#282828"` |
| `text_colour` | Text colour for this segment only | from `[bar]` |
| `style` | Edge shape for this segment only | from `[bar]` |
| `interval` | Seconds between updates; decimals are OK, `0` means never on its own | per module |
| `show_always` | Show the segment even when it has nothing to say | `false` |

A hidden segment (nothing to say, no `show_always`) still keeps its number, so click regions and
`SIGRTMIN+N` signals never shift when a segment appears or disappears.

**Tip:** run `nimdow-wl-status --check-config` after editing. It lists any mistakes with the
segment number and key, for example `segment 3 (memory): key 'decimals': wrong type or value`.

## Built-in modules

These read directly from the kernel and start no extra programs, so they cost almost nothing.

### `datetime`

```toml
[[segment]]
module = "datetime"
icon = " "
colour = "#d79921"
format = "ddd d MMM HH:mm "     # → "Mon 9 Nov 16:30 "
```

The format uses [Nim's time format](https://nim-lang.org/docs/times.html#parsing-and-formatting-dates).
Common pieces: `HH:mm` is 24-hour time, `h:mm tt` is 12-hour time, `ddd` is Mon, `d MMM` is
9 Nov, and `yyyy-MM-dd` is 2026-11-09. It updates exactly on the minute, or every second if
the format includes seconds (`ss`). The clock is right straight after a suspend and after the system time is set; a timezone change shows at the next tick.

### `memory`

```toml
[[segment]]
module = "memory"
icon = "󰍛 "
method = "htop"      # "htop" (same number as htop) or "available" (same as `free`)
decimals = 2         # → "4.95 GiB"; below 1 GiB it shows MiB
```

It updates every 2 seconds by default.

### `cpu`

```toml
[[segment]]
module = "cpu"
icon = " "
decimals = 0         # → "12%"
```

Shows CPU usage averaged over the interval, which defaults to 2 seconds.

### `battery`

```toml
[[segment]]
module = "battery"
icons = [" ", "󰂎 ", "󱊡 ", "󱊢 ", "󱊢 ", "󱊣 "]   # charging, empty, low, half, 3/4, full
name = "BAT0"        # optional; the first battery found is used by default
```

The `icons` list must contain exactly 6 entries, in the order shown. With no battery the
segment is hidden and not polled again, so the same config works on a desktop. When several
batteries match, the first by name (`BAT0`) is used. It updates every 30 seconds by default.

### `net`

```toml
[[segment]]
module = "net"
show_always = true
icon_wifi = " "
icon_ethernet = "󰈀"
icon_disconnected = "󰌙 "
show_ssid = true     # show the wifi name next to the icon (needs nmcli)
```

Shows whether you're on wifi, on ethernet, or offline. The wifi name is looked up only when
the connection changes (and every 2 minutes), from NetworkManager's cached list: it never
triggers a wifi scan. With `show_ssid = false`
it shows the icon only and never runs `nmcli`. It updates every 5 seconds by default.

## Your own scripts

Anything not built in can come from a script, so the bar can show whatever you like. There
are two kinds.

### `command`: run a script every few seconds

```toml
[[segment]]
module = "command"
command = "uptime -p | sed 's/^up //'"
icon = " "
interval = 60          # seconds; default 60
timeout = 10           # kill it if it takes longer; default 10
hide_on_error = false  # true: hide the segment instead of showing N/A when it fails
```

The **first line** the command prints is shown (see [what is kept](#text-from-scripts)). If the command fails (non-zero exit) or
times out, the segment shows `N/A`.

### `stream`: a script that keeps running

```toml
[[segment]]
module = "stream"
command = "~/.config/nimdow-wl/scripts/volume.sh"
```

The script starts once and keeps running. **Every line it prints replaces the segment's
text** immediately. This suits things that change on events rather than on a timer, like
volume. If the script exits, it's restarted automatically after a short pause.

### Changing the colour from a script

A script can change its segment's background by printing a tab and a colour after the text:

```sh
printf 'UPDATING\t#fb4934\n'      # red background
printf 'Low!\talert\n'            # a name from [colours] works too
echo "All good"                   # no tab: back to the segment's normal colour
```

### Text from scripts

Anything that does not come from this program's own settings (script output, the wifi name) is
cleaned before it reaches the bar: control bytes (below `0x20`, and `0x7f`) are dropped, which
removes escape sequences and the `0x1F` byte that separates segments, so a script can never
add colours or click regions. The text is cut at 256 bytes (on a character boundary).

### Good to know

- Commands run with `sh -c`, so pipes, `~` and `$VARS` work.
- Relative paths are relative to the config folder (`~/.config/nimdow-wl/`), so
  `command = "scripts/weather.sh"` finds `~/.config/nimdow-wl/scripts/weather.sh`.
- Scripts are stopped automatically when nimdow-wl-status exits or reloads.
- Already have scripts from dwm, dwmblocks or slstatus? If they print one line, they work as a `command` as they are.

## Shipped scripts

Ready-made scripts in `scripts/`. Copy them to `~/.config/nimdow-wl/scripts/` and edit freely.

| Script | Kind | Shows | Arguments |
|---|---|---|---|
| `volume.sh` | `stream` | `" 45%"`, or the mute icon when muted (bursts of events are coalesced) | `[volume icon] [mute icon]` |
| `updates.sh` | `command` | `Updates: 3`, `0`, or `UPDATING` while pacman runs | `[colour while updating]` |
| `weather.sh` | `command` | `+20°C` from wttr.in | `[city]` (default: your location, found by IP) |

Without its tool (`pactl`, `checkupdates`, `curl`) a script prints nothing and its segment stays hidden.

```toml
[[segment]]
module = "stream"
command = "scripts/volume.sh ' ' '󰖁 '"

[[segment]]
module = "command"
command = "scripts/updates.sh alert"
icon = "󰣇 "
interval = 600
timeout = 60
show_always = true

[[segment]]
module = "command"
command = "scripts/weather.sh London"
icon = " "
interval = 600
```

## Clicking on the bar

Clicks are handled by nimdow-wl, not by nimdow-wl-status. In `~/.config/nimdow-wl/config.toml`,
`clickRegion` is the segment's position in your `status.toml`: 1 for the first segment, 2
for the second, and so on. `%7` is the mouse button: 1 is left, 3 is right, and 4 and 5 are
scroll up and down.

```toml
# Segment 1 = updates: left click opens a terminal and upgrades
[[startProcess]]
command = "kitty -e sh -c 'paru -Syu; read _'"
clickRegion = 1

# Segment 4 = volume: scroll to change it, left click to mute
[[startProcess]]
command = "sh -c 'case %7 in 4) wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ ;; 5) wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- ;; 1) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;; esac'"
clickRegion = 4
```

If you reorder segments in `status.toml`, update the `clickRegion` numbers to match.

## Refreshing a segment from a keybind

You can tell nimdow-wl-status to update a segment immediately, which is handy after
changing brightness or upgrading packages:

```sh
pkill -RTMIN+3 nimdow-wl-stat      # refresh segment 3
pkill -USR1    nimdow-wl-stat      # refresh everything
pkill -HUP     nimdow-wl-stat      # reload the config (saving the file already does this)
```

For example, to update the updates segment right after an upgrade, run
`paru -Syu; pkill -RTMIN+1 nimdow-wl-stat`.

> **Why `nimdow-wl-stat` and not the full name?** Linux shortens process names to 15
> characters, so the running process is called `nimdow-wl-statu`, and `pkill nimdow-wl-status`
> finds nothing. Don't use `pkill -f` either: it can match other programs that merely
> mention the name.

## Troubleshooting

| Problem | Fix |
|---|---|
| A change in `status.toml` did nothing | Run `nimdow-wl-status --check-config`. If the file has a mistake, the bar keeps your last working config until you fix it. |
| The bar shows the default instead of my config | The config had errors at startup. Run `--check-config` to see them. |
| Icons show as boxes | Use a [Nerd Font](https://www.nerdfonts.com) as your nimdow-wl bar font. |
| A script segment shows `N/A` | The command failed or timed out. Run it in a terminal to see why, or raise `timeout`. |
| The battery segment is missing | No battery was found, so it is hidden. Set `name` if yours has an unusual one (see `ls /sys/class/power_supply`). |
| I want to see what it sends | Run `nimdow-wl-status --stdout` in a terminal; it prints each update as a line. |
| Clicks hit the wrong segment | `clickRegion` numbers follow the segment order in `status.toml` (hidden segments count); update them after reordering. |
| The bar is empty after restarting nimdow-wl | It resends the status as soon as the new socket appears. If it does not, check that `nimdow-wl-stat` still runs. |

### Command-line options

```
nimdow-wl-status                    run and feed the nimdow-wl bar
nimdow-wl-status --stdout           print updates to the terminal instead
nimdow-wl-status --config <file>    use a different config file
nimdow-wl-status --check-config     check the config, report problems, and exit
nimdow-wl-status -h, --help         show this usage
```

An unknown option prints the usage and exits with status 2.

---

Design notes for contributors are in [docs/DESIGN.md](docs/DESIGN.md).
License: GPL-3.0-or-later.
