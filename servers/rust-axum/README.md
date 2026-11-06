# rust-axum — xitdb feed server (Rust/Axum reference)

Axum + Tokio multi-thread on the frozen layout (`schema-xitdb.md`).

## Run

```bash
cargo build --release
XITDB_PATH=/tmp/x/feed.xitdb JWT_SECRET=twelve-dollar-challenge \
  HOST=127.0.0.1 PORT=3000 ./target/release/xitdb-bench-rust
```

Or via the harness (fresh seed + suite): `bash harness/run.sh servers/rust-axum`.

## Nginx or direct

Behind `harness/bench/nginx.conf` on `127.0.0.1:3000` (64 idle conns;
Axum/hyper keep-alive idle default ≥65s, so Nginx never reuses a closed
socket), or directly on `0.0.0.0:80`. This repo's gate runs direct.

## Optimizations (and why)

- Denormalized `author` + `like_count` in the post object: feed and
  single-post reads do zero joins / zero `count(*)` (the xitdb-shaped
  trade the benchmark is meant to test).
- Feed = one `SortedMap.count()` + `iter_from_index(count-20)` + 20
  point gets, reversed in memory: O(log n) seek, constant 20 reads.
- One xitdb txn per mutating request (`run_context`, `FileCore`
  fsync:true): 201 means committed + fsynced (the WAL +
  `synchronous=NORMAL`-or-stronger equivalent).
- Whole txn inside `spawn_blocking`, lock guard never held across
  `.await`; single writer mutex (xitdb: one writer at a time).
- Manual compact-JSON emission with frozen key order
  (`id,body,created_at,author,like_count`); `serde_json` only for string
  escaping and request parsing (exact-byte goldens).
- JWT HS256 verified every request (no memoization); auth checked
  before id validation per spec.
