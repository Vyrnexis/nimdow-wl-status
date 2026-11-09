# Package
version       = "0.3.0"
author        = "DrunkenAlcoholic"
description   = "Event-driven status feeder for nimdow-wl"
license       = "GPL-3.0-or-later"
srcDir        = "src"
bin           = @["nimdow_wl_status"]
namedBin["nimdow_wl_status"] = "nimdow-wl-status"

# Dependencies
requires "nim >= 2.0.0"
requires "parsetoml >= 0.7.2"
