## Transport: nimdow-wl's IPC socket (`nimdow-ipc status <text>`), or lines on stdout.
import std/[os, net, strutils, parseutils, times]
from std/posix import kill, Pid, errno, EPERM
import loop

var
  useStdout* = false
  cachedPath, lastPath = ""          # socket we resolved / last delivered to
  lastText = "\0"                    # last text delivered
  retry: Deadline

proc findSocket(): string =
  ## Newest socket whose owning pid is alive.
  let rt = getEnv("XDG_RUNTIME_DIR")
  var bestTime = fromUnix(0)
  for _, path in walkDir((if rt != "": rt else: "/tmp") / "nimdow-wl"):
    let name = path.extractFilename
    var pid: int
    if not name.startsWith("ipc-socket.") or parseInt(name[11 .. ^1], pid) == 0: continue
    if kill(Pid(pid), 0) != 0 and errno != EPERM: continue
    let t = try: getLastModificationTime(path) except CatchableError: fromUnix(0)
    if result == "" or t > bestTime: (result = path; bestTime = t)

proc trySendTo(path, text: string): bool =
  var s: Socket
  try:
    s = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    s.connectUnix(path)
    result = s.trySend("nimdow-ipc status " & text)
  except CatchableError: result = false
  if s != nil:
    try: s.close() except CatchableError: discard

proc sendStatus*(text: string, force = false) =
  ## Deliver only on change (or force / the WM socket changed); retry every 2s while the WM is down.
  if useStdout:
    if text != lastText or force:
      lastText = text
      try: stdout.write text, "\n"; stdout.flushFile()
      except IOError: quit(0)       # reader went away
    return
  cancel(retry)
  if text == lastText and not force and cachedPath != "" and cachedPath == lastPath: return
  var ok = cachedPath != "" and trySendTo(cachedPath, text)
  if not ok:
    cachedPath = findSocket()
    ok = cachedPath != "" and trySendTo(cachedPath, text)
  if ok:
    lastPath = cachedPath
    lastText = text
  else:
    cachedPath = ""
    lastText = "\0"
    retry = after(2000, proc() = sendStatus(text, true))
