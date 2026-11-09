## TOML -> Config, validation. Never raises; problems are returned as errors/warnings.
import std/[os, strutils, sequtils, tables, times]
import parsetoml
import render

const DefaultConfig* = staticRead("../../config.default.toml")

type
  SegCfg* = object
    module*, icon*, bg*, fg*: string  ## bg/fg are "#rrggbb"; fg "" = unset
    sides*: Sides
    interval*: float                  ## seconds; 0 = only on signal; -1 = unset (datetime: aligned)
    showAlways*: bool
    opt*: TomlTableRef                ## module options, already type-checked
  Config* = object
    segs*: seq[SegCfg]
    colours*: Table[string, string]   ## name -> "#rrggbb"
    dir*: string                      ## config file directory (cwd of scripts)
  Loaded* = object
    cfg*: Config
    errors*, warnings*: seq[string]

# key:type  s string, c colour, y style, n number >= 0, i integer, b bool, a array of strings
const
  Common = "module:s icon:s colour:c color:c text_colour:c style:y interval:n show_always:b"
  Modules = {
    "datetime": (-1.0, "format:s"),
    "memory": (2.0, "method:s decimals:i"),
    "cpu": (2.0, "decimals:i"),
    "battery": (5.0, "icons:a name:s"),
    "net": (5.0, "icon_wifi:s icon_ethernet:s icon_disconnected:s show_ssid:b"),
    "command": (60.0, "command:s timeout:n hide_on_error:b"),
    "stream": (0.0, "command:s")}.toTable

proc str*(c: SegCfg, k: string, d = ""): string =
  if k in c.opt: c.opt[k].stringVal else: d
proc num*(c: SegCfg, k: string, d: float): float =
  if k notin c.opt: return d
  let v = c.opt[k]
  if v.kind == TomlValueKind.Int: v.intVal.float else: v.floatVal
proc flag*(c: SegCfg, k: string, d: bool): bool =
  if k in c.opt: c.opt[k].boolVal else: d
proc list*(c: SegCfg, k: string): seq[string] =
  if k in c.opt:
    for e in c.opt[k].arrayVal: result.add e.stringVal

proc resolve(v: string, raw: Table[string, string]): string =
  ## "#rrggbb" or a (chain of) names from `raw`; "" if unknown.
  var v = v.strip
  for _ in 0 .. 8:
    if isHex(v): return v
    if v.toLowerAscii notin raw: return ""
    v = raw[v.toLowerAscii]

proc typeOk(v: TomlValueRef, t: char): bool =
  case t
  of 's', 'c', 'y': v.kind == TomlValueKind.String
  of 'n': (v.kind == TomlValueKind.Int and v.intVal >= 0) or (v.kind == TomlValueKind.Float and v.floatVal >= 0)
  of 'i': v.kind == TomlValueKind.Int
  of 'b': v.kind == TomlValueKind.Bool
  else:
    if v.kind != TomlValueKind.Array: return false
    for e in v.arrayVal:
      if e.kind != TomlValueKind.String: return false
    true

proc loadConfig*(text, path: string): Loaded =
  var errs, warns: seq[string]
  let dir = parentDir(absolutePath(path))
  var root: TomlValueRef
  try: root = parseString(text)
  except CatchableError as e: return Loaded(errors: @[path & ": " & e.msg])
  let top = root.tableVal
  for k in top.keys:
    if k notin ["bar", "colours", "segment"]: warns.add "unknown key '" & k & "' (ignored)"

  proc table(name: string): TomlTableRef =
    if name in top and top[name].kind == TomlValueKind.Table: top[name].tableVal
    else: newTTable().tableVal

  let bar = table("bar")
  var barSides = Styles["angle_b"]
  if "style" in bar:
    if bar["style"].kind != TomlValueKind.String or bar["style"].stringVal.toLowerAscii notin Styles:
      errs.add "[bar] style: unknown style (" & toSeq(Styles.keys).join(", ") & ")"
    else: barSides = Styles[bar["style"].stringVal.toLowerAscii]
  let barFg = if "text_colour" in bar and bar["text_colour"].kind == TomlValueKind.String: bar["text_colour"].stringVal else: ""

  # colours: theme files first, then the user's [colours]
  var raw: Table[string, string]
  proc addColours(t: TomlTableRef, origin: string) =
    for k, v in t:
      if v.kind == TomlValueKind.String: raw[k.toLowerAscii] = v.stringVal
      else: errs.add origin & ": colour '" & k & "' must be a string"
  if "colour_files" in bar:
    let files = bar["colour_files"]
    if not typeOk(files, 'a'): errs.add "[bar] colour_files: expected array of strings"
    else:
      for f in files.arrayVal:
        try:
          let t = parseString(readFile(dir / f.stringVal)).tableVal
          if "colours" in t and t["colours"].kind == TomlValueKind.Table: addColours(t["colours"].tableVal, f.stringVal)
        except CatchableError as e: errs.add "colour file " & f.stringVal & ": " & e.msg
  addColours(table("colours"), "[colours]")
  for k, v in raw:
    let hex = resolve(v, raw)
    if hex == "": errs.add "[colours] " & k & ": invalid colour \"" & v & "\""
    else: result.cfg.colours[k] = hex
  if barFg != "" and resolve(barFg, raw) == "": errs.add "[bar] text_colour: invalid colour \"" & barFg & "\""

  let segs = if "segment" in top and top["segment"].kind == TomlValueKind.Array: top["segment"].arrayVal else: @[]
  if segs.len == 0: errs.add "no [[segment]] defined"
  for i, node in segs:
    var label = "segment " & $(i + 1)
    if node.kind != TomlValueKind.Table:
      errs.add label & ": expected a table"; continue
    let t = node.tableVal
    let name = if "module" in t and t["module"].kind == TomlValueKind.String: t["module"].stringVal.toLowerAscii else: ""
    if name notin Modules:
      errs.add label & ": module must be one of " & toSeq(Modules.keys).join(", ")
      continue
    label &= " (" & name & ")"
    var c = SegCfg(module: name, bg: "#282828", fg: resolve(barFg, raw), sides: barSides, interval: Modules[name][0], opt: newTTable().tableVal)
    var types: Table[string, char]
    for kv in (Common & " " & Modules[name][1]).split: types[kv.split(':')[0]] = kv[^1]
    let errsBefore = errs.len
    for k, v in t:
      if k notin types: warns.add label & ": unknown key '" & k & "' (ignored)"; continue
      if not typeOk(v, types[k]): errs.add label & ": key '" & k & "': wrong type or value"; continue
      case types[k]
      of 'c':
        let hex = resolve(v.stringVal, raw)
        if hex == "": errs.add label & ": key '" & k & "': invalid colour \"" & v.stringVal & "\""
        elif k == "text_colour": c.fg = hex
        elif k == "colour" or "colour" notin t: c.bg = hex
      of 'y':
        if v.stringVal.toLowerAscii notin Styles: errs.add label & ": key '" & k & "': unknown style \"" & v.stringVal & "\""
        else: c.sides = Styles[v.stringVal.toLowerAscii]
      else: c.opt[k] = v
    if "icon" in c.opt: c.icon = c.opt["icon"].stringVal
    c.showAlways = c.flag("show_always", false)
    c.interval = c.num("interval", c.interval)
    if errs.len == errsBefore:
      if name == "datetime":
        try: discard now().format(c.str("format", "ddd d MMM HH:mm "))
        except CatchableError: errs.add label & ": key 'format': invalid time format"
      elif name == "memory" and c.str("method", "htop") notin ["htop", "available"]:
        errs.add label & ": key 'method': htop or available"
      elif name == "battery" and "icons" in c.opt and c.list("icons").len != 6:
        errs.add label & ": key 'icons': expected exactly 6 strings"
      elif name in ["command", "stream"] and c.str("command").strip == "":
        errs.add label & ": key 'command': missing or empty"
    result.cfg.segs.add c
  result.cfg.dir = dir
  result.errors = errs
  result.warnings = warns
