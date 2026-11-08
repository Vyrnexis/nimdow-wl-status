## Shared selector + one-shot timers for the event loop.
import std/[selectors, monotimes, times, tables]

type
  FdHandler* = proc() {.closure.}
  TimerHandler* = proc() {.closure.}
  TimerId* = int
  Timer = object
    id: TimerId
    due: MonoTime
    cb: TimerHandler

let sel* = newSelector[int]()
var
  handlers = initTable[int, FdHandler]()
  timers: seq[Timer]
  nextTimerId = 0

proc watchFd*(fd: int, cb: FdHandler) =
  ## Call `cb` whenever `fd` is readable (or hung up / errored).
  sel.registerHandle(fd, {Event.Read}, fd)
  handlers[fd] = cb

proc unwatchFd*(fd: int) =
  if fd in handlers:
    handlers.del(fd)
    try: sel.unregister(fd)
    except CatchableError: discard

proc after*(ms: int, cb: TimerHandler): TimerId =
  inc nextTimerId
  timers.add Timer(id: nextTimerId, due: getMonoTime() + initDuration(milliseconds = ms), cb: cb)
  nextTimerId

proc cancel*(id: TimerId) =
  for i in 0 ..< timers.len:
    if timers[i].id == id:
      timers.delete(i)
      return

proc earliestTimer*(): (bool, MonoTime) =
  for t in timers:
    if not result[0] or t.due < result[1]:
      result = (true, t.due)

proc runTimers*() =
  let n = getMonoTime()
  var fire: seq[TimerHandler]
  var i = 0
  while i < timers.len:
    if timers[i].due <= n:
      fire.add timers[i].cb
      timers.delete(i)
    else:
      inc i
  for cb in fire:
    try: cb()
    except CatchableError as e: stderr.writeLine "timer error: ", e.msg

proc pollFds*(timeoutMs: int) =
  ## Wait for fd events (timeoutMs < 0 = forever) and dispatch handlers.
  var keys: seq[ReadyKey]
  try:
    keys = sel.select(timeoutMs)
  except CatchableError:
    return
  for k in keys:
    let cb = handlers.getOrDefault(k.fd, nil)
    if cb != nil:
      try: cb()
      except CatchableError as e: stderr.writeLine "fd handler error: ", e.msg
