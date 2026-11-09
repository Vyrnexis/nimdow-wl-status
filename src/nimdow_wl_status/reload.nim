## Config reload: inotify on the config dir, then validate, then re-exec.
import std/[os, posix, inotify, strutils, tables]
import loop, child

proc watchConfig*(path: string, onChange: proc() {.closure.}) =
  ## Calls onChange (debounced) when `path` is written, created or renamed into place.
  let fd = inotify_init1(O_NONBLOCK or O_CLOEXEC)
  if fd < 0: return
  var names: Table[cint, string]            # watch descriptor -> file name to react to
  var paths = @[absolutePath(path)]
  try:                                      # symlinked config: edits land in the target's dir
    if symlinkExists(paths[0]): paths.add expandFilename(paths[0])
  except CatchableError: discard
  for p in paths:
    let wd = inotify_add_watch(fd, cstring(parentDir(p)), uint32(IN_CLOSE_WRITE or IN_MOVED_TO or IN_CREATE or IN_DELETE))
    if wd >= 0: names[wd] = extractFilename(p)
  var debounce: Deadline
  watch(fd, proc() =
    var buf: array[4096, byte]
    var hit = false
    while true:
      let n = read(fd, addr buf[0], buf.len)
      if n <= 0: break
      var off = 0
      while off + sizeof(InotifyEvent) <= n:
        let ev = cast[ptr InotifyEvent](addr buf[off])
        let name = if ev.len > 0: $cast[cstring](addr buf[off + sizeof(InotifyEvent)]) else: ""
        if ev.wd in names and name == names[ev.wd]: hit = true
        off += sizeof(InotifyEvent) + ev.len.int
    if hit:
      cancel(debounce)
      debounce = after(200, onChange))

proc reexec*() =
  ## Replace this process with a fresh copy (same argv). Children go first: PDEATHSIG does
  ## not fire on exec.
  killAll()
  var fds: seq[cint]
  for _, p in walkDir("/proc/self/fd"):
    try: fds.add cint(parseInt(p.extractFilename)) except ValueError: discard
  for fd in fds:
    if fd > 2: discard fcntl(fd, F_SETFD, FD_CLOEXEC)
  let argv = allocCStringArray(@[paramStr(0)] & commandLineParams())
  # The real path, not /proc/self/exe: the process name comes from the exec'd path. After a
  # rebuild readlink ends in " (deleted)": run the new binary.
  var path = getAppFilename()
  if path.endsWith(" (deleted)"): path.setLen(path.len - " (deleted)".len)
  discard execv(path.cstring, argv)
  stderr.writeLine "error: re-exec failed: ", strerror(errno)
  deallocCStringArray(argv)
