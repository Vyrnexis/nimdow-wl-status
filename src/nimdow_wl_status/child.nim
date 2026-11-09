## fork/exec of `sh -c`, killed with us (PR_SET_PDEATHSIG), line reader, timeout.
import std/[posix, strutils]
import loop

type Child* = ref object
  pid: Pid
  rfd, wfd: cint                    ## our end of its stdout / stdin
  buf: string
  killTimer: Deadline
  timedOut, done: bool
  onLine: proc(line: string)
  onExit: proc(code: int)           ## exit status; -1 = killed / timed out / spawn failed

var live: seq[Child]

proc prctl(option: cint, arg: culong): cint {.importc, header: "<sys/prctl.h>".}
proc cexit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

proc kill*(c: Child) =
  ## SIGKILL its whole process group.
  if not c.done:
    discard posix.kill(-c.pid, SIGKILL)
    discard posix.kill(c.pid, SIGKILL)

proc killAll*() =
  for c in live: c.kill()

proc reap(c: Child) =
  var st: cint
  let r = waitpid(c.pid, st, WNOHANG)
  if r == 0:                        # closed its stdout but still running
    discard after(100, proc() = reap(c))
    return
  c.done = true
  cancel(c.killTimer)
  live.delete(live.find(c))
  c.onExit(if r < 0 or c.timedOut or not WIFEXITED(st): -1 else: WEXITSTATUS(st).int)

proc eof(c: Child) =
  unwatch(c.rfd)
  discard close(c.rfd)
  if c.wfd >= 0: discard close(c.wfd)
  if c.buf != "": c.onLine(c.buf)
  reap(c)

proc readable(c: Child) =
  var b: array[4096, char]
  while true:
    let n = read(c.rfd, addr b[0], b.len)
    if n > 0:
      let old = c.buf.len
      c.buf.setLen(old + n)
      copyMem(addr c.buf[old], addr b[0], n)
    elif n == 0 or (errno != EAGAIN and errno != EINTR):
      eof(c)
      return
    else: break
  var start = 0
  while true:
    let i = c.buf.find('\n', start)
    if i < 0: break
    c.onLine(if i > start and c.buf[i - 1] == '\r': c.buf[start ..< i - 1] else: c.buf[start ..< i])
    start = i + 1
  c.buf = c.buf[start .. ^1]
  if c.buf.len > 65536: c.buf = ""

proc spawn*(cmd, dir: string, guard: bool, timeoutMs: int,
            onLine: proc(line: string), onExit: proc(code: int)): Child =
  ## Run `sh -c cmd` in `dir`. stdout lines go to onLine. With `guard` its stdin is a pipe
  ## that hits EOF when we die (a script can `cat >/dev/null; kill 0` to take its helpers
  ## down: PDEATHSIG only covers the shell itself); otherwise stdin is at EOF at once.
  let c = Child(onLine: onLine, onExit: onExit, wfd: -1)
  result = c
  var o, i: array[2, cint]
  if pipe(o) != 0: discard
  elif pipe(i) != 0: discard close(o[0]); discard close(o[1]); o[0] = -1
  if o[0] < 0:
    c.done = true
    discard after(0, proc() = onExit(-1))
    return
  for fd in [o[0], o[1], i[0], i[1]]: discard fcntl(fd, F_SETFD, FD_CLOEXEC)
  discard fcntl(o[0], F_SETFL, O_NONBLOCK)
  let argv = allocCStringArray(["sh", "-c", cmd])
  let parent = getpid()
  let pid = fork()
  if pid == 0:
    discard prctl(1, SIGKILL.culong)         # PR_SET_PDEATHSIG
    if getppid() != parent: cexit(1)
    discard setpgid(0, 0)
    var empty: Sigset
    discard sigemptyset(empty)
    discard sigprocmask(SIG_SETMASK, empty, empty)   # signalfd needs them blocked in the parent
    for sig in 1 .. 31: signal(sig.cint, SIG_DFL)
    discard dup2(i[0], 0)
    discard dup2(o[1], 1)
    if dir != "": discard chdir(dir.cstring)
    discard execv("/bin/sh", argv)
    cexit(127)
  deallocCStringArray(argv)
  discard close(o[1])
  discard close(i[0])
  if pid < 0:
    c.done = true
    discard close(o[0]); discard close(i[1])
    discard after(0, proc() = onExit(-1))
    return
  discard setpgid(pid, pid)
  c.pid = pid
  c.rfd = o[0]
  if guard: c.wfd = i[1] else: discard close(i[1])
  live.add c
  watch(o[0], proc() = readable(c))
  if timeoutMs > 0:
    c.killTimer = after(timeoutMs, proc() =
      c.timedOut = true
      c.kill())
