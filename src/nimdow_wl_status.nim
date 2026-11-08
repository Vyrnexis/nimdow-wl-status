###########
# Imports
# #########
import std/[os, monotimes, times, posix, strutils]
# Core function for nimdow-wl-status
import core/[segment, events, ipc, signals, reconnect, procs, config, reload]

# Parameters:
# --stdout        print each new status as one line on stdout instead of sending it to nimdow-wl
# --config <path> use this config file (default $XDG_CONFIG_HOME/nimdow-wl/status.toml,
#                 else the built-in default, see config.default.toml)
# --check-config  parse and validate the config, print problems, exit 0 (ok) / 1 (errors)
# Signals:
# SIGUSR1 refresh everything, SIGRTMIN+N refresh segment N (1-based), SIGHUP reload the config,
# SIGTERM/SIGINT exit

###################
# Config
###################
var
  configPath = defaultConfigPath()
  explicitConfig = false
  checkOnly = false
  currentText = ""        # text of the config file this process was started with

block parseArgs:
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--stdout": useStdout = true
    elif a == "--check-config": checkOnly = true
    elif a == "--config" or a.startsWith("--config="):
      if a == "--config":
        inc i
        if i >= args.len:
          stderr.writeLine "--config needs a path"
          quit(2)
        configPath = args[i]
      else:
        configPath = a["--config=".len .. ^1]
      explicitConfig = true
    inc i
  configPath = expandTilde(configPath)

proc report(l: Loaded, origin: string) =
  for w in l.warnings: stderr.writeLine "warning: ", w
  for e in l.errors: stderr.writeLine "error: ", e

proc readConfig(text: var string): bool =
  ## False if the file exists but cannot be read.
  text = ""
  if not fileExists(configPath): return true
  try:
    text = readFile(configPath)
  except CatchableError as e:
    stderr.writeLine "error: cannot read ", configPath, ": ", e.msg
    return false
  true

if checkOnly:
  var text: string
  var l: Loaded
  if not readConfig(text):
    quit(1)
  if fileExists(configPath):
    l = parseConfig(text, configPath)
  elif explicitConfig:
    stderr.writeLine "error: config file not found: ", configPath
    quit(1)
  else:
    echo "no config file at ", configPath, "; the built-in default would be used"
    l = builtinDefault()
  l.report(configPath)
  if l.errors.len > 0:
    stderr.writeLine configPath, ": ", l.errors.len, " error(s)"
    quit(1)
  echo configPath, ": ok (", l.segments.len, " segments, ", l.warnings.len, " warning(s))"
  quit(0)

proc startupConfig(): seq[Segment] =
  var text: string
  var l: Loaded
  var haveFile = readConfig(text) and fileExists(configPath)
  if haveFile:
    l = parseConfig(text, configPath)
    l.report(configPath)
    currentText = text
    if l.errors.len > 0:
      stderr.writeLine "error: invalid config ", configPath, ", using the built-in default"
      l = builtinDefault()
  else:
    if explicitConfig:
      stderr.writeLine "warning: config file not found: ", configPath, ", using the built-in default"
    l = builtinDefault()
  l.segments

let
  ###################
  # Status Bar setup
  ###################
  ## The segment list comes from the config file (see config.default.toml).
  segments = startupConfig()

###################
# Event loop
# #################
var quit = false

proc reexec() =
  ## Replace this process with a fresh copy of itself (same argv) to pick up a new config.
  killChildren()   # includes `pactl subscribe`, which would otherwise outlive the exec
  # Mark every inherited fd close-on-exec (selector, inotify, self-pipe, child pipes);
  # not closed, so we keep working if exec fails.
  var fds: seq[cint]
  for kind, p in walkDir("/proc/self/fd"):
    try: fds.add cint(parseInt(p.extractFilename))
    except ValueError: discard
  for fd in fds:
    if fd > 2: discard fcntl(fd, F_SETFD, FD_CLOEXEC)
  let argv = allocCStringArray(@[paramStr(0)] & commandLineParams())
  discard execv("/proc/self/exe", argv)
  stderr.writeLine "error: re-exec failed: ", strerror(errno)
  deallocCStringArray(argv)

proc tryReload(force: bool) =
  ## Validate the config on disk first; only a valid one restarts the process.
  var text: string
  if not readConfig(text): return
  if not force and text == currentText: return   # unchanged (duplicate events, touch)
  let exists = fileExists(configPath)
  let l = if exists: parseConfig(text, configPath) else: builtinDefault()
  l.report(configPath)
  if l.errors.len > 0:
    stderr.writeLine "error: config ", configPath, " is invalid, keeping the current configuration"
    return
  stderr.writeLine "config changed, reloading"
  reexec()

proc barText(): string =
  for s in segments:
    result &= s.text

proc flush(force = false) =
  if barDirty or force:
    barDirty = false
    sendStatus(barText(), force)

proc refreshAll() =
  for s in segments:
    s.refreshNow()
    s.reschedule()

for i, s in segments:
  s.index = i + 1

var sigs = @[SIGUSR1, SIGTERM, SIGINT, SIGHUP]
for i in 1 .. segments.len:
  if sigRtMin() + cint(i) <= 64: sigs.add sigRtMin() + cint(i)  # 64 = SIGRTMAX on Linux
installSignals(sigs, proc(sig: cint) =
  if sig == SIGTERM or sig == SIGINT:
    quit = true
  elif sig == SIGHUP:
    tryReload(force = true)
  elif sig == SIGUSR1:
    refreshAll()
    flush(force = true)
  else:
    let i = int(sig - sigRtMin())
    if i >= 1 and i <= segments.len:
      segments[i - 1].refreshNow()
      segments[i - 1].reschedule()
      flush())

discard watchConfigFile(configPath, proc() = tryReload(force = false))

initConnectChecker(proc() =
  refreshAll()
  flush())

for s in segments:
  s.startSegment()
  s.reschedule()
flush(force = true)

while not quit:
  # sleep until the earliest segment or timer is due; no fixed tick
  var hasDue = false
  var due: MonoTime
  for s in segments:
    if s.hasDue and (not hasDue or s.nextDue < due):
      hasDue = true
      due = s.nextDue
  let (hasTimer, timerDue) = earliestTimer()
  if hasTimer and (not hasDue or timerDue < due):
    hasDue = true
    due = timerDue
  var timeout = -1
  if hasDue:
    let ns = (due - getMonoTime()).inNanoseconds
    timeout = if ns <= 0: 0 else: int((ns + 999_999) div 1_000_000)
  pollFds(timeout)
  runTimers()
  let now = getMonoTime()
  for s in segments:
    if s.hasDue and s.nextDue <= now:
      s.refreshNow()
      s.reschedule()
  flush()

killChildren()
