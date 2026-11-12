## Transport: nimdow-wl's IPC socket (`nimdow-ipc status <text>`), or lines on stdout.
import std/[os, strutils, parseutils, times, posix, inotify]
import loop

const Prefix = "ipc-socket."

var
  useStdout* = false
  cachedPath = ""                    # socket in use
  lastText = "\0"                    # last text delivered ("\0": nothing, resend at once)
  wanted = ""                        # the current text, for a socket that appears later
  resend: Deadline
  ifd = cint(-1)
  dirWd, parentWd = cint(-1)

proc socketDir(): string =
  ## Where nimdow-wl keeps its sockets (it tests the variable with existsEnv).
  if existsEnv("XDG_RUNTIME_DIR"): getEnv("XDG_RUNTIME_DIR") / "nimdow-wl"
  else: "/tmp/nimdow-wl-" & $getuid()

proc findSocket(): string =
  ## Newest socket whose owning pid is alive.
  var bestTime = fromUnix(0)
  for _, path in walkDir(socketDir()):
    let name = path.extractFilename
    var pid: int
    if not name.startsWith(Prefix) or parseInt(name[Prefix.len .. ^1], pid) == 0: continue
    if kill(Pid(pid), 0) != 0 and errno != EPERM: continue
    let t = try: getLastModificationTime(path) except CatchableError: fromUnix(0)
    if result == "" or t > bestTime: (result = path; bestTime = t)

proc trySendTo(path, text: string): bool =
  ## Never blocks for long: connect and send give up after a few ms (SO_SNDTIMEO).
  if path.len >= Sockaddr_un_path_length: return false
  let fd = socket(AF_UNIX, SOCK_STREAM or SOCK_CLOEXEC, 0)
  if cint(fd) < 0: return false
  var tv = Timeval(tv_sec: posix.Time(0), tv_usec: 5000)
  discard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, addr tv, SockLen(sizeof(tv)))
  var sa: Sockaddr_un
  sa.sun_family = TSa_Family(AF_UNIX)
  copyMem(addr sa.sun_path[0], path.cstring, path.len)
  if connect(fd, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa))) == 0:
    let msg = "nimdow-ipc status " & text
    var off = 0
    result = true
    while off < msg.len:
      let n = send(fd, unsafeAddr msg[off], msg.len - off, MSG_NOSIGNAL)
      if n > 0: off += n
      elif n < 0 and errno == EINTR: continue
      else: (result = false; break)
  discard close(cint(fd))

proc sendStatus*(text: string, force = false) =
  ## Deliver only on change (or `force`). A failed send (no WM, or it died) forgets what was
  ## delivered and waits: the next new socket resends, as does the next change.
  wanted = text
  if text == lastText and not force: return
  if useStdout:
    lastText = text
    try: stdout.write text, "\n"; stdout.flushFile()
    except IOError: quit(0)         # reader went away
    return
  var ok = cachedPath != "" and trySendTo(cachedPath, text)
  if not ok:
    cachedPath = findSocket()
    ok = cachedPath != "" and trySendTo(cachedPath, text)
  if ok: lastText = text
  else:
    cachedPath = ""
    lastText = "\0"

proc watchSockets() =
  ## (Re)add the inotify watch on the socket dir, or on its parent until the dir exists.
  let dir = socketDir()
  dirWd = inotify_add_watch(ifd, cstring(dir), uint32(IN_CREATE))
  if dirWd >= 0:
    if parentWd >= 0: (discard inotify_rm_watch(ifd, parentWd); parentWd = -1)
  elif parentWd < 0:
    parentWd = inotify_add_watch(ifd, cstring(parentDir(dir)), uint32(IN_CREATE or IN_MOVED_TO))
    if parentWd >= 0: watchSockets()      # the dir may have appeared meanwhile

proc watchWm*() =
  ## A new `ipc-socket.<pid>` means nimdow-wl (re)started: resend the current text then
  ## (after a short wait, so it is listening). No polling.
  ifd = inotify_init1(O_NONBLOCK or O_CLOEXEC)
  if ifd < 0:
    stderr.writeLine "warning: inotify unavailable, a nimdow-wl restart is noticed at the next change"
    return
  watchSockets()
  let dirName = extractFilename(socketDir())
  watch(ifd, proc() =
    var hit = false
    readEvents(ifd, proc(wd: cint, mask: uint32, name: string) =
      if (mask and uint32(IN_IGNORED)) != 0 and wd == dirWd: (dirWd = -1; watchSockets())
      elif wd == parentWd and name == dirName: (watchSockets(); hit = true)
      elif wd == dirWd and name.startsWith(Prefix): hit = true)
    if hit:
      cancel(resend)
      resend = after(50, proc() =
        cachedPath = ""
        sendStatus(wanted, true)))
