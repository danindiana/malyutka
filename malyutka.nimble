version       = "0.3.1"
author        = "Malyutka contributors"
description   = "Malyutka (9M14): small, robust, model-neutral Linux agent harness in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["malyutka"]
requires      "nim >= 2.0.0"

task test, "Run tests":
  exec "nim c -r --hints:off --path:src tests/test_core.nim"
  exec "nim c -r --hints:off --path:src tests/test_invariants.nim"
  exec "nim c -r --hints:off --path:src tests/test_adversarial.nim"
