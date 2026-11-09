import std/times
import ../[config, loop]

proc hasSeconds(fmt: string): bool =
  ## An unquoted `s` pattern (quoted 'text' is literal in Nim's format).
  var quoted = false
  for c in fmt:
    if c == '\'': quoted = not quoted
    elif c == 's' and not quoted: return true

proc init*(s: Seg) =
  let fmt = s.cfg.str("format", "ddd d MMM HH:mm ")
  if s.cfg.interval < 0: s.align = if hasSeconds(fmt): 1 else: 60
  s.refresh = proc() = s.setBody(now().format(fmt))
