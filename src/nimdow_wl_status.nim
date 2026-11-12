## nimdow-wl-status: optional status feeder for nimdow-wl. See README.md and docs/DESIGN.md.
##   --stdout        print each new status line instead of sending it to nimdow-wl
##   --config <path> config file (default $XDG_CONFIG_HOME/nimdow-wl/status.toml, else the first
##                   nimdow-wl/status.toml in $XDG_CONFIG_DIRS (default /etc/xdg), copied to the
##                   user path on first run, else the built-in default)
##   --check-config  validate the config, print problems, exit 0 (ok) / 1 (errors)
##   -h, --help      print this usage
## Signals: SIGUSR1 rerun all, SIGRTMIN+N rerun segment N, SIGHUP reload, SIGTERM/SIGINT exit.
import std/[os, posix, strutils]
import nimdow_wl_status/[config, loop, child, ipc, reload]
import nimdow_wl_status/modules/[datetime, memory, cpu, battery, net, command]

const Usage = """usage: nimdow-wl-status [--stdout] [--config <file>] [--check-config] [-h|--help]
  --stdout          print each new status line instead of sending it to nimdow-wl
  --config <file>   config file (default ~/.config/nimdow-wl/status.toml)
  --check-config    validate the config, print problems, exit 0 (ok) / 1 (errors)
  -h, --help        this help"""

var
  configPath = getConfigDir() / "nimdow-wl" / "status.toml"
  explicitConfig, checkOnly = false
  running = ""                     # text of the config this process runs

block parseArgs:
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--stdout": useStdout = true
    elif a == "--check-config": checkOnly = true
    elif a == "-h" or a == "--help": (echo Usage; quit(0))
    elif a == "--config" or a.startsWith("--config="):
      if a == "--config":
        inc i
        if i >= args.len: (stderr.writeLine "--config needs a path"; quit(2))
        configPath = args[i]
      else: configPath = a[9 .. ^1]
      explicitConfig = true
    else: (stderr.writeLine("unknown argument: ", a, "\n", Usage); quit(2))
    inc i
  configPath = expandTilde(configPath)

proc systemConfig(): string =
  ## First nimdow-wl/status.toml in $XDG_CONFIG_DIRS (default /etc/xdg), or "".
  var dirs = getEnv("XDG_CONFIG_DIRS")
  if dirs == "": dirs = "/etc/xdg"
  for d in dirs.split(':'):
    if d == "": continue
    let f = d / "nimdow-wl" / "status.toml"
    if fileExists(f): return f

block firstRun:
  ## No --config and no user file: use the system-wide config (installed by the desktop
  ## package). It is copied to the user path (never overwriting) unless only checking; if the
  ## copy fails the system file is used as is. With no system file the built-in default is used
  ## and nothing is written.
  if explicitConfig or fileExists(configPath): break firstRun
  let sys = systemConfig()
  if sys == "": break firstRun
  if checkOnly:
    configPath = sys
    break firstRun
  try:
    createDir(parentDir(configPath))
    copyFile(sys, configPath)
    stderr.writeLine "copied ", sys, " to ", configPath
  except CatchableError as e:
    stderr.writeLine "warning: cannot copy ", sys, " to ", configPath, ": ", e.msg, ", using ", sys
    configPath = sys

proc readConfig(text: var string): bool =
  ## False if the file exists but cannot be read. `text` stays "" when there is no file.
  text = ""
  try:
    if fileExists(configPath): text = readFile(configPath)
    result = true
  except CatchableError as e:
    stderr.writeLine "error: cannot read ", configPath, ": ", e.msg

proc load(text: string): Loaded =
  ## The file's config, or the built-in default when there is no file or it is empty.
  result = loadConfig(if text.strip != "": text else: DefaultConfig, configPath)
  for w in result.warnings: stderr.writeLine "warning: ", w
  for e in result.errors: stderr.writeLine "error: ", e

if checkOnly:
  var text: string
  if not readConfig(text): quit(1)
  if explicitConfig and not fileExists(configPath):
    stderr.writeLine "error: config file not found: ", configPath
    quit(1)
  let l = load(text)
  if l.errors.len > 0:
    stderr.writeLine configPath, ": ", l.errors.len, " error(s)"
    quit(1)
  echo configPath, ": ok (", l.cfg.segs.len, " segments, ", l.warnings.len, " warning(s))"
  quit(0)

proc replaceOlder() =
  ## One feeder per user: stop an older one (e.g. left over from a previous login, as
  ## it is no Wayland client and outlives the session) and record our pid.
  let rt = getEnv("XDG_RUNTIME_DIR")
  let pidFile = if rt != "": rt / "nimdow-wl-status.pid" else: "/tmp/nimdow-wl-status-" & $getuid() & ".pid"
  let old = try: parseInt(readFile(pidFile).strip) except CatchableError: 0
  if old > 0 and old != getpid().int and
      (try: readFile("/proc/" & $old & "/comm").strip == "nimdow-wl-statu" except CatchableError: false):
    if kill(Pid(old), SIGTERM) == 0:
      var alive = true
      for _ in 1 .. 50:                # up to 1 s, then force
        if kill(Pid(old), 0) != 0: (alive = false; break)
        sleep 20
      if alive: discard kill(Pid(old), SIGKILL)
  try: writeFile(pidFile, $getpid())
  except CatchableError as e: stderr.writeLine "warning: cannot write ", pidFile, ": ", e.msg

if not useStdout: replaceOlder()

var segs: seq[Seg]

proc start(cfg: Config) =
  palette = cfg.colours
  for c in cfg.segs:
    let s = Seg(cfg: c, icon: c.icon, bg: c.bg)
    case c.module
    of "datetime": datetime.init(s)
    of "memory": memory.init(s)
    of "cpu": cpu.init(s)
    of "battery": battery.init(s)
    of "net": net.init(s)
    of "command": initCommand(s, cfg.dir)
    else: initStream(s, cfg.dir)
    s.setBody("")                  # show_always segments show their icon at once
    segs.add s
  for s in segs: runSeg(s)

proc tryReload(force: bool) =
  ## Only a valid config restarts the process. A deleted or empty file keeps the current one.
  var text: string
  if not readConfig(text) or text.strip == "" or (not force and text == running): return
  if load(text).errors.len > 0:
    stderr.writeLine "error: config ", configPath, " is invalid, keeping the current configuration"
    return
  stderr.writeLine "config changed, reloading"
  reexec()

proc flush(force = false) =
  if dirty or force:
    dirty = false
    var bar: string
    for s in segs: bar &= s.text
    sendStatus(bar, force)

block startup:
  var text: string
  var l: Loaded
  if readConfig(text) and text.strip != "":
    l = load(text)
    running = text
    if l.errors.len > 0:
      stderr.writeLine "error: invalid config ", configPath, ", using the built-in default"
      l = loadConfig(DefaultConfig, configPath)
  else:
    if explicitConfig: stderr.writeLine "warning: config file not found: ", configPath, ", using the built-in default"
    l = load("")
  var sigs = @[SIGUSR1, SIGTERM, SIGINT, SIGHUP]
  for i in 1 .. min(l.cfg.segs.len, 64 - sigRtMin().int): sigs.add sigRtMin() + cint(i)
  watchSignals(sigs, proc(sig: cint) =
    if sig == SIGTERM or sig == SIGINT: stop()
    elif sig == SIGHUP: tryReload(force = true)
    elif sig == SIGUSR1:
      for s in segs: runSeg(s)
      flush(force = true)
    else:
      let i = int(sig - sigRtMin())
      if i >= 1 and i <= segs.len: runSeg(segs[i - 1]))
  watchConfig(configPath, proc() = tryReload(force = false))
  onClockSet = proc() =
    for s in segs:
      if s.align > 0: runSeg(s)
  if not useStdout: watchWm()
  onIdle = proc() = flush()
  start(l.cfg)
  flush(force = true)

run()
killAll()
