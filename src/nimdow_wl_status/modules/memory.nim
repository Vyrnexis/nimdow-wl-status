import std/[strutils, parseutils]
import ../[config, loop, procfs]

const Keys = ["MemTotal", "MemFree", "MemAvailable", "Buffers", "Cached", "Shmem", "SReclaimable"]

proc parseMeminfo*(buf: string, n: int, v: var array[Keys.len, int]) =
  ## Fills `v` (kB, -1 = absent) from the first `n` bytes of /proc/meminfo, one pass,
  ## only the keys in `Keys`.
  for x in v.mitems: x = -1
  var i = 0
  while i < n:
    var eol = buf.find('\n', i)
    if eol < 0 or eol > n: eol = n
    let colon = buf.find(':', i, eol - 1)
    if colon > i:
      for k, key in Keys:
        if colon - i == key.len and cmpMem(unsafeAddr buf[i], key.cstring, key.len) == 0:
          var x: int
          discard parseInt(buf, x, colon + 1 + skipWhitespace(buf, colon + 1))
          v[k] = x
          break
    i = eol + 1

proc init*(s: Seg) =
  ## method "htop": htop's formula; "available": MemTotal - MemAvailable.
  let useAvailable = s.cfg.str("method", "htop") == "available"
  let decimals = int(s.cfg.num("decimals", 2))
  var
    fd = cint(-1)
    buf = newString(8192)
    v: array[Keys.len, int]
  s.refresh = proc() =
    let n = slurp(fd, "/proc/meminfo", buf)
    if n <= 0: raise newException(IOError, "cannot read /proc/meminfo")
    parseMeminfo(buf, n, v)
    let used =
      if useAvailable:
        if v[0] < 0 or v[2] < 0: raise newException(IOError, "no MemAvailable in /proc/meminfo")
        v[0] - v[2]
      else:
        for x in [0, 1, 3, 4, 5, 6]:
          if v[x] < 0: raise newException(IOError, "missing " & Keys[x] & " in /proc/meminfo")
        v[0] - (v[1] + v[3] + v[4]) + (v[5] - v[6])
    s.setBody(if used >= 1048576: formatFloat(used.float / (1024.0 * 1024.0), ffDecimal, decimals).strip(leading = false, chars = {'.'}) & " GiB"
              else: $(used div 1024) & " MiB")
