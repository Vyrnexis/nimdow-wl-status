## Config reload: inotify on the config dir, then validate, then re-exec.
import std/[os, posix, inotify, strutils, tables]
import loop, child

proc watchConfig*(path: string, onChange: proc() {.closure.}) =
  ## Calls onChange (debounced) when `path` is written, created or renamed into place. If
  ## its directory does not exist yet, the parent is watched until the directory appears.
  let fd = inotify_init1(O_NONBLOCK or O_CLOEXEC)
  if fd < 0:
    stderr.writeLine "warning: inotify unavailable, config changes need SIGHUP"
    return
  var names: Table[cint, string]            # watch descriptor -> name to react to
  var paths = @[absolutePath(path)]
  try:                                      # symlinked config: edits land in the target's dir
    if symlinkExists(paths[0]): paths.add expandFilename(paths[0])
  except CatchableError: discard
  proc add(p: string) =
    let dir = parentDir(p)
    var wd = inotify_add_watch(fd, cstring(dir), uint32(IN_CLOSE_WRITE or IN_MOVED_TO or IN_CREATE or IN_DELETE))
    if wd >= 0: (names[wd] = extractFilename(p); return)
    # No such directory: wait for it in its parent.
    wd = inotify_add_watch(fd, cstring(parentDir(dir)), uint32(IN_CREATE or IN_MOVED_TO))
    if wd >= 0: names[wd] = "/" & extractFilename(dir)    # "/": a directory to enter
    else: stderr.writeLine "warning: cannot watch ", dir, " for config changes: ", strerror(errno)
  for p in paths: add p
  var debounce: Deadline
  watch(fd, proc() =
    var hit = false
    readEvents(fd, proc(wd: cint, mask: uint32, name: string) =
      if wd notin names or name == "": return
      if names[wd][0] == '/':
        if name == names[wd][1 .. ^1]:       # the directory appeared: watch it, check the file
          names.del wd
          discard inotify_rm_watch(fd, wd)
          for p in paths: add p
          hit = true
      elif name == names[wd]: hit = true)
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
