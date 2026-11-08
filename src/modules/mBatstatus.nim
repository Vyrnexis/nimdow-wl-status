import std/[os, strutils]
import ../core/segment

const
  ## Default battery icons: charging, empty, low, half, 3qtr, full
  BATTERY_ICONS* = @[" \u{f1e6}", "\u{f244} ", "\u{f243} ", "\u{f242} ", "\u{f241} ", "\u{f240} "]

proc batteryHooks*(icons: seq[string], name = ""): Hooks =
  ## icons: 6 entries (charging, empty, low, half, 3qtr, full). name: e.g. "BAT0"; empty = first battery found.
  var batDir = ""
  result.body = proc(s: Segment): string =
    # Use the first battery found (BAT0, BAT1, ...); the directory is cached after the first scan
    if batDir == "":
      if name != "":
        let path = "/sys/class/power_supply" / name
        if fileExists(path / "capacity"): batDir = path
      else:
        for path in walkDirs("/sys/class/power_supply/BAT*"):
          if fileExists(path / "capacity"):
            batDir = path
            break
    let bat = batDir
    if bat == "":
      return icons[1] & "N/A" #isEmpty
    else:
      # Read the first line of the these files
      let sBatStats = readLines(bat / "status", 1)
      let sCapacity = readLines(bat / "capacity", 1)

      # Check if battery status is in charging mode
      if sBatStats[0] == "Charging":
        s.icon = icons[0] #isPlg
      else:
        case parseInt(sCapacity[0]):
        of 10..35:
          s.icon = icons[2] #isLow
        of 36..59:
          s.icon = icons[3] #isHalf
        of 60..85:
          s.icon = icons[4] #is3Qrt
        of 86..100:
          s.icon = icons[5] #isFull
        else:
          s.icon = icons[1] #isEmpty
      # return the corresponding icon and battery level
      return sCapacity[0] & "%"
