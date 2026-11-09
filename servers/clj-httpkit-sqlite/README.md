# clj-httpkit-sqlite — SQLite twin of the Clojure/http-kit server

http-kit + Ring on upstream `schema.sql` via `org.xerial/sqlite-jdbc`
3.46.1.0 + `org.clojure/java.jdbc` 0.7.12 (JVM-bundled natives, no apt).
Handlers, auth, and JSON are verbatim copies of `servers/clj-httpkit`;
only the store layer (plus the 1-line default DB path) differs. Serves
plain `feed.db`, not the history flavor.

## Run

```bash
clojure -T:build uber
XITDB_PATH=/tmp/x/feed-clj.xitdb JWT_SECRET=twelve-dollar-challenge \
  HOST=127.0.0.1 PORT=3000 java -Xmx1g -jar target/server.jar
```

Or via the harness (fresh seed + suite):
`FLAVOR=history bash harness/run.sh servers/clj-httpkit`.

## Why a second seed flavor

`xitdb-clj` roots every file in a history `ArrayList` (its atom model:
`swap!`/`@db`), so it cannot serve the HashMap-rooted `feed.xitdb`.
`bun ./seed/generate-xitdb.ts --flavor history` writes the same rows
with the canonical map as moment 0; xitdb-clj opens it in string-key
`:compat` mode. Same rows, same goldens — only the root differs.

## Nginx or direct

Behind `harness/bench/nginx.conf` on `127.0.0.1:3000`, or directly on
`0.0.0.0:80`. This repo's gate runs direct. (`-Xmx1g` caps heap for the
2GB droplet.)

## Optimizations (and why)

- Denormalized `author` + `like_count` in the post object: feed and
  single-post reads do zero joins / zero `count(*)` (the xitdb-shaped
  trade the benchmark is meant to test).
- Feed = one `count` + lazy `xitdb.sorted/page` window of 20 + 20 point
  gets, reversed: O(log n) seek, constant reads, low memory.
- One `swap!` per mutating request (atom lock inside, no extra lock),
  **plus an explicit `sync` after each**: the commit path syncs data
  but *not* the header write, so without it 201 would not be durable.
- Reads go through `@db` (shared read handle, thread-safe); http-kit
  threads share it freely.
- Manual compact-JSON emission with frozen key order
  (`id,body,created_at,author,like_count`); `cheshire/generate-string`
  per string for escaping.
- JWT HS256 (`buddy-sign`, 60s leeway for parity with the other
  references) verified every request; auth checked before id
  validation per spec.
