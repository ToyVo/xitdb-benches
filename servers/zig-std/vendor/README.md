# vendor/

`lib.zig` is the exact upstream `src/lib.zig` from
https://github.com/xit-vcs/xitdb (the reference implementation),
vendored so builds need no network.

- Source commit: `6b93af1af3a260399fa0a0b1b268ded2cbf5eec5` (2026-11-03)
- License: MIT (see upstream LICENSE) — vendored with attribution.
- Re-vendor manually when upstream moves: re-download, re-run
  `zig build test`, re-run both gates.
