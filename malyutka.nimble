version       = "0.8.0"
author        = "Malyutka contributors"
description   = "Malyutka (9M14): small, robust, model-neutral Linux agent harness in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["malyutka"]
requires      "nim >= 1.6.14"   # tested: 1.6.14 native (full suite); 2.2.4 semantic check only

task test, "Run tests":
  exec "nim c -r --hints:off --path:src tests/test_core.nim"
  exec "nim c -r --hints:off --path:src tests/test_invariants.nim"
  exec "nim c -r --hints:off --path:src tests/test_adversarial.nim"
  exec "nim c -r --hints:off --path:src tests/test_m2.nim"
  exec "nim c -r --hints:off --path:src tests/test_sessions.nim"
  exec "nim c -r --hints:off --path:src tests/test_compact.nim"
  exec "nim c -r --hints:off --path:src tests/test_process.nim"
  exec "nim c -r --hints:off --path:src tests/test_skills.nim"
  exec "nim c -r --hints:off --path:src tests/test_mcp.nim"
  exec "nim c -r --hints:off --path:src tests/test_latch.nim"
