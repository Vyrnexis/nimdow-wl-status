import std/[strutils, parseutils]
import ../[config, loop, procfs]

proc parseStat*(line: string, total, idle: var int) =
  ## "cpu user nice system idle iowait irq softirq steal guest guest_nice": `total` is the
  ## first 8 fields (guest time is already inside user), `idle` is idle + iowait.
  total = 0
  idle = 0
  var i = 3
  for n in 0 ..< 8:
    var v: int
    i += skipWhitespace(line, i)
    let k = parseInt(line, v, i)
    if k == 0: break
    i += k
    total += v
    if n == 3 or n == 4: idle += v

proc usage*(dTotal, dIdle: int): float =
  ## Busy percentage of a delta; 0 when nothing elapsed.
  if dTotal > 0: 100.0 * (dTotal - dIdle).float / dTotal.float else: 0.0

proc init*(s: Seg) =
  ## Usage over the interval, from /proc/stat deltas; the baseline is taken here, so the
  ## first value is not the average since boot.
  let decimals = int(s.cfg.num("decimals", 0))
  var
    fd = cint(-1)
    buf = newString(256)
    prevTotal, prevIdle, total, idle = 0
  proc sample() =
    let n = slurp(fd, "/proc/stat", buf)
    if n <= 0: raise newException(IOError, "cannot read /proc/stat")
    parseStat(buf, total, idle)       # only the first line is read: its fields end before 256
  sample()
  prevTotal = total
  prevIdle = idle
  s.refresh = proc() =
    sample()
    if total == prevTotal: return     # nothing elapsed yet (rerun right after start): keep the body
    let u = usage(total - prevTotal, idle - prevIdle)
    prevTotal = total
    prevIdle = idle
    s.setBody(formatFloat(u, ffDecimal, decimals).strip(leading = false, chars = {'.'}) & "%")
