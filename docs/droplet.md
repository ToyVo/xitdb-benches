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
