version       = "0.2.0"
author        = "Malyutka contributors"
description   = "Malyutka (9M14): small, robust, model-neutral Linux agent harness in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["malyutka"]
requires      "nim >= 2.0.0"

task test, "Run tests":
  exec "nim c -r --path:src tests/test_core.nim"
