# TLS is compiled only into the web helper (and its tests). With -d:ssl, Nim loads OpenSSL eagerly at
# startup, so the main harness stays libssl-free and keeps working on hosts without it (SPEC-011).
if projectName() in ["malyutka_web", "test_web"]:
  switch("define", "ssl")
