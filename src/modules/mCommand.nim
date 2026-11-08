import std/strutils
import ../core/[segment, procs]

proc commandHooks*(cmd: string, timeoutMs: int, hideOnError: bool): Hooks =
  ## Runs `sh -c cmd` asynchronously on every refresh; body = first stdout line, stripped.
  ## Non-zero exit (or timeout) shows "N/A", or nothing with hideOnError.
  let runner = newRunner()   # per instance: several command segments are independent
  result.refresh = proc(s: Segment) =
    runner.run("sh", @["-c", cmd], timeoutMs, proc(output: string, code: int) =
      if code != 0:
        s.setBody(if hideOnError: "" else: "N/A")
      else:
        let lines = output.splitLines()
        s.setBody(if lines.len > 0: lines[0].strip() else: ""))
