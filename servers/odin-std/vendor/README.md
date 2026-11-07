# vendor/

`xitdb/` is the exact upstream package from
https://github.com/boxxxie/odin-xitdb (the reference Odin implementation),
vendored so builds need no network.

- Source commit: `b760ee9d6ff4b54421d0272c12f74d62c12c4856` (2026-11-06)
- License: MIT (see upstream LICENSE) — vendored with attribution.
- Re-vendor manually when upstream moves: re-copy, re-run `odin test tests/`,
  re-run both gates.
