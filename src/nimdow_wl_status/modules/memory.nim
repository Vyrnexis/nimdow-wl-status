import std/[strutils, tables]
import ../[config, loop]

proc init*(s: Seg) =
  ## method "htop": htop's formula; "available": MemTotal - MemAvailable.
  let useAvailable = s.cfg.str("method", "htop") == "available"
  let decimals = int(s.cfg.num("decimals", 2))
  s.refresh = proc() =
    var m: Table[string, int]
    for line in lines("/proc/meminfo"):
      let c = line.find(':')
      if c > 0: m[line[0 ..< c]] = line[c + 1 .. ^1].strip().split()[0].parseInt()
    let used =
      if useAvailable: m["MemTotal"] - m["MemAvailable"]
      else: m["MemTotal"] - (m["MemFree"] + m["Buffers"] + m["Cached"]) + (m["Shmem"] - m["SReclaimable"])
    s.setBody(if used >= 1048576: formatFloat(used.float / (1024.0 * 1024.0), ffDecimal, decimals) & " GiB"
              else: $(used div 1024) & " MiB")
