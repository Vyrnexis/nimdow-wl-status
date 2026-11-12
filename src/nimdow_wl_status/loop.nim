## One selector, timers (segment deadlines among them), signalfd, and the live segment type.
import std/[selectors, times, posix, tables, inotify]
import config, render

type
  Seg* = ref object
    cfg*: SegCfg
    icon*, bg*, text*: string       ## current icon / background (scripts may override) / rendered text
    body, rIcon, rBg: string        ## what `text` was built from
    align*: int                     ## >0: due on wall-clock multiples of this many seconds
    refresh*: proc() {.closure.}    ## module action: re-read / re-run
    timer: Deadline
  Deadline* = ref object
    due: int64                      ## CLOCK_BOOTTIME ns: counts suspend, so a resume fires what is overdue
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
  onClockSet*: proc() {.closure.}   ## the wall clock was set (aligned deadlines are stale)
  tfd, setFd: cint                  ## the one timerfd (earliest deadline) / wall-clock-set detector
  armed = 0'i64                     ## deadline loaded into tfd (0 = disarmed)

const
  ClockBoottime = 7.cint
  TfdAbstime = 1.cint
  TfdCancelOnSet = 2.cint

proc signalfd(fd: cint, mask: ptr Sigset, flags: cint): cint {.importc, header: "<sys/signalfd.h>".}
proc timerfd_create(clock, flags: cint): cint {.importc, header: "<sys/timerfd.h>".}
proc timerfd_settime(fd, flags: cint, new, old: ptr Itimerspec): cint {.importc, header: "<sys/timerfd.h>".}
proc sigRtMin*(): cint {.importc: "__libc_current_sigrtmin", header: "<signal.h>".}

proc watch*(fd: cint, cb: proc() {.closure.}) =
  sel.registerHandle(fd.int, {Event.Read}, 0)
  handlers[fd.int] = cb

proc unwatch*(fd: cint) =
  handlers.del(fd.int)
  try: sel.unregister(fd.int) except CatchableError: discard

proc bootNow(): int64 =
  var t: Timespec
  discard clock_gettime(ClockBoottime, t)
  t.tv_sec.int64 * 1_000_000_000 + t.tv_nsec

proc after*(ms: int, cb: proc() {.closure.}): Deadline =
  result = Deadline(due: bootNow() + ms.int64 * 1_000_000, cb: cb)
  timers.add result

proc cancel*(t: Deadline) =
  let i = timers.find(t)
  if i >= 0: timers.delete(i)

proc setBody*(s: Seg, body: string) =
  if body == s.body and s.icon == s.rIcon and s.bg == s.rBg: return
  s.body = body
  s.rIcon = s.icon
  s.rBg = s.bg
  let t = segmentText(s.cfg.sides, s.bg, s.cfg.fg, s.icon, sanitize(body), s.cfg.showAlways)
  if t != s.text:
    s.text = t
    dirty = true

proc runSeg*(s: Seg)

proc arm(s: Seg) =
  if s.align > 0:
    let n = now()
    s.timer = after((s.align - n.second mod s.align) * 1000 - n.nanosecond div 1_000_000 + 5, proc() = runSeg(s))
  elif s.cfg.interval > 0:
    s.timer = after(int(s.cfg.interval * 1000), proc() = runSeg(s))

proc runSeg*(s: Seg) =
  ## Refresh now and (re)arm the segment's next deadline, even if the refresh raises.
  cancel(s.timer)
  try: s.refresh()
  except CatchableError as e:
    stderr.writeLine "error: segment: ", e.msg
    s.setBody("N/A")
  arm(s)

proc readEvents*(fd: cint, cb: proc(wd: cint, mask: uint32, name: string)) =
  ## Drains an inotify fd, calling cb for each event.
  var buf: array[4096, byte]
  while true:
    let n = read(fd, addr buf[0], buf.len)
    if n <= 0: break
    var off = 0
    while off + sizeof(InotifyEvent) <= n:
      let ev = cast[ptr InotifyEvent](addr buf[off])
      cb(ev.wd, ev.mask, if ev.len > 0: $cast[cstring](addr buf[off + sizeof(InotifyEvent)]) else: "")
      off += sizeof(InotifyEvent) + ev.len.int

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

proc setTimer(due: int64) =
  ## Load the earliest deadline into the timerfd (0 disarms).
  if due == armed: return
  armed = due
  var its: Itimerspec
  its.it_value.tv_sec = posix.Time(due div 1_000_000_000)
  its.it_value.tv_nsec = clong(due mod 1_000_000_000)
  discard timerfd_settime(tfd, TfdAbstime, addr its, nil)

proc watchClock() =
  ## An absolute timer far ahead, cancelled whenever the wall clock is set: a step then
  ## shows up as ECANCELED on read.
  setFd = timerfd_create(CLOCK_REALTIME, O_NONBLOCK or O_CLOEXEC)
  proc rearm() =
    var its: Itimerspec
    its.it_value.tv_sec = posix.Time(1 shl 40)
    discard timerfd_settime(setFd, TfdAbstime or TfdCancelOnSet, addr its, nil)
  rearm()
  watch(setFd, proc() =
    var x: uint64
    if read(setFd, addr x, sizeof(x)) < 0 and errno == ECANCELED:
      rearm()
      if onClockSet != nil: onClockSet())

proc run*() =
  tfd = timerfd_create(ClockBoottime, O_NONBLOCK or O_CLOEXEC)
  watch(tfd, proc() =
    var x: uint64
    discard read(tfd, addr x, sizeof(x)))
  watchClock()
  while not stopped:
    var due = 0'i64
    for t in timers:
      if due == 0 or t.due < due: due = t.due
    setTimer(due)
    for k in sel.select(-1):
      try:
        if k.fd in handlers: handlers[k.fd]()
      except CatchableError as e: stderr.writeLine "error: ", e.msg
    let n = bootNow()
    var fire: seq[Deadline]
    for t in timers:
      if t.due <= n: fire.add t
    for t in fire:
      cancel(t)
      try: t.cb()
      except CatchableError as e: stderr.writeLine "error: ", e.msg
    if onIdle != nil: onIdle()
