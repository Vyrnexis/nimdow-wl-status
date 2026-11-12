import std/[os, strutils, algorithm]
import ../[config, loop]

const Icons = @[" \u{f1e6}", "\u{f244} ", "\u{f243} ", "\u{f242} ", "\u{f241} ", "\u{f240} "]

proc init*(s: Seg) =
  ## icons: charging, empty, low, half, 3qtr, full. name: e.g. BAT0 (default: first found).
  let icons = if s.cfg.list("icons").len == 6: s.cfg.list("icons") else: Icons
  let name = s.cfg.str("name")
  var dir = ""
  s.refresh = proc() =
    if dir == "":
      var found: seq[string]
      for p in walkDirs("/sys/class/power_supply/" & (if name != "": name else: "BAT*")):
        if fileExists(p / "capacity"): found.add p
      if found.len > 0: dir = found.sorted[0]
    if dir == "":                    # no battery: hide, and stop polling (a signal reruns it)
      s.cfg.interval = 0
      s.setBody("")
      return
    try:
      let cap = readFile(dir / "capacity").strip
      s.icon =
        if readFile(dir / "status").strip == "Charging": icons[0]
        else:
          case parseInt(cap)
          of 10 .. 35: icons[2]
          of 36 .. 59: icons[3]
          of 60 .. 85: icons[4]
          of 86 .. 100: icons[5]
          else: icons[1]
      s.setBody(cap & "%")
    except CatchableError:
      dir = ""                       # gone: look again next time
      raise
