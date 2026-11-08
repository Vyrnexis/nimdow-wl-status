import std/[strutils, uri]
import ../core/[segment, procs]

proc weatherHooks*(location, format: string, retry: Duration): Hooks =
  ## wttr.in query; `format` is wttr.in's format string (e.g. "%t", "%c+%t").
  let url = "https://wttr.in/" & encodeUrl(location, usePlus = false) & "?format=" & format.replace(" ", "%20")
  let runner = newRunner()
  var lastGood = ""
  result.refresh = proc(s: Segment) =
    ## Async curl; keeps the last good value on failure and retries after `retry`.
    runner.run("curl", @["-sf", "--max-time", "10", url], 15_000, proc(output: string, code: int) =
      let text = output.strip()
      if code == 0 and text != "":
        lastGood = text
        s.setBody(text)
        s.reschedule()
      else:
        s.setBody(if lastGood != "": lastGood else: "N/A")
        s.scheduleIn(retry))
