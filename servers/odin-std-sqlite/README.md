# odin-std-sqlite — SQLite twin of the Odin server

Hand-rolled HTTP/1.1 on `core:net` + upstream `schema.sql` via
`system:sqlite3` FFI (`libsqlite3-dev` on Ubuntu; hand-written
bindings, prepared-once statements, `SQLITE_STATIC` binds). Handlers,
auth, and JSON are verbatim copies of `servers/odin-std`; only the
store layer (plus the 1-line default DB path) differs. It carries no
xitdb code.

## Run

```bash
odin build src -out:server -o:speed
XITDB_PATH=/tmp/x/feed.xitdb JWT_SECRET=twelve-dollar-challenge \
  HOST=127.0.0.1 PORT=3000 ./server
```

Or via the harness (fresh seed + suite): `bash harness/run.sh servers/odin-std`.

## Nginx or direct

Behind `harness/bench/nginx.conf` on `127.0.0.1:3000`, or directly on
`0.0.0.0:80`. Connections stay open until the client closes (except
frameless body-methods, which close after responding). This repo's
gate runs direct.

## Model

OS thread per connection under one mutex (the DB takes one writer at
a time); requests on a connection are served sequentially with
keep-alive. A 256KB arena per connection owns transient bytes and is
reset every request; the reusable read buffer and request bodies live
on the heap, and store reads allocate into the request arena (never
the store heap), so per-connection memory stays flat for the life of
the connection.

## Optimizations (and why)

- Denormalized `author` + `like_count` in the post object: feed and
  single-post reads do zero joins / zero `count(*)` (the xitdb-shaped
  trade the benchmark is meant to test).
- Feed = one `sorted_map_count` + `sorted_map_get_index_kv_pair` window
  + 20 point gets, reversed in memory: O(log n) seek, constant reads.
- One xitdb txn per mutating request (`database_run_context`,
  fsync-on): 201 means committed + fsynced.
- Manual compact-JSON emission with frozen key order
  (`id,body,created_at,author,like_count`); per-string escaping for
  `"` `\` + controls. (Odin `fmt` has no brace escape, so framing
  avoids `fmt` entirely.)
- JWT HS256 verified every request (hand-rolled over `core:crypto`,
  constant-time compare, 60s leeway for parity with the other
  references); auth checked before id validation per spec.
- String keys are hashed inside the binding — no manual hashing.

## Notes

- `vendor/xitdb` is upstream `odin-xitdb` pinned (see `vendor/README.md`).
- POSTs with neither `content-length` nor chunked framing get a normal
  response with `connection: close` (there is no safe way to skip an
  unframed body for reuse). Body bytes already buffered past the
  headers are consumed first — otherwise the server blocks forever
  waiting for arrived bytes.
