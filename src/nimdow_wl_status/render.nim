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

proc segmentText*(sides: Sides, bg, fg, icon, body: string, showAlways: bool): string =
  ## One bar segment; "" when hidden. `fg` empty = leave the bar's foreground alone.
  if body == "" and not showAlways: return ""
  let bgc = sgr(bg)
  let main = BG & bgc & (if fg != "": FG & sgr(fg) else: "") & icon & body & Region
  if sides.left == "" and sides.right == "":
    main & Reset
  elif sides.right == "":
    FG & bgc & sides.left & Reset & main
  else:
    Reset & FG & bgc & sides.left & Reset & main & Reset & FG & bgc & sides.right & Reset
