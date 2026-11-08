## Signals delivered through a self-pipe so they can be polled by the selector.
import std/posix
import events

var wfd: cint = -1

proc libcSigRtMin(): cint {.importc: "__libc_current_sigrtmin", header: "<signal.h>".}

proc sigRtMin*(): cint = libcSigRtMin()

proc handler(sig: cint) {.noconv.} =
  var b = char(sig)
  let saved = errno
  discard write(wfd, addr b, 1)
  errno = saved

proc noopHandler(sig: cint) {.noconv.} = discard

proc installSignals*(sigs: seq[cint], onSignal: proc(sig: cint) {.closure.}) =
  var fds: array[2, cint]
  if pipe(fds) != 0: return
  for fd in fds:
    discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
  wfd = fds[1]
  let rfd = fds[0]
  # A no-op handler, not SIG_IGN: ignored signals are inherited across exec, which
  # would stop children (pactl subscribe) dying of SIGPIPE when we go away.
  signal(SIGPIPE, noopHandler)
  for s in sigs:
    signal(s, handler)
  watchFd(rfd.int, proc() =
    var buf: array[64, char]
    while true:
      let n = read(rfd, addr buf[0], buf.len)
      if n <= 0: break
      for i in 0 ..< n:
        onSignal(cint(buf[i])))
