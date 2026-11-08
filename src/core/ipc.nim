## Direct transport to nimdow-wl's IPC socket (or stdout for dwl/somebar-style piping).
import std/[os, net, strutils, parseutils, times]
from std/posix import kill, Pid, errno, EPERM
import events

var
  useStdout* = false
  cachedPath = ""
  lastPath = ""        # socket path we last successfully sent to
  lastText = "\0"      # last text successfully delivered
  retryTimer: TimerId = 0

proc socketDir(): string =
  let rt = getEnv("XDG_RUNTIME_DIR")
  (if rt != "": rt else: "/tmp") / "nimdow-wl"

proc pidAlive(pid: int): bool =
  kill(Pid(pid), 0) == 0 or errno == EPERM

proc findSocket(): string =
  var best = ""
  var bestTime = fromUnix(0)
  for kind, path in walkDir(socketDir()):
    let name = path.extractFilename
    if not name.startsWith("ipc-socket."): continue
    var pid: int
    if parseInt(name["ipc-socket.".len .. ^1], pid) == 0 or not pidAlive(pid): continue
    let t = try: getLastModificationTime(path) except CatchableError: fromUnix(0)
    if best == "" or t > bestTime:
      best = path
      bestTime = t
  best

proc trySendTo(path, text: string): bool =
  var s: Socket
  try:
    s = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    s.connectUnix(path)
    result = s.trySend("nimdow-ipc status " & text)
  except CatchableError:
    result = false
  if s != nil:
    try: s.close() except CatchableError: discard

proc sendStatus*(text: string, force = false) =
  ## Deliver the bar text (only when changed, or force / WM socket changed).
  if useStdout:
    if text != lastText or force:
      lastText = text
      try:
        stdout.write text, "\n"
        stdout.flushFile()
      except IOError:
        quit(0)  # reader went away
    return
  if retryTimer != 0:
    cancel(retryTimer)
    retryTimer = 0
  if text == lastText and not force and cachedPath != "" and cachedPath == lastPath:
    return
  var path = cachedPath
  var ok = false
  if path != "":
    ok = trySendTo(path, text)
  if not ok:
    path = findSocket()          # connect failed or nothing cached: rescan
    cachedPath = path
    if path != "":
      ok = trySendTo(path, text)
  if ok:
    lastPath = path
    lastText = text
  else:
    cachedPath = ""
    lastText = "\0"
    retryTimer = after(2000, proc() =
      retryTimer = 0
      sendStatus(text, true))
