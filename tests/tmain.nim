## Unit tests: `nimble test`.
import std/[unittest, strutils, tables]
import ../src/nimdow_wl_status/render
import ../src/nimdow_wl_status/child
import ../src/nimdow_wl_status/modules/[cpu, memory]

suite "sanitize":
  test "clean text is untouched":
    check sanitize("Updates: 3 \u{f1eb} é") == "Updates: 3 \u{f1eb} é"
  test "control bytes, ESC and the region separator are dropped":
    check sanitize("a\x1b[31mb\x1Fc\x7fd\te\nf\0g") == "a[31mbcdefg"
  test "capped on a character boundary":
    check sanitize('x'.repeat(300)).len == MaxBody
    let s = sanitize('x'.repeat(MaxBody - 1) & "é" & "tail")   # é would straddle the cap
    check s == 'x'.repeat(MaxBody - 1)
    check sanitize('x'.repeat(MaxBody - 2) & "é").len == MaxBody

suite "segmentText":
  let sides = Styles["angle_b"]
  test "a hidden segment is its region separator":
    check segmentText(sides, "#282828", "", "", "", false) == "\x1F"
  test "a shown one ends with its region separator, one per segment":
    let t = segmentText(sides, "#282828", "", "i ", "body", false)
    check t.count('\x1F') == 1
    check "i body\x1F" in t
  test "show_always shows the icon only":
    check "ic\x1F" in segmentText(sides, "#282828", "", "ic", "", true)
  test "region numbering with a hidden segment in the middle":
    let bar = segmentText(sides, "#282828", "", "", "a", false) & segmentText(sides, "#282828", "", "", "", false) &
              segmentText(sides, "#282828", "", "", "c", false)
    check bar.count('\x1F') == 3

suite "splitLines":
  test "complete lines first, the rest only on flush":
    var buf = "one\ntwo\r\nthr"
    var got: seq[string]
    splitLines(buf, false, proc(l: string) = got.add l)
    check got == @["one", "two"]
    check buf == "thr"
    splitLines(buf, true, proc(l: string) = got.add l)
    check got == @["one", "two", "thr"]
    check buf == ""
  test "data and EOF in one pass keeps the line order":
    var buf = "a\nb\nc"
    var got: seq[string]
    splitLines(buf, true, proc(l: string) = got.add l)
    check got == @["a", "b", "c"]

suite "cpu":
  test "only the first 8 fields count (guest is inside user)":
    var total, idle: int
    parseStat("cpu  100 10 50 800 40 5 5 2 77 7\ncpu0 1 2 3", total, idle)
    check total == 100 + 10 + 50 + 800 + 40 + 5 + 5 + 2
    check idle == 840
  test "usage of a delta":
    check usage(200, 150) == 25.0
    check usage(0, 0) == 0.0

suite "memory":
  test "only the needed keys, in one pass":
    let m = "MemTotal:       16000 kB\nMemFree:         4000 kB\nMemAvailable:    9000 kB\n" &
            "Buffers:          100 kB\nCached:          2000 kB\nShmem:            300 kB\nSReclaimable:     200 kB\nOther: 5 kB\n"
    var v: array[7, int]
    parseMeminfo(m, m.len, v)
    check v == [16000, 4000, 9000, 100, 2000, 300, 200]
  test "an absent key is -1":
    let m = "MemTotal: 1 kB\n"
    var v: array[7, int]
    parseMeminfo(m, m.len, v)
    check v[0] == 1 and v[2] == -1
