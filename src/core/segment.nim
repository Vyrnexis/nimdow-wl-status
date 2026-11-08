import std/[times, monotimes, sugar, strformat, strutils]
export times.Duration, times.initDuration, times.DurationZero

type
  Sides* = tuple
    left: string
    right: string

  Segment* = ref object
    sides: Sides
    color*: string
    body: (Segment) -> string
    text*: string
    icon*: string
    isShowAlways*: bool
    raw: string                  # last body text pushed by the module
    interval: Duration           # DurationZero = never due periodically
    alignMinute: bool            # due on every wall-clock minute boundary
    alignSecond: bool            # due on every wall-clock second boundary
    hasDue*: bool
    nextDue*: MonoTime
    index*: int                  # 1-based position in the bar (SIGRTMIN+index)
    start: (Segment) -> void     # called once at startup (async modules)
    refresh: (Segment) -> void   # called on every forced/periodic refresh

  Hooks* = object
    ## What a module contributes to a segment; every instance owns its own closures/state.
    body*: (Segment) -> string
    start*: (Segment) -> void
    refresh*: (Segment) -> void

var barDirty* = false  ## set whenever any segment text changes

# TODO: escape chars to hex color code
const
  RESET: string  = "\x1b[0m"
  FG: string = "\x1b[38;2;"
  BG: string = "\x1b[48;2;"
  
  REGION: string = "\x1F"

  ARROW* = (left: "", right: "").Sides
  ARROW_L* = (left: "", right: "").Sides
  ARROW_R* = (left: "", right: "").Sides

  CIRCLE* = (left: "", right: "").Sides
  CIRCLE_L* = (left: "", right: "").Sides
  CIRCLE_R* = (left: "", right: "").Sides

  ANGLE_A* = (left: "", right: "").Sides
  ANGLE_B* = (left: "", right: "").Sides
  NO_SIDES* = (left: "", right: "").Sides

proc parseStyle*(name: string, sides: var Sides): bool =
  ## Map a style name from the config to its sides; false if unknown.
  result = true
  case name.toLowerAscii
  of "arrow": sides = ARROW
  of "arrow_l": sides = ARROW_L
  of "arrow_r": sides = ARROW_R
  of "circle": sides = CIRCLE
  of "circle_l": sides = CIRCLE_L
  of "circle_r": sides = CIRCLE_R
  of "angle_a": sides = ANGLE_A
  of "angle_b": sides = ANGLE_B
  of "none": sides = NO_SIDES
  else: result = false

proc hexColorToEscapeCode*(strHex: string): string =
  let hex: uint = fromHex[uint](strHex[1..<7])
  return fmt"{hex.int shr 16 and 0xff};{hex.int shr 8 and 0xff};{hex.int and 0xff}m"

proc render(s: Segment) =
  let body = s.raw
  var t: string
  if body == "" and not s.isShowAlways:
    t = body
  else:
    t = if s.sides.left == "" and s.sides.right == "":
      BG&s.color & s.icon & body & REGION & RESET
    elif s.sides.right == "":
      FG&s.color & s.sides.left & RESET & BG&s.color & s.icon & body & REGION
    else:
      RESET & FG&s.color & s.sides.left & RESET & BG&s.color & s.icon & body & REGION & RESET & FG&s.color & s.sides.right & RESET
  if t != s.text:
    s.text = t
    barDirty = true

proc setBody*(s: Segment, text: string) =
  ## Push new body text (from an async/event module); renders and marks the bar dirty.
  s.raw = text
  s.render()

proc rerender*(s: Segment) =
  ## Re-render after changing s.color / s.icon without changing the body text.
  s.render()

proc update*(s: Segment) =
  ## Run the synchronous body (if any) and render it.
  if s.body == nil: return
  var body: string
  try:
    body = s.body(s)
  except CatchableError as e:
    stderr.writeLine "Error: ", e.msg
    body = "N/A"
  s.setBody(body)

proc scheduleIn*(s: Segment, d: Duration) =
  s.hasDue = true
  s.nextDue = getMonoTime() + d

proc reschedule*(s: Segment) =
  ## Compute the next periodic due time.
  if s.alignSecond:
    let n = now()
    let ms = 1000 - n.nanosecond div 1_000_000 + 5
    s.scheduleIn(initDuration(milliseconds = ms))
  elif s.alignMinute:
    let n = now()
    let ms = (60 - n.second) * 1000 - n.nanosecond div 1_000_000 + 5
    s.scheduleIn(initDuration(milliseconds = ms))
  elif s.interval > DurationZero:
    s.scheduleIn(s.interval)
  else:
    s.hasDue = false

proc refreshNow*(s: Segment) =
  ## Refresh the segment: async hook and/or sync body. Never raises.
  if s.refresh != nil:
    try: s.refresh(s)
    except CatchableError as e:
      stderr.writeLine "Error: ", e.msg
      s.setBody("N/A")
  s.update()

proc startSegment*(s: Segment) =
  ## Initial refresh: the start hook if there is one, else a normal refresh.
  if s.start != nil:
    try: s.start(s)
    except CatchableError as e:
      stderr.writeLine "Error: ", e.msg
      s.setBody("N/A")
  else:
    s.refreshNow()

proc initSegment*(isShowAlways: bool = false, icon: string = "", sides: Sides = ANGLE_B, color: string = "#282828", body: (Segment) -> string = nil, interval: Duration = initDuration(milliseconds = 500), alignMinute: bool = false, alignSecond: bool = false, start: (Segment) -> void = nil, refresh: (Segment) -> void = nil): Segment =
  result = Segment.new
  result.icon = icon
  result.sides = sides
  result.color = hexColorToEscapeCode(color)
  result.body = body
  result.isShowAlways = isShowAlways
  result.interval = interval
  result.alignMinute = alignMinute
  result.alignSecond = alignSecond
  result.start = start
  result.refresh = refresh
  result.render()  # isShowAlways segments show their icon before the first body arrives
