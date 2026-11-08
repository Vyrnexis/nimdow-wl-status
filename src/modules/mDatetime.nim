import std/times
import ../core/segment

proc validDateTimeFormat*(fmt: string): bool =
  try: discard format(now(), fmt)
  except CatchableError: return false
  true

proc formatHasSeconds*(fmt: string): bool =
  ## True if an unquoted `s` pattern appears (quoted 'text' is literal in Nim's format).
  var quoted = false
  for c in fmt:
    if c == '\'': quoted = not quoted
    elif c == 's' and not quoted: return true

proc dateTimeHooks*(fmt: string): Hooks =
  result.body = proc(s: Segment): string = format(now(), fmt)
