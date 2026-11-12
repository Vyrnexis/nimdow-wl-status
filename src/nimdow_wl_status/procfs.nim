## Re-read a /proc file through one long-lived fd (a single pread per read).
import std/posix

proc slurp*(fd: var cint, path: string, buf: var string): int =
  ## `fd` starts at -1. Reads up to buf.len bytes from the start of `path`; -1 on error (the fd is dropped).
  if fd < 0:
    fd = open(path.cstring, O_RDONLY or O_CLOEXEC)
    if fd < 0: return -1
  result = pread(fd, addr buf[0], buf.len, 0)
  if result < 0: (discard close(fd); fd = -1)
