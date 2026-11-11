# Droplet provision record (M3 Task 1)

- Bench: `xb-bench` (178.128.235.251), s-1vcpu-2gb, tor1, Ubuntu 24.04 x86_64, 1 vCPU / 1.9GB.
- k6 driver: `xb-k6` (138.197.152.199), s-1vcpu-1gb, tor1, k6 v1.8.2.
- SSH: throwaway `xitdb-m3-batch` ed25519 key (deleted at batch end).

## Toolchains (via each server's install.sh, all verified)

| stack | version |
|---|---|
| rustc/cargo | 1.85.0 |
| go | go1.23.12 linux/amd64 |
| bun | 1.4.4 |
| zig | 0.17.0 |
| java/maven | Temurin 21.0.13 / Maven 3.10.0 |
| clojure | CLI 1.12.6.1673 |
| odin | dev-2026-10 |
| k6 (driver) | v1.8.2 |

## Provision bugs found and fixed (all in install.sh scripts)

- zig tarball is arch-first (`zig-x86_64-linux-…`, not `zig-linux-x86_64-…`).
- go installed but never symlinked into PATH.
- odin needs `clang` specifically (plus build-essential); found via strace.
- clj upstream installer needs an existing prefix dir + ruby under the
  `HOMEBREW_RUBY_PATH` name; guard now reinstalls on literal `PREFIX`.
- rustup shims need `RUSTUP_HOME` — symlinked toolchain binaries directly.

## On-box small gates (all 42/42)

rust-axum, go-std, ts-bun, zig-std, java-spring, odin-std,
clj-httpkit (`FLAVOR=history`).

---

# Droplet provision record (M4/B9 re-score batch)

- Bench: `xb2-bench` (159.89.123.95), s-1vcpu-2gb, tor1, Ubuntu 24.04.
- k6 driver: `xb2-k6` (159.89.122.17), s-2vcpu-4gb from the start
  (M3 learned a 1gb driver OOM-starves at 2500 VUs), k6 v1.8.2.
- SSH: throwaway `xitdb-m4-batch` ed25519 key (deleted at batch end).
- Same toolchain versions as M3 (verified identical); twin extras:
  zig amalgamation 3.54.1 (via twin install.sh), libsqlite3-dev
  (via twin install.sh). Master seeds: hashmap full (1010MB), history
  full (634MB), sqlite full (275MB).

## On-box small gates (all 14 × 42/42)

All 7 xitdb servers (M4a-fixed code) + all 7 `-sqlite` twins
(`STORE=sqlite`), small seeds.

## Batch notes

- k6-box sshd wedged twice mid-batch (M3 saw it once); detached legs
  meant no data loss. One reboot issued; box recovered on its own.
- Contaminated legs (non-monotonic 8–26x outliers) were rerun fresh
  and marked in the run logs, never silently kept.
- M3-vs-M4 xitdb verdicts are NOT comparable across batches (same rust
  binary: 5000 vs 4062 — droplet variance). Every xVAS is same-box.
