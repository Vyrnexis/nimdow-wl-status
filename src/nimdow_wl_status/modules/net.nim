import std/[os, strutils, monotimes, times]
import ../[config, loop, child]

proc isWireless(name: string): bool =
  dirExists("/sys/class/net" / name / "wireless")

proc init*(s: Seg) =
  ## Link state from sysfs; `nmcli` (async) only for the SSID, when the link changes or every 2 min.
  let
    iconWifi = s.cfg.str("icon_wifi", "\u{f1eb} ")
    iconEth = s.cfg.str("icon_ethernet", "\u{f0200}\u{f6ff}")
    iconDown = s.cfg.str("icon_disconnected", "\u{f072} ")
    showSsid = s.cfg.flag("show_ssid", true)
  var link, ssid = ""               # "eth", "wifi:<if>" or "down"
  var lastQuery: MonoTime

  proc show() =
    s.icon = (if link == "eth": iconEth elif link.startsWith("wifi:"): iconWifi else: iconDown)
    s.setBody(if showSsid and link.startsWith("wifi:"): ssid else: "")

  proc query() =
    lastQuery = getMonoTime()
    let asked = link
    var found = ""
    # --rescan no: read NetworkManager's list, never trigger a scan
    discard spawn("nmcli -t -f ACTIVE,SSID device wifi list --rescan no", "", false, 10_000,
      proc(line: string) =
        if line.startsWith("yes:"): found = line[4 .. ^1].replace("\\:", ":").replace("\\\\", "\\"),
      proc(code: int) =
        if link != asked: return        # the link changed meanwhile: a newer answer is coming
        ssid = if code == 0: found else: ""
        show())

  s.refresh = proc() =
    var key = "down"
    for _, path in walkDir("/sys/class/net"):
      let name = path.extractFilename
      if name == "lo" or not (dirExists(path / "device") or symlinkExists(path / "device")): continue
      if (try: readFile(path / "operstate").strip != "up" except CatchableError: true): continue
      if isWireless(name):
        if key notin ["eth"] and not key.startsWith("wifi:"): key = "wifi:" & name
      else: key = "eth"
    let changed = key != link
    link = key
    if changed: ssid = ""
    if showSsid and key.startsWith("wifi:") and (changed or getMonoTime() - lastQuery > initDuration(minutes = 2)):
      query()
    show()
