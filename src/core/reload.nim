## Watch the config file's directory with inotify; coalesces bursts (editors that
## write via rename or in several steps) into one callback.
import std/[os, posix, inotify, tables]
import events

proc watchConfigFile*(path: string, onChange: proc() {.closure.}, debounceMs = 200): bool =
  ## Returns false if nothing could be watched (e.g. the directory does not exist).
  let fd = inotify_init1(O_NONBLOCK or O_CLOEXEC)
  if fd < 0: return false
  let mask = uint32(IN_CLOSE_WRITE or IN_MOVED_TO or IN_MOVED_FROM or IN_CREATE or IN_DELETE)
  var names = initTable[cint, string]()   # watch descriptor -> file name to react to

  proc add(p: string) =
    let wd = inotify_add_watch(fd, cstring(parentDir(p)), mask)
    if wd >= 0: names[wd] = extractFilename(p)

  let abs = absolutePath(path)
  add(abs)
  # a symlinked config (dotfile managers): edits land in the target's directory
  try:
    if symlinkExists(abs):
      let target = expandFilename(abs)
      if target != abs: add(target)
  except CatchableError: discard
  if names.len == 0:
    discard close(fd)
    return false

  var debounce: TimerId = 0
  watchFd(fd.int, proc() =
    var buf: array[4096, byte]
    var hit = false
    while true:
      let n = read(fd, addr buf[0], buf.len)
      if n <= 0: break
      var off = 0
      while off + sizeof(InotifyEvent) <= n:
        let ev = cast[ptr InotifyEvent](addr buf[off])
        let nameLen = ev.len.int
        let name = if nameLen > 0: $cast[cstring](addr buf[off + sizeof(InotifyEvent)]) else: ""
        if ev.wd in names and name == names[ev.wd]: hit = true
        off += sizeof(InotifyEvent) + nameLen
    if hit:
      if debounce != 0: cancel(debounce)
      debounce = after(debounceMs, proc() =
        debounce = 0
        onChange()))
  true
