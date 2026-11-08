import std/strutils
import ../core/[segment, events, procs]

const
  # Default volume / mute icons
  VOL_ICON* = "\u{f028} "
  MUTE_ICON* = "\u{f0581} "

proc parseVolume(output: string): string =
  let parts = output.split(" / ")
  if parts.len < 2: return ""
  parts[1].strip

proc pulseHooks*(iconVolume, iconMute: string): Hooks =
  ## Event driven: `pactl subscribe` triggers a debounced volume/mute query.
  ## Single instance only (one `pactl subscribe` child).
  var pulseQuery: proc() {.closure.}

  result.start = proc(s: Segment) =
    let volRun = newRunner()
    let muteRun = newRunner()
    var debounce: TimerId = 0

    proc query() =
      volRun.run("pactl", @["get-sink-volume", "@DEFAULT_SINK@"], 5000, proc(vout: string, vcode: int) =
        let vol = if vcode == 0: parseVolume(vout) else: ""
        if vol == "":
          s.setBody("N/A")
          return
        muteRun.run("pactl", @["get-sink-mute", "@DEFAULT_SINK@"], 5000, proc(mout: string, mcode: int) =
          let isMuted = mcode == 0 and mout.contains("yes")
          s.icon = if vol == "0%" or isMuted: iconMute else: iconVolume
          s.setBody(vol)))

    pulseQuery = query
    query()
    streamLines("pactl", @["subscribe"], proc(line: string) =
      # "on sink #N" / "on server" only: "sink-input" events fire constantly during playback
      if (" on sink #" in line or " on server" in line) and debounce == 0:
        debounce = after(50, proc() =
          debounce = 0
          query()))

  result.refresh = proc(s: Segment) =
    if pulseQuery != nil: pulseQuery()
