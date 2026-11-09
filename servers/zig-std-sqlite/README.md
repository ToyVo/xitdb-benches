# zig-std-sqlite — SQLite twin of the Zig server

Zig 0.17 `std.http.Server` on upstream `schema.sql` via the SQLite
amalgamation 3.54.1 (compiled in, no system dep; hand-written FFI since
0.17 removed `@cImport`). Handlers, auth, and JSON are verbatim copies
of `servers/zig-std`; only the store layer (plus DB open, build wiring,
and tests) differs.

## Run

```bash
zig build -Doptimize=ReleaseFast
XITDB_PATH=/tmp/x/feed.xitdb JWT_SECRET=twelve-dollar-challenge \
  HOST=127.0.0.1 PORT=3000 ./zig-out/bin/server
```

Or via the harness (fresh seed + suite): `bash harness/run.sh servers/zig-std`.

## Nginx or direct

Behind `harness/bench/nginx.conf` on `127.0.0.1:3000`, or directly on
`0.0.0.0:80`. Connections stay open until the client closes (except
frameless body-methods, which close after responding — see below).
This repo's gate runs direct.

## Model

`std.Thread` per connection under one `std.Io.Mutex` (the DB takes one
writer at a time); requests on a connection are served sequentially
with keep-alive. An arena per request owns all response bytes.

## Optimizations (and why)

- Denormalized `author` + `like_count` in the post object: feed and
  single-post reads do zero joins / zero `count(*)` (the xitdb-shaped
  trade the benchmark is meant to test).
- Feed = one `SortedMap.count()` + `getIndexKeyValuePair(count-20..)`
  + 20 point gets, reversed in memory: O(log n) seek, constant reads.
- One xitdb txn per mutating request (`runContext`, `fsync:true`):
  201 means committed + fsynced.
- Manual compact-JSON emission with frozen key order
  (`id,body,created_at,author,like_count`); `std.json.Stringify` per
  string for escaping.
- JWT HS256 verified every request (hand-rolled over `std.crypto`,
  constant-time compare, 60s leeway for parity with the other
  references); auth checked before id validation per spec.
- `HashMap`/`HashSet` keys are raw `u160` SHA-1 hashes — the server
  hashes every key itself (`validate.hashKey`).

## Notes

- `vendor/lib.zig` is upstream `xitdb` pinned (see `vendor/README.md`).
- POSTs with neither `content-length` nor chunked framing get a normal
  response with `connection: close` (`std.http.Server` cannot discard
  an unframed body for reuse).
