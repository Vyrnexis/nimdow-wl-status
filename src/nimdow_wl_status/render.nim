## Segment styles (sides glyphs), colour -> SGR, segment text.
import std/[strutils, tables]

type Sides* = tuple[left, right: string]

const
  Reset = "\x1b[0m"
  FG = "\x1b[38;2;"
  BG = "\x1b[48;2;"
  Region = "\x1F"
  Styles* = {
    "arrow": (left: "", right: ""), "arrow_l": (left: "", right: ""),
    "arrow_r": (left: "", right: ""), "circle": (left: "", right: ""),
    "circle_l": (left: "", right: ""), "circle_r": (left: "", right: ""),
    "angle_a": (left: "", right: ""), "angle_b": (left: "", right: ""),
    "none": (left: "", right: "")}.toTable

proc isHex*(s: string): bool =
  if s.len != 7 or s[0] != '#': return false
  for c in s[1 .. ^1]:
    if c notin HexDigits: return false
  true

proc sgr(hex: string): string =
  ## "#rrggbb" -> "r;g;bm"
  let v = fromHex[int](hex[1 .. 6])
  $(v shr 16 and 0xff) & ";" & $(v shr 8 and 0xff) & ";" & $(v and 0xff) & "m"

const MaxBody* = 256               ## bytes of external text kept per segment

proc sanitize*(s: string): string =
  ## External text (scripts, SSIDs) made safe for the status: bytes < 0x20 and 0x7f are
  ## dropped (that removes the 0x1F region separator and ESC), then at most MaxBody bytes
  ## are kept, cut on a UTF-8 character boundary.
  var clean = s.len <= MaxBody
  if clean:
    for c in s:
      if c < ' ' or c == '\x7f': (clean = false; break)
    if clean: return s
  for c in s:
    if c < ' ' or c == '\x7f': continue
    if result.len == MaxBody:
      if (c.ord and 0xC0) == 0x80:                 # cut inside a character: drop it whole
        while result.len > 0 and (result[^1].ord and 0xC0) == 0x80: result.setLen result.len - 1
        if result.len > 0: result.setLen result.len - 1
      break
    result.add c

proc segmentText*(sides: Sides, bg, fg, icon, body: string, showAlways: bool): string =
  ## One bar segment. A hidden one is just its region separator, so click region N stays
  ## segment N. `fg` empty = leave the bar's foreground alone.
  if body == "" and not showAlways: return Region
  let bgc = sgr(bg)
  let main = BG & bgc & (if fg != "": FG & sgr(fg) else: "") & icon & body & Region
  if sides.left == "" and sides.right == "":
    main & Reset
  elif sides.right == "":
    FG & bgc & sides.left & Reset & main
  else:
    Reset & FG & bgc & sides.left & Reset & main & Reset & FG & bgc & sides.right & Reset
