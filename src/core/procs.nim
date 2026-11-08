## Non-blocking child processes driven by the shared selector.
import std/[os, osproc, posix, strutils, monotimes, times, streams]
import events

proc setNonBlock(fd: cint) =
  let fl = fcntl(fd, F_GETFL)
  discard fcntl(fd, F_SETFL, fl or O_NONBLOCK)

proc drain(fd: cint, sink: var string, keep: bool): bool =
  ## Read all currently available bytes. Returns true on EOF.
  var buf: array[4096, char]
  while true:
    let n = read(fd, addr buf[0], buf.len)
    if n > 0:
      if keep:
        let o = sink.len
        sink.setLen(o + n)
        copyMem(addr sink[o], addr buf[0], n)
    elif n == 0:
      return true
    else:
      return false  # EAGAIN / EINTR / error: wait for next event

proc spawn(cmd: string, args: seq[string]): Process =
  result = startProcess(cmd, args = args, options = {poUsePath})
  try: streams.close(result.inputStream) except CatchableError: discard
  setNonBlock(result.outputHandle.cint)
  setNonBlock(result.errorHandle.cint)

var
  runProcs: seq[Process]    # one-shot children currently running
  streamProcs: seq[Process]

proc finish(p: Process, outFd, errFd: cint) =
  unwatchFd(outFd.int)
  let i = runProcs.find(p)
  if i >= 0: runProcs.delete(i)
  p.close()

proc runAsync*(cmd: string, args: seq[string], timeoutMs: int,
               onDone: proc(output: string, exitCode: int) {.closure.}) =
  ## Run a child without blocking; calls onDone(stdout, exitCode) when it exits.
  ## exitCode is -1 if it could not start or was killed on timeout.
  var p: Process
  try:
    p = spawn(cmd, args)
  except CatchableError:
    onDone("", -1)
    return
  runProcs.add p
  let outFd = p.outputHandle.cint
  let errFd = p.errorHandle.cint
  var
    output, junk: string
    timer: TimerId = 0
    killed = false
    done = false
    pollReap: proc() {.closure.}

  proc complete() =
    if done: return
    done = true
    if timer != 0: cancel(timer)
    finish(p, outFd, errFd)
    let code = if killed: -1 else: p.peekExitCode()
    onDone(output, code)

  pollReap = proc() =
    # stdout hit EOF: reap (child may take a moment to actually exit)
    if p.peekExitCode() == -1 and not killed:
      timer = after(10, pollReap)
    else:
      timer = 0
      complete()

  watchFd(outFd.int, proc() =
    discard drain(errFd, junk, false)
    if drain(outFd, output, true):
      unwatchFd(outFd.int)
      pollReap())
  if timeoutMs > 0:
    timer = after(timeoutMs, proc() =
      timer = 0
      killed = true
      try: p.kill() except CatchableError: discard
      discard p.waitForExit()
      complete())

type Runner* = ref object
  ## Guarantees at most one concurrent run; a request during a run is coalesced
  ## into a single re-run afterwards.
  busy: bool
  again: bool
  cmd: string
  args: seq[string]
  timeoutMs: int
  onDone: proc(output: string, exitCode: int) {.closure.}

proc newRunner*(): Runner = Runner.new

proc run*(r: Runner, cmd: string, args: seq[string], timeoutMs: int,
          onDone: proc(output: string, exitCode: int) {.closure.}) =
  r.cmd = cmd; r.args = args; r.timeoutMs = timeoutMs; r.onDone = onDone
  if r.busy:
    r.again = true
    return
  r.busy = true
  r.again = false
  runAsync(cmd, args, timeoutMs, proc(output: string, code: int) =
    r.busy = false
    let cb = r.onDone
    if r.again:
      r.again = false
      r.run(r.cmd, r.args, r.timeoutMs, r.onDone)  # newest request wins
    else:
      discard
    try: cb(output, code)
    except CatchableError as e: stderr.writeLine "runner callback error: ", e.msg)

proc busy*(r: Runner): bool = r.busy

# Long-running children get SIGKILL if we die (even by SIGKILL), via util-linux setpriv.
# pactl ignores SIGPIPE, so otherwise an orphaned `pactl subscribe` would live forever.
let setprivExe = findExe("setpriv")

proc spawnStream(cmd: string, args: seq[string]): Process =
  if setprivExe != "":
    spawn(setprivExe, @["--pdeathsig", "KILL", "--", cmd] & args)
  else:
    spawn(cmd, args)

proc killChildren*() =
  ## Kill and reap every child we spawned (call on exit and before re-exec).
  for p in streamProcs & runProcs:
    try:
      p.kill()
      discard p.waitForExit()
    except CatchableError: discard
  streamProcs.setLen(0)
  runProcs.setLen(0)

proc streamLines*(cmd: string, args: seq[string], onLine: proc(line: string) {.closure.}) =
  ## Long-running child; calls onLine per stdout line. Restarts with backoff if it dies.
  var
    backoffMs = 500
    p: Process
    pending: string
    junk: string
    startedAt: MonoTime
    launch: proc() {.closure.}

  proc died(outFd: cint) =
    unwatchFd(outFd.int)
    try:
      p.kill()
      discard p.waitForExit()
      p.close()
      let i = streamProcs.find(p)
      if i >= 0: streamProcs.delete(i)
    except CatchableError: discard
    pending = ""
    if getMonoTime() - startedAt > initDuration(seconds = 10):
      backoffMs = 500
    discard after(backoffMs, launch)
    backoffMs = min(backoffMs * 2, 30_000)

  launch = proc() =
    try:
      p = spawnStream(cmd, args)
    except CatchableError:
      discard after(backoffMs, launch)
      backoffMs = min(backoffMs * 2, 30_000)
      return
    startedAt = getMonoTime()
    streamProcs.add p
    let outFd = p.outputHandle.cint
    let errFd = p.errorHandle.cint
    watchFd(outFd.int, proc() =
      discard drain(errFd, junk, false)
      var chunk: string
      let eof = drain(outFd, chunk, true)
      pending.add chunk
      var nl = pending.find('\n')
      while nl >= 0:
        let line = pending[0 ..< nl]
        pending = pending[nl + 1 .. ^1]
        try: onLine(line)
        except CatchableError as e: stderr.writeLine "stream callback error: ", e.msg
        nl = pending.find('\n')
      if eof:
        died(outFd))
  launch()
