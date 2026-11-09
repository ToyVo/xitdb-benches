# go-std-sqlite — SQLite twin of the Go stdlib server

Go std `net/http` on upstream `schema.sql` via mattn/go-sqlite3 v1.14.53
(cgo, bundled SQLite amalgamation; `database/sql` with `MaxOpenConns(1)`).
Handlers, auth, and JSON are verbatim copies of `servers/go-std`; only
the store layer differs.

## Run

```bash
go build -o bin/server .
XITDB_PATH=/tmp/x/feed.xitdb JWT_SECRET=twelve-dollar-challenge \
  HOST=127.0.0.1 PORT=3000 ./bin/server
```

Or via the harness (fresh seed + suite): `bash harness/run.sh servers/go-std`.

## Nginx or direct

Behind `harness/bench/nginx.conf` on `127.0.0.1:3000` (64 idle conns;
`http.Server{IdleTimeout: 70s}`, so Nginx never reuses a closed socket),
or directly on `0.0.0.0:80`. This repo's gate runs direct.

## Optimizations (and why)

- Denormalized `author` + `like_count` in the post object: feed and
  single-post reads do zero joins / zero `count(*)` (the xitdb-shaped
  trade the benchmark is meant to test).
- Feed = one `SortedMap.Count()` + `GetIndexKeyValuePair(count-20..)`
  + 20 point gets, reversed in memory: O(log n) seek, constant reads.
- One xitdb txn per mutating request (`RunContext`; the commit path
  syncs, so 201 means committed + durable).
- Whole-DB `sync.Mutex` (stdlib spawns a goroutine per conn; xitdb
  takes one writer at a time); reads hold it only for the copy.
- Manual compact-JSON emission with frozen key order
  (`id,body,created_at,author,like_count`); strings escaped via an
  non-HTML-escaping `json.Encoder` (`SetEscapeHTML(false)`).
- JWT HS256 verified every request (60s leeway, parity with the Rust
  reference); auth checked before id validation per spec.
