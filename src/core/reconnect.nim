## Fork-free connectivity check: is there a default route?
import std/strutils
import events

proc hasV4Route(): bool =
  try:
    var first = true
    for line in lines("/proc/net/route"):
      if first:
        first = false
        continue
      let f = line.splitWhitespace()
      if f.len > 7 and f[1] == "00000000" and f[7] == "00000000":
        # RTF_UP flag
        if (parseHexInt(f[3]) and 1) != 0: return true
  except CatchableError: discard

proc hasV6Route(): bool =
  try:
    for line in lines("/proc/net/ipv6_route"):
      let f = line.splitWhitespace()
      # dest(32 hex) plen(00) ... metric ... flags(8) ifname
      if f.len >= 10 and f[0] == "00000000000000000000000000000000" and f[1] == "00" and
         f[9] != "lo" and (parseHexInt(f[8]) and 1) != 0: return true
  except CatchableError: discard

proc getIsOnline*(): bool = hasV4Route() or hasV6Route()

proc initConnectChecker*(onReconnect: proc() {.closure.}, intervalMs = 5000) =
  ## Polls every intervalMs; calls onReconnect on an offline -> online transition.
  var wasOnline = getIsOnline()
  var tick: proc() {.closure.}
  tick = proc() =
    let online = getIsOnline()
    if online and not wasOnline:
      onReconnect()
    wasOnline = online
    discard after(intervalMs, tick)
  discard after(intervalMs, tick)
