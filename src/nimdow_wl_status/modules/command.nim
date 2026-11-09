## Generic `command` (run every interval) and `stream` (long-running) script segments.
import std/[strutils, monotimes, times, tables]
import ../[config, loop, child, render]

proc show(s: Seg, line: string) =
  ## `text` or `text<TAB>colour`; the colour holds until the next line.
  let tab = line.find('\t')
  s.bg = s.cfg.bg
  if tab >= 0:
    let c = line[tab + 1 .. ^1].strip
    if isHex(c): s.bg = c
    elif c.toLowerAscii in palette: s.bg = palette[c.toLowerAscii]
  s.setBody((if tab >= 0: line[0 ..< tab] else: line).strip)

proc initCommand*(s: Seg, dir: string) =
  let cmd = s.cfg.str("command")
  let timeout = int(s.cfg.num("timeout", 10) * 1000)
  let hide = s.cfg.flag("hide_on_error", false)
  var current: Child
  s.refresh = proc() =
    if current != nil: current.kill()          # rerun: the old run's callbacks go quiet
    var first: string
    var got = false
    var me: Child
    me = spawn(cmd, dir, false, timeout,
      proc(line: string) =
        if not got: (got = true; first = line),
      proc(code: int) =
        if me != current: return
        current = nil
        if code != 0:
          s.bg = s.cfg.bg
          s.setBody(if hide: "" else: "N/A")
        else: s.show(first))
    current = me

proc initStream*(s: Seg, dir: string) =
  let cmd = s.cfg.str("command")
  var
    current: Child
    retry: Deadline
    backoff = 500                              # ms, doubling to 30s, reset after 10s alive
    started: MonoTime
  proc start() =
    started = getMonoTime()
    var me: Child
    me = spawn(cmd, dir, true, 0,
      proc(line: string) =
        if me == current: s.show(line),
      proc(code: int) =
        if me != current: return
        current = nil
        if getMonoTime() - started > initDuration(seconds = 10): backoff = 500
        retry = after(backoff, start)
        backoff = min(backoff * 2, 30_000))
    current = me
  s.refresh = proc() =                         # (re)start now
    cancel(retry)
    if current != nil:
      let old = current
      current = nil
      old.kill()
    start()
