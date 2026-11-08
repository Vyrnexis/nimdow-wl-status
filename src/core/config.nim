## TOML configuration: parsing, validation and building the segment list.
import std/[os, strutils, tables, sets, times]
import parsetoml
import segment, colours
import ../modules/[mArchupdates, mBatstatus, mDatetime, mMemory, mPulse, mWeather, mWifi, mCommand]

const DefaultConfigText* = staticRead("../../config.default.toml")

type
  Loaded* = object
    segments*: seq[Segment]
    errors*, warnings*: seq[string]

  Report = ref object
    errors, warnings: seq[string]

  Ctx = ref object
    label: string
    tbl: TomlTableRef
    used: HashSet[string]
    rep: Report

const
  DEFAULT_COLOUR = "#282828"
  Modules = ["archupdates", "weather", "memory", "pulse", "battery", "wifi", "datetime", "command"]
  SingleInstance = ["archupdates", "pulse", "wifi"]

proc defaultConfigPath*(): string =
  getConfigDir() / "nimdow-wl" / "status.toml"

# ---------------------------------------------------------------- colours

proc lookupIn[T: tuple](pal: T, name: string, found: var string): bool =
  for k, v in fieldPairs(pal):
    if k.toLowerAscii == name:
      found = v
      return true

proc isHex(s: string): bool =
  if s.len != 7 or s[0] != '#': return false
  for c in s[1 .. ^1]:
    if c notin HexDigits: return false
  true

proc resolveColour(value: string, named: Table[string, string], hex: var string): string =
  ## Returns an error message ("" = ok) and the "#rrggbb" in `hex`.
  let v = value.strip()
  if v.startsWith("#"):
    if not isHex(v): return "invalid hex colour \"" & value & "\" (expected #rrggbb)"
    hex = v
    return ""
  let dot = v.find('.')
  if dot > 0:
    let pal = v[0 ..< dot].toLowerAscii.replace("-", "").replace("_", "")
    let name = v[dot + 1 .. ^1].toLowerAscii
    var ok = false
    case pal
    of "gruvbox": ok = lookupIn(Gruvbox, name, hex)
    of "nord": ok = lookupIn(Nord, name, hex)
    of "dracula": ok = lookupIn(Dracula, name, hex)
    of "catppuccin", "cattpuccin": ok = lookupIn(Cattpuccin, name, hex)
    of "rosepine": ok = lookupIn(RosePine, name, hex)
    else: return "unknown palette \"" & v[0 ..< dot] & "\" (gruvbox, nord, dracula, catppuccin, rosepine)"
    if not ok: return "unknown colour \"" & v[dot + 1 .. ^1] & "\" in palette " & v[0 ..< dot]
    return ""
  if v.toLowerAscii in named:
    hex = named[v.toLowerAscii]
    return ""
  "unknown colour \"" & value & "\" (use #rrggbb, <palette>.<name> or a name from [colours])"

# ---------------------------------------------------------------- typed accessors

proc kindName(v: TomlValueRef): string =
  case v.kind
  of TomlValueKind.Int: "integer"
  of TomlValueKind.Float: "float"
  of TomlValueKind.Bool: "boolean"
  of TomlValueKind.String: "string"
  of TomlValueKind.Array: "array"
  of TomlValueKind.Table: "table"
  else: "date/time"

proc fail(c: Ctx, key, msg: string) =
  c.rep.errors.add c.label & ": key '" & key & "': " & msg

proc newCtx(rep: Report, label: string, tbl: TomlTableRef): Ctx =
  Ctx(label: label, tbl: tbl, rep: rep)

proc raw(c: Ctx, key: string): TomlValueRef =
  c.used.incl key
  if key in c.tbl: c.tbl[key] else: nil

proc getStr(c: Ctx, key: string, default = ""): string =
  result = default
  let v = c.raw(key)
  if v == nil: return
  if v.kind != TomlValueKind.String: c.fail(key, "expected string, got " & kindName(v)); return
  result = v.stringVal

proc getBool(c: Ctx, key: string, default: bool): bool =
  result = default
  let v = c.raw(key)
  if v == nil: return
  if v.kind != TomlValueKind.Bool: c.fail(key, "expected boolean, got " & kindName(v)); return
  result = v.boolVal

proc getNum(c: Ctx, key: string, default: float, present: var bool): float =
  ## Integer or float, must be >= 0.
  result = default
  present = false
  let v = c.raw(key)
  if v == nil: return
  var n: float
  case v.kind
  of TomlValueKind.Int: n = v.intVal.float
  of TomlValueKind.Float: n = v.floatVal
  else: c.fail(key, "expected number, got " & kindName(v)); return
  if n < 0: c.fail(key, "must not be negative"); return
  present = true
  result = n

proc getNum(c: Ctx, key: string, default: float): float =
  var p: bool
  c.getNum(key, default, p)

proc getInt(c: Ctx, key: string, default, lo, hi: int): int =
  result = default
  let v = c.raw(key)
  if v == nil: return
  if v.kind != TomlValueKind.Int: c.fail(key, "expected integer, got " & kindName(v)); return
  if v.intVal < lo or v.intVal > hi: c.fail(key, "must be between " & $lo & " and " & $hi); return
  result = v.intVal.int

proc getStrList(c: Ctx, key: string, default: seq[string], count: int): seq[string] =
  result = default
  let v = c.raw(key)
  if v == nil: return
  if v.kind != TomlValueKind.Array: c.fail(key, "expected array of strings, got " & kindName(v)); return
  var l: seq[string]
  for e in v.arrayVal:
    if e.kind != TomlValueKind.String: c.fail(key, "expected array of strings, found " & kindName(e)); return
    l.add e.stringVal
  if l.len != count: c.fail(key, "expected exactly " & $count & " strings, got " & $l.len); return
  result = l

proc getColour(c: Ctx, key: string, named: Table[string, string], default: string): string =
  ## Returns "#rrggbb".
  result = default
  let v = c.raw(key)
  if v == nil: return
  if v.kind != TomlValueKind.String: c.fail(key, "expected string, got " & kindName(v)); return
  var hex: string
  let e = resolveColour(v.stringVal, named, hex)
  if e != "": c.fail(key, e); return
  result = hex

proc warnUnknown(c: Ctx) =
  for k in c.tbl.keys:
    if k notin c.used:
      c.rep.warnings.add c.label & ": unknown key '" & k & "' (ignored)"

proc secs(f: float): Duration = initDuration(milliseconds = int(f * 1000))

# ---------------------------------------------------------------- segments

proc buildSegment(rep: Report, idx: int, node: TomlValueRef, barSides: Sides,
                  named: Table[string, string], seen: var HashSet[string]): Segment =
  var label = "segment " & $idx
  if node.kind != TomlValueKind.Table:
    rep.errors.add label & ": expected a table"
    return nil
  let c = newCtx(rep, label, node.tableVal)
  let errsBefore = rep.errors.len

  let modName = c.getStr("module").toLowerAscii
  if "module" notin node.tableVal:
    c.fail("module", "missing (one of " & Modules.join(", ") & ")")
    return nil
  elif modName notin Modules:
    if errsBefore == rep.errors.len:
      c.fail("module", "unknown module \"" & modName & "\" (one of " & Modules.join(", ") & ")")
    return nil
  c.label = label & " (" & modName & ")"

  let icon = c.getStr("icon")
  # "color" is an alias of "colour"
  if "colour" in node.tableVal and "color" in node.tableVal:
    rep.warnings.add c.label & ": both 'colour' and 'color' set, using 'colour'"
  let key = if "colour" in node.tableVal or "color" notin node.tableVal: "colour" else: "color"
  let colourHex = c.getColour(key, named, DEFAULT_COLOUR)
  c.used.incl "colour"; c.used.incl "color"
  var sides = barSides
  let styleName = c.getStr("style")
  if "style" in node.tableVal and errsBefore == rep.errors.len and not parseStyle(styleName, sides):
    c.fail("style", "unknown style \"" & styleName & "\" (arrow, arrow_l, arrow_r, circle, circle_l, circle_r, angle_a, angle_b, none)")
  var hasInterval: bool
  var intervalSecs = c.getNum("interval", 0, hasInterval)
  let showAlways = c.getBool("show_always", false)

  var
    hooks: Hooks
    defInterval = 0.0         # module default, seconds
    alignMinute = false
    alignSecond = false

  if modName in SingleInstance:
    if modName in seen:
      rep.warnings.add c.label & ": this module can only be used once, duplicate skipped"
      return nil
    seen.incl modName

  case modName
  of "archupdates":
    defInterval = 600
    let busy = c.getColour("colour_busy", named, "#fb4934")
    let text = c.getStr("updating_text", "UPDATING")
    let timeout = c.getNum("timeout", 60)
    hooks = archUpdatesHooks(hexColorToEscapeCode(colourHex), hexColorToEscapeCode(busy), text, int(timeout * 1000))
  of "weather":
    defInterval = 600
    let location = c.getStr("location", "Perth")
    let format = c.getStr("format", "%t")
    let retry = c.getNum("retry", 60)
    if location == "": c.fail("location", "must not be empty")
    hooks = weatherHooks(location, format, secs(retry))
  of "memory":
    defInterval = 2
    let m = c.getStr("method", "htop").toLowerAscii
    if m notin ["htop", "available"]: c.fail("method", "unknown method \"" & m & "\" (htop or available)")
    let decimals = c.getInt("decimals", 2, 0, 6)
    hooks = memoryHooks(m == "available", decimals)
  of "pulse":
    hooks = pulseHooks(c.getStr("icon_volume", VOL_ICON), c.getStr("icon_mute", MUTE_ICON))
  of "battery":
    defInterval = 5
    let icons = c.getStrList("icons", BATTERY_ICONS, 6)
    let name = c.getStr("name")
    hooks = batteryHooks(icons, name)
  of "wifi":
    defInterval = 5
    hooks = wifiHooks(c.getStr("icon_wifi", WIFI_ICON), c.getStr("icon_ethernet", ETHERNET_ICON),
                      c.getStr("icon_disconnected", DISCONNECTED_ICON), c.getBool("show_ssid", true))
  of "datetime":
    let fmt = c.getStr("format", "ddd d MMM HH:mm ")
    if not validDateTimeFormat(fmt): c.fail("format", "invalid time format \"" & fmt & "\"")
    if formatHasSeconds(fmt): alignSecond = true else: alignMinute = true
    hooks = dateTimeHooks(fmt)
  of "command":
    defInterval = 60
    let cmd = c.getStr("command")
    if cmd.strip() == "": c.fail("command", "missing or empty")
    let timeout = c.getNum("timeout", 10)
    let hide = c.getBool("hide_on_error", false)
    hooks = commandHooks(cmd, int(timeout * 1000), hide)
  else: discard

  c.used.incl "module"
  c.warnUnknown()
  if rep.errors.len != errsBefore: return nil

  if hasInterval:
    alignMinute = false; alignSecond = false
  else:
    intervalSecs = defInterval
  initSegment(isShowAlways = showAlways, icon = icon, sides = sides, color = colourHex,
              body = hooks.body, interval = secs(intervalSecs), alignMinute = alignMinute,
              alignSecond = alignSecond, start = hooks.start, refresh = hooks.refresh)

proc parseConfig*(text, origin: string): Loaded =
  ## Parse and validate; never raises. Segments are built only if there are no errors.
  let rep = Report()
  var root: TomlValueRef
  try:
    root = parseString(text, origin)
  except CatchableError as e:
    rep.errors.add origin & ": " & e.msg
    return Loaded(errors: rep.errors)

  let top = newCtx(rep, "config", root.tableVal)
  var barSides = ANGLE_B
  var named = initTable[string, string]()

  # [bar]
  let bar = top.raw("bar")
  if bar != nil:
    if bar.kind != TomlValueKind.Table: rep.errors.add "[bar]: expected a table"
    else:
      let c = newCtx(rep, "[bar]", bar.tableVal)
      let s = c.getStr("style", "angle_b")
      if not parseStyle(s, barSides) and "style" in bar.tableVal and bar.tableVal["style"].kind == TomlValueKind.String:
        c.fail("style", "unknown style \"" & s & "\" (arrow, arrow_l, arrow_r, circle, circle_l, circle_r, angle_a, angle_b, none)")
      c.warnUnknown()

  # [colours] / [colors]
  for tname in ["colours", "colors"]:
    let cols = top.raw(tname)
    if cols == nil: continue
    if cols.kind != TomlValueKind.Table:
      rep.errors.add "[" & tname & "]: expected a table"
      continue
    let c = newCtx(rep, "[" & tname & "]", cols.tableVal)
    for k, v in cols.tableVal:
      c.used.incl k
      if v.kind != TomlValueKind.String:
        c.fail(k, "expected string, got " & kindName(v)); continue
      var hex: string
      let e = resolveColour(v.stringVal, initTable[string, string](), hex)
      if e != "": c.fail(k, e) else: named[k.toLowerAscii] = hex

  # [[segment]]
  let segs = top.raw("segment")
  var built: seq[Segment]
  if segs == nil or (segs.kind == TomlValueKind.Array and segs.arrayVal.len == 0):
    rep.errors.add "config: no [[segment]] defined"
  elif segs.kind != TomlValueKind.Array:
    rep.errors.add "config: 'segment' must be an array of tables ([[segment]]), got " & kindName(segs)
  else:
    var seen = initHashSet[string]()
    for i, node in segs.arrayVal:
      let s = buildSegment(rep, i + 1, node, barSides, named, seen)
      if s != nil: built.add s
  if rep.errors.len == 0 and built.len == 0:
    rep.errors.add "config: no usable segments"

  top.used.incl "colours"; top.used.incl "colors"
  top.warnUnknown()
  result.errors = rep.errors
  result.warnings = rep.warnings
  if rep.errors.len == 0: result.segments = built

proc builtinDefault*(): Loaded =
  parseConfig(DefaultConfigText, "<built-in default>")
