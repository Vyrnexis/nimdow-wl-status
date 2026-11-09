## One selector, timers (segment deadlines among them), signalfd, and the live segment type.
import std/[selectors, monotimes, times, posix, tables]
import config, render

type
  Seg* = ref object
    cfg*: SegCfg
    icon*, bg*, text*: string       ## current icon / background (scripts may override) / rendered text
    align*: int                     ## >0: due on wall-clock multiples of this many seconds
    refresh*: proc() {.closure.}    ## module action: re-read / re-run
    timer: Deadline
  Deadline* = ref object
    due: MonoTime
    cb: proc() {.closure.}
  SigInfo {.importc: "struct signalfd_siginfo", header: "<sys/signalfd.h>".} = object
    ssi_signo: uint32

var
  sel = newSelector[int]()
  handlers: Table[int, proc() {.closure.}]
  timers: seq[Deadline]
  stopped = false
  dirty* = false                    ## a segment's text changed
  palette*: Table[string, string]   ## [colours], for script colour names
  onIdle*: proc() {.closure.}       ## called after each wake-up (flush the bar)

proc signalfd(fd: cint, mask: ptr Sigset, flags: cint): cint {.importc, header: "<sys/signalfd.h>".}
proc sigRtMin*(): cint {.importc: "__libc_current_sigrtmin", header: "<signal.h>".}

proc watch*(fd: cint, cb: proc() {.closure.}) =
  sel.registerHandle(fd.int, {Event.Read}, 0)
  handlers[fd.int] = cb

proc unwatch*(fd: cint) =
  handlers.del(fd.int)
  try: sel.unregister(fd.int) except CatchableError: discard

proc after*(ms: int, cb: proc() {.closure.}): Deadline =
  result = Deadline(due: getMonoTime() + initDuration(milliseconds = ms), cb: cb)
  timers.add result

proc cancel*(t: Deadline) =
  let i = timers.find(t)
  if i >= 0: timers.delete(i)

proc setBody*(s: Seg, body: string) =
  let t = segmentText(s.cfg.sides, s.bg, s.cfg.fg, s.icon, body, s.cfg.showAlways)
  if t != s.text:
    s.text = t
    dirty = true

proc arm(s: Seg) =
  if s.align > 0:
    let n = now()
    s.timer = after((s.align - n.second mod s.align) * 1000 - n.nanosecond div 1_000_000 + 5, proc() = s.refresh(); arm(s))
  elif s.cfg.interval > 0:
    s.timer = after(int(s.cfg.interval * 1000), proc() = s.refresh(); arm(s))

proc runSeg*(s: Seg) =
  ## Refresh now and (re)arm the segment's next deadline.
  cancel(s.timer)
  try: s.refresh()
  except CatchableError as e:
    stderr.writeLine "error: segment: ", e.msg
    s.setBody("N/A")
  arm(s)

proc watchSignals*(sigs: seq[cint], cb: proc(sig: cint)) =
  ## Block `sigs` and receive them through the selector. SIGPIPE is blocked too (children
  ## get an empty mask), so a dead socket gives EPIPE instead of killing us.
  var mask: Sigset
  discard sigemptyset(mask)
  for s in sigs: discard sigaddset(mask, s)
  let fd = signalfd(-1, addr mask, O_NONBLOCK or O_CLOEXEC)
  discard sigaddset(mask, SIGPIPE)
  discard sigprocmask(SIG_BLOCK, mask, mask)
  watch(fd, proc() =
    var info: SigInfo
    while read(fd, addr info, sizeof(info)) == sizeof(info): cb(cint(info.ssi_signo)))

proc stop*() = stopped = true

proc run*() =
  while not stopped:
    var timeout = -1
    if timers.len > 0:
      var due = timers[0].due
      for t in timers:
        if t.due < due: due = t.due
      timeout = max(0, int((due - getMonoTime()).inNanoseconds + 999_999) div 1_000_000)
    for k in sel.select(timeout):
      try:
        if k.fd in handlers: handlers[k.fd]()
      except CatchableError as e: stderr.writeLine "error: ", e.msg
    let n = getMonoTime()
    var fire: seq[Deadline]
    for t in timers:
      if t.due <= n: fire.add t
    for t in fire:
      cancel(t)
      try: t.cb()
      except CatchableError as e: stderr.writeLine "error: ", e.msg
    if onIdle != nil: onIdle()
