# ts-bun — xitdb feed server (TypeScript/Bun reference)

`Bun.serve` + `xitdb-ts` on the frozen layout (`schema-xitdb.md`).

## Run

```bash
bun install
XITDB_PATH=/tmp/x/feed.xitdb JWT_SECRET=twelve-dollar-challenge \
  HOST=127.0.0.1 PORT=3000 bun run src/index.ts
```

Or via the harness (fresh seed + suite): `bash harness/run.sh servers/ts-bun`.

## Nginx or direct

Behind `harness/bench/nginx.conf` on `127.0.0.1:3000` (64 idle conns;
`idleTimeout: 70` — Bun defaults to 10s, so this is load-bearing),
or directly on `0.0.0.0:80`. This repo's gate runs direct.

## Optimizations (and why)

- Denormalized `author` + `like_count` in the post object: feed and
  single-post reads do zero joins / zero `count(*)` (the xitdb-shaped
  trade the benchmark is meant to test).
- Feed = one `SortedMap.count()` + `getIndexKeyValuePair(count-20..)`
  + 20 point gets, reversed in memory: O(log n) seek, constant reads.
- One xitdb txn per mutating request **plus `core.sync()`**
  (flush+fsync): the commit path syncs data but *not* the header write
  (see `commitRoot` in `xitdb-ts`), so without the extra sync 201 would
  not be durable. 201 means committed + synced.
- Single-threaded event loop, no lock: xitdb calls are synchronous
  microsecond local I/O; JWT verify (`jose`, HS256, 60s leeway for
  parity with the Rust/Go references) is awaited per request with no
  memoization.
- `JSON.stringify` on construction-ordered literals gives exact key
  order with no HTML escaping; `body.length` is natively the UTF-16
  reference semantics upstream specifies.
