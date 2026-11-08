import std/[os, strutils, posix, inotify]
import ../core/[segment, events, procs]

const
  PACMAN_DIR = "/var/lib/pacman"
  LOCK_NAME = "db.lck"

proc archUpdatesHooks*(okColor, busyColor, updatingText: string, timeoutMs: int): Hooks =
  ## okColor / busyColor are colour escape codes (see hexColorToEscapeCode).
  let runner = newRunner()
  var locked = false

  proc showUpdating(s: Segment) =
    locked = true
    s.color = busyColor
    s.setBody(updatingText)

  proc checkNow(s: Segment) =
    ## Async checkupdates: exit 2 = nothing to update, other non-zero = failure.
    if fileExists(PACMAN_DIR / LOCK_NAME):
      s.showUpdating()
      return
    locked = false
    s.color = okColor
    runner.run("checkupdates", @[], timeoutMs, proc(output: string, code: int) =
      if locked: return  # an upgrade started meanwhile; the lock release re-checks
      s.color = okColor
      var text: string
      if code == 2:
        text = "0"
      elif code != 0:
        text = "N/A"
      else:
        var n = 0
        for line in output.splitLines():
          if line.strip() != "": inc n
        text = if n == 0: "0" else: "Updates: " & $n
      s.setBody(text))

  proc watchLock(s: Segment) =
    let fd = inotify_init1(O_NONBLOCK or O_CLOEXEC)
    if fd >= 0 and inotify_add_watch(fd, PACMAN_DIR, IN_CREATE or IN_DELETE or IN_MOVED_TO or IN_MOVED_FROM) >= 0:
      watchFd(fd.int, proc() =
        var buf: array[4096, byte]
        while true:
          let n = read(fd, addr buf[0], buf.len)
          if n <= 0: break
          var off = 0
          while off + sizeof(InotifyEvent) <= n:
            let ev = cast[ptr InotifyEvent](addr buf[off])
            let nameLen = ev.len.int
            let name = if nameLen > 0: $cast[cstring](addr buf[off + sizeof(InotifyEvent)]) else: ""
            if name == LOCK_NAME:
              if (ev.mask and (IN_CREATE or IN_MOVED_TO)) != 0:
                s.showUpdating()
              elif (ev.mask and (IN_DELETE or IN_MOVED_FROM)) != 0:
                checkNow(s)
            off += sizeof(InotifyEvent) + nameLen)
    else:
      # Fallback: poll the lock file
      if fd >= 0: discard close(fd)
      var poll: proc() {.closure.}
      poll = proc() =
        let has = fileExists(PACMAN_DIR / LOCK_NAME)
        if has and not locked: s.showUpdating()
        elif not has and locked: checkNow(s)
        discard after(2000, poll)
      discard after(2000, poll)

  result.start = proc(s: Segment) =
    watchLock(s)
    checkNow(s)
  result.refresh = proc(s: Segment) =
    checkNow(s)
