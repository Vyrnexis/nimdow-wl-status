import std/[os, strutils, monotimes, times]
import ../core/[segment, procs]

const
  ## Default icons (the wifi / disconnected ones are followed by a space)
  WIFI_ICON* = "\u{f1eb} "
  ETHERNET_ICON* = "\u{f0200}\u{f6ff}"
  DISCONNECTED_ICON* = "\u{f072} "

const SSID_MAX_AGE = initDuration(minutes = 2)

proc unescapeTerse(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      inc i
    result.add s[i]
    inc i

proc isWireless(name: string): bool =
  if dirExists("/sys/class/net" / name / "wireless"): return true
  try:
    for line in lines("/proc/net/wireless"):
      if line.strip().startsWith(name & ":"): return true
  except CatchableError: discard

proc wifiHooks*(iconWifi, iconEthernet, iconDisconnected: string, showSsid: bool): Hooks =
  let runner = newRunner()
  var
    linkKey = ""          # "eth", "wifi:<if>" or "down"
    ssid = ""             # cached SSID for the current wifi link
    lastQuery: MonoTime

  proc queryUp(s: Segment) =
    runner.run("nmcli", @["-t", "-f", "ACTIVE,SSID", "device", "wifi"], 10_000, proc(output: string, code: int) =
      var found = ""
      if code == 0:
        for line in output.splitLines():
          if line.startsWith("yes:"):
            found = unescapeTerse(line[4 .. ^1])
            break
      ssid = found
      lastQuery = getMonoTime()
      if linkKey.startsWith("wifi:"):
        s.icon = iconWifi
        s.setBody(if showSsid: ssid else: ""))

  # Fork-free link detection via sysfs; nmcli only runs (async) when the link state changes.
  result.body = proc(s: Segment): string =
    var key = "down"
    for kind, path in walkDir("/sys/class/net"):
      let name = path.extractFilename
      if name == "lo" or not (dirExists(path / "device") or symlinkExists(path / "device")): continue
      let up = try: readFile(path / "operstate").strip() == "up" except CatchableError: false
      if not up: continue
      if isWireless(name):
        if not key.startsWith("wifi:") and key != "eth": key = "wifi:" & name
      else:
        key = "eth"
    if key == "eth":
      linkKey = key
      s.icon = iconEthernet
      return ""
    if key.startsWith("wifi:"):
      if key != linkKey:
        ssid = ""
        linkKey = key
        if showSsid: queryUp(s)
      elif showSsid and getMonoTime() - lastQuery > SSID_MAX_AGE:
        lastQuery = getMonoTime()
        queryUp(s)
      s.icon = iconWifi
      return if showSsid: ssid else: ""
    linkKey = key
    ssid = ""
    s.icon = iconDisconnected
    return ""
