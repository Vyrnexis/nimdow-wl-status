import std/[strutils]
import ../core/[segment]

const
  MEMINFO_PATH: string = "/proc/meminfo"
  GIB_DIVISOR: float = 1024.0 * 1024.0
  MIB_DIVISOR: int = 1024

proc memoryHooks*(useAvailable: bool, decimals: int): Hooks =
  ## useAvailable = false: htop's formula; true: MemTotal - MemAvailable.
  result.body = proc(s: Segment): string =
    var iMemTotal, iMemFree, iBuffers, iCached, iShmem, iSReclaimable, iAvailable: int
    # One pass over /proc/meminfo, parsing every needed key
    for line in lines(MEMINFO_PATH):
      let c = line.find(':')
      if c < 0: continue
      let key = line[0 ..< c]
      var target: ptr int
      case key
      of "MemTotal": target = addr iMemTotal
      of "MemFree": target = addr iMemFree
      of "Buffers": target = addr iBuffers
      of "Cached": target = addr iCached
      of "Shmem": target = addr iShmem
      of "SReclaimable": target = addr iSReclaimable
      of "MemAvailable": target = addr iAvailable
      else: continue
      target[] = line[c + 1 .. ^1].strip().split()[0].parseInt()
    let iUsedMem =
      if useAvailable: iMemTotal - iAvailable
      else: iMemTotal - (iMemFree + iBuffers + iCached) + (iShmem - iSReclaimable)  # htop
    if iUsedMem >= 1048576: # Check to see if used mem is 1GB or greater
      result = formatFloat(iUsedMem.float / GIB_DIVISOR, ffDecimal, decimals) & " GiB"
    else:
      result = $(iUsedMem div MIB_DIVISOR) & " MiB"
