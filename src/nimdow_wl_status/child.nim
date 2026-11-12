## fork/exec of `sh -c`, killed with us (PR_SET_PDEATHSIG), line reader, timeout.
import std/[posix, strutils]
import loop

type Child* = ref object
  pid: Pid
  rfd, wfd, pfd: cint               ## our end of its stdout / stdin; its pidfd
  buf: string
  killTimer: Deadline
  timedOut, done: bool
  onLine: proc(line: string)
  onExit: proc(code: int)           ## exit status; -1 = killed / timed out / spawn failed

var live: seq[Child]

proc prctl(option: cint, arg: culong): cint {.importc, header: "<sys/prctl.h>".}
var SYS_pidfd_open {.importc, header: "<sys/syscall.h>".}: clong
proc syscall(n: clong): clong {.importc, header: "<unistd.h>", varargs.}
proc cexit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

proc kill*(c: Child) =
  ## SIGKILL its whole process group.
  if not c.done:
    discard posix.kill(-c.pid, SIGKILL)
    discard posix.kill(c.pid, SIGKILL)

proc killAll*() =
  for c in live: c.kill()

proc splitLines*(buf: var string, flush: bool, onLine: proc(line: string)) =
  ## Hand the complete lines in `buf` to onLine and keep the unterminated rest; with `flush`
  ## the rest goes too (EOF).
  var start = 0
  while true:
    let i = buf.find('\n', start)
    if i < 0: break
    onLine(if i > start and buf[i - 1] == '\r': buf[start ..< i - 1] else: buf[start ..< i])
    start = i + 1
  buf = buf[start .. ^1]
  if flush and buf != "": onLine(buf)
  if flush or buf.len > 65536: buf = ""

proc drain(c: Child, flush: bool) = splitLines(c.buf, flush, c.onLine)

proc pump(c: Child): bool =
  ## Read what is there into the buffer, then the lines. True at EOF.
  var b: array[4096, char]
  while true:
    let n = read(c.rfd, addr b[0], b.len)
    if n > 0:
      let old = c.buf.len
      c.buf.setLen(old + n)
      copyMem(addr c.buf[old], addr b[0], n)
    elif n == 0 or (errno != EAGAIN and errno != EINTR):
      result = true
      break
    else: break
  drain(c, result)

proc closeOut(c: Child) =
  unwatch(c.rfd)
  discard close(c.rfd)
  c.rfd = -1

proc exited(c: Child) =
  ## Its pidfd is readable: the process is gone. Collect it, take what is left in the pipe
  ## (a daemonised helper may still hold the write end), and report.
  var st: cint
  let r = waitpid(c.pid, st, WNOHANG)
  if r == 0: return                 # stale event for a reused fd number
  unwatch(c.pfd)
  discard close(c.pfd)
  if c.rfd >= 0:
    discard pump(c)
    drain(c, true)
    closeOut(c)
  if c.wfd >= 0: discard close(c.wfd)
  c.done = true
  cancel(c.killTimer)
  live.delete(live.find(c))
  c.onExit(if r < 0 or c.timedOut or not WIFEXITED(st): -1 else: WEXITSTATUS(st).int)

proc readable(c: Child) =
  if pump(c): closeOut(c)           # EOF: the exit follows through the pidfd

proc pidfdOpen(pid: Pid): cint =
  cint(syscall(SYS_pidfd_open, pid, 0))

proc spawn*(cmd, dir: string, guard: bool, timeoutMs: int,
            onLine: proc(line: string), onExit: proc(code: int)): Child =
  ## Run `sh -c cmd` in `dir`. stdout lines go to onLine. With `guard` its stdin is a pipe
  ## that hits EOF when we die (a script can `cat >/dev/null; kill 0` to take its helpers
  ## down: PDEATHSIG only covers the shell itself); otherwise stdin is at EOF at once.
  let c = Child(onLine: onLine, onExit: onExit, wfd: -1, rfd: -1, pfd: -1)
  result = c
  var o, i = [cint(-1), -1]
  proc fail(c: Child) =
    c.done = true
    discard after(0, proc() = onExit(-1))
  if pipe(o) != 0: o = [cint(-1), -1]
  elif pipe(i) != 0:
    discard close(o[0]); discard close(o[1])
    o = [cint(-1), -1]
  if o[0] < 0: (fail(c); return)
  for fd in [o[0], o[1], i[0], i[1]]: discard fcntl(fd, F_SETFD, FD_CLOEXEC)
  discard fcntl(o[0], F_SETFL, O_NONBLOCK)
  let argv = allocCStringArray(["sh", "-c", cmd])
  let parent = getpid()
  var st: cint
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
  c.pid = pid
  if pid < 0:
    discard close(o[0]); discard close(i[1])
    fail(c)
    return
  discard setpgid(pid, pid)
  c.pfd = pidfdOpen(pid)
  if c.pfd < 0:                     # no pidfd (kernel < 5.3): cannot track it, so do not run it
    c.kill()
    discard waitpid(pid, st, 0)
    discard close(o[0]); discard close(i[1])
    fail(c)
    return
  c.rfd = o[0]
  if guard: c.wfd = i[1] else: discard close(i[1])
  live.add c
  watch(c.pfd, proc() = exited(c))
  watch(o[0], proc() = readable(c))
  if timeoutMs > 0:
    c.killTimer = after(timeoutMs, proc() =
      c.timedOut = true
      c.kill())
