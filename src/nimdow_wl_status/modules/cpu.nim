import std/[strutils, sequtils]
import ../[config, loop]

proc init*(s: Seg) =
  ## Usage over the interval, from /proc/stat deltas.
  let decimals = int(s.cfg.num("decimals", 0))
  var prevTotal, prevIdle = 0
  s.refresh = proc() =
    var f: File
    if not open(f, "/proc/stat"): raise newException(IOError, "cannot read /proc/stat")
    let v = f.readLine().splitWhitespace()[1 .. ^1].map(parseInt)   # user nice system idle iowait ...
    f.close()
    let total = v.foldl(a + b)
    let idle = v[3] + v[4]
    let dt = total - prevTotal
    let usage = if dt > 0: 100.0 * (dt - (idle - prevIdle)).float / dt.float else: 0.0
    prevTotal = total
    prevIdle = idle
    s.setBody(formatFloat(usage, ffDecimal, decimals).strip(leading = false, chars = {'.'}) & "%")
