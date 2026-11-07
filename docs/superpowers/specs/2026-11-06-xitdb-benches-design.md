# xitdb-benches ($12 Server Challenge on xitdb) — Design

Date: 2026-11-06
Status: draft, awaiting review
Approach: (1) Rust-reference-first, then fan out

## 1. Intent

Build a new local repo `xitdb-benches` (publish later) that runs the
[twelve-dollar-server-challenge](https://github.com/arjaythedev/twelve-dollar-server-challenge)
feed API conformantly, with xitdb instead of SQLite, in 7 languages —
so the xitdb implementations race each other primarily, and the
published SQLite leaderboard secondarily.

- Outcome: 7 conformant servers (rust, zig, java, go, typescript +
  clojure, odin) + one shared harness (seed generator, test port,
  load reuse, droplet contract).
- Why: the existing `benches/ops.rs` here is micro-benchmarks
  (hashmap/array/sorted/commit); the existing
  `examples/rest_server.rs` is a minimal `PUT/GET/DELETE /kv/{key}`
  over a file-backed `HashMap`. Neither proves feed-API conformance
  or cross-language comparability.
- Success: `test-xitdb.sh` 42/42 on a fresh full `feed.xitdb`
  (50k users / 500k posts / ~2M likes) per server + local k6 smoke
  green; v1 done = Rust green + 6 scaffolds; M2 = all 7 green;
  M3 = 7-way shootout numbers in `LEADERBOARD-XITDB.md`.
- Non-goals (YAGNI): no query engine, no SQLite compat layer, no
  kernel/box tuning, no change to upstream challenge files beyond
  vendoring.

References: `SPEC.md`, `schema.sql`, `seed/generate.mjs`,
`seed/make-seed.sh`, `test/test.sh`, `test/run.sh`,
`bench/load.js`, `bench/nginx.conf`; xitdb impls: `xit-vcs/xitdb`
(Zig), `xitdb-rs` (this repo, Rust), `xitdb-java`, `xitdb-ts`,
`xitdb-go`, `codeboost/xitdb-clj`, `boxxxie/odin-xitdb`;
realistic-load-test / database-benchmark-configs as secondary refs.

## 2. Architecture & repo layout

New repo `xitdb-benches/` (local for now):

```
xitdb-benches/
  SPEC-XITDB.md          # upstream SPEC.md + xitdb deltas
  schema-xitdb.md        # canonical layout doc (frozen before fan-out)
  seed/                  # TS/Bun generator -> feed.xitdb + tokens.json
  harness/               # test-xitdb.sh, run.sh, bench/load.js, nginx.conf
  servers/
    rust-axum/           # v1: full impl
    go-std/ ts-bun/ zig-std/ java-spring/ clj-httpkit/ odin-std/
      # v1: scaffold only (README + install/build/start + stub)
  docker-compose.yml     # local 7x services on 3001-3007 + nginx option
  LEADERBOARD-XITDB.md   # xitdb-vs-xitdb primary, SQLite secondary
```

Runtime contract (droplet-faithful, works locally): env `XITDB_PATH`
(fresh copy of `feed.xitdb`), `JWT_SECRET=twelve-dollar-challenge`,
`HOST`/`PORT` (`127.0.0.1:3000` behind Nginx, `0.0.0.0:80` direct).
Each server keeps `install.sh` (root, toolchain), `build.sh`
(pinned deps, no prebuilt binaries), `start.sh` (foreground, healthy
<=60s). HTTP/1.1 keep-alive; idle >=65s behind Nginx (64 idle conns)
or ~15k conns direct with `LimitNOFILE=65535`. No kernel tuning;
in-process settings (threads, GC, fsync) fair game.

## 3. Canonical xitdb layout (all 7 share; frozen before fan-out)

Denormalized (option A): embed the join at write time; plays to
xitdb's strength, avoids the per-request join/counter that a
normalized mirror of SQLite would force.

Root is a `HashMap` with 5 keys: `users`, `posts`, `feed`, `likes`,
`meta`.

- `users`: `HashMap<id_str -> {username, created_at}>`. Write-once
  at seed; never on hot path (auth uses JWT `username` as-is).
- `posts`: `HashMap<id_str -> post-object HashMap{id:Uint,
  body:String, created_at:String, author:String,
  like_count:Uint}>`. `author` + `like_count` embedded: zero joins,
  zero `count(*)` on reads. Stored state, not a cache.
- `feed`: `SortedMap<feed_key -> post_id_str>` where
  `feed_key = created_at + '\0' + id_padded_10`. `created_at` is
  `YYYY-MM-DDTHH:MM:SS.mmmZ`, so lexicographic =
  `ORDER BY created_at ASC, id ASC`. Feed read = `count()` ->
  `iter_from_index(count-20)` -> 20 forward -> reverse in memory ->
  20x `posts.get()`. Single-post read = `posts.get(id)` only.
- `likes`: `HashMap<post_id_str -> HashSet<user_id_str>>`.
  `POST /:id/like` runs one `run_context` txn: put-if-absent + bump
  `posts[id].like_count` iff inserted. Returns `201
  already_liked:false` vs `200 already_liked:true`; atomic under the
  writer mutex.
- `meta`: `HashMap{next_post_id:Uint, seed_sha:String}`.
  `POST /posts` txn: `id = next_post_id++`, `created_at =
  now_utc_millis_Z`, insert `posts[id]` + `feed.put(feed_key)`,
  commit with `FileCore` fsync:true before 201 (the WAL +
  `synchronous=NORMAL`-or-stronger equivalent).

## 4. Seed generator (TS/Bun, single source of truth)

`seed/` is a Bun project on `xitdb-ts` (same hash/magic/slots; files
stay byte-compatible with Rust/Go/Zig/Java/Clojure/Odin given the
same hash).

- Ports `generate.mjs` line-for-line: mulberry32(42),
  `ADJECTIVES/NOUNS/WORDS/OPENERS`, `sentence()/postBody()`,
  `END=2026-01-01`, `USERS=50k`, `POSTS=500k`, `LIKES=~2M` (expo +
  1% popular x20), `TOKEN_COUNT=20k`, `JWT_SECRET`. TSV row content
  identical, sunk into xitdb instead of SQLite.
- One bulk txn into `feed.xitdb` per section 3 (`users` -> `posts`
  -> `feed` index -> `likes` sets + `like_count` backfill ->
  `meta{next_post_id:500001}`), plus `tokens.json` (HS256, `iat=now`,
  `exp=+10y`). 2k-row batches so Bun stays under ~512MB ingest.
- Verifies: counts + spot golden reads vs SQLite TSVs (same
  bodies/usernames/timestamps); prints content sha alongside
  upstream `738d11ab...` for audit. Flags: `--full` (default)
  vs `--small` (1k/10k/20k, bring-up + CI speed).
- Servers never generate at boot: `start.sh` copies `feed.xitdb` to
  `$XITDB_PATH` fresh (mirrors "never serve feed.db directly"),
  opens `FileCore` fsync-on.

## 5. API conformance (byte-identical; only storage swaps)

`SPEC-XITDB.md` = upstream `SPEC.md` + three deltas: `SQLITE_PATH` ->
`XITDB_PATH`, health `SELECT 1` -> xitdb root read, durability =
fsync-on-commit.

- 5 endpoints unchanged: `GET /health ->
  {"status":"ok","db":"ok","uptime_s":int}` (503
  `degraded/unreachable` on root-read fail), `GET /feed ->
  {"posts":[20]}`, `GET /posts/:id -> {"post":...}`, `POST /posts ->
  201`, `POST /:id/like -> 201 first / 200 repeat
  {"liked":true,"already_liked":bool,"post_id":int}`.
- Post key order frozen: `id,body,created_at,author,like_count`.
  Compact JSON, `Content-Type: application/json`, `created_at`
  exactly as stored (new rows = UTC-now-millis). `author` = JWT
  `username` as-is; `like_count` = stored counter as-of-request.
- Errors verbatim: `not found`, `invalid post id`, `post not found`,
  `missing bearer token`, `invalid or expired token`, `invalid token
  payload`, `malformed JSON body`, `body is required`, `body must be
  at most 500 characters`, `internal server error`; incl.
  auth-before-id (`POST /posts/abc/like` no-token -> 401,
  with-token -> 400) and trim-then-validate bodies.
- Auth: `Bearer <HS256>` with `JWT_SECRET`, verify signature + `exp`
  + `alg==HS256` every request (no memoization), `sub` =
  positive-int-string, `username` = string. No login endpoint.
- Writes: one xitdb txn per mutating request (group-commit only if
  each response waits its commit); 201 means committed + fsynced.
  Denormalized counts/indexes are stored state, not caches under
  rule 5; no response/query caches, table copies, or JWT memoization.

## 6. The 7 servers

All implement sections 3+5; all honor section 2 contract; keep-alive
idle >=65s or ~15k conns direct.

- Rust/Axum (v1 reference): extends `rest_server.rs`:
  `Arc<Mutex<Database<FileCore>>>`, whole txn in `spawn_blocking`
  (never hold guard across `.await`), manual compact-JSON for key
  order, pinned HS256 verify-per-request.
- Go/std, Zig/std, Odin/std: std `net/http`, std/ordered JSON,
  pinned HS256 libs; single writer mutex; thread-per-conn (Go) or
  event-loop + worker pool (Zig/Odin) tuned for 1 vCPU.
- TS/Bun.serve: `Bun.serve`, pinned `jose` verify, `JSON.stringify`
  with fixed insertion order; sync xitdb txn, no `await` inside.
- Java/Spring Boot, Clojure/http-kit+Ring: Boot 3 pinned /
  Ring+http-kit, Jackson/Cheshire explicit order, `jjwt`/Buddy
  verify-per-request; fixed thread pool for 2GB; writer
  `ReentrantLock` / `locking`.
- Shared: mutating request = one txn (fsync before 201); reads never
  hold the writer lock past the copy; JWT + JSON error branches run
  before DB touch (preserves 400/401 precedence); `uptime_s` =
  process wall-clock.

Pinned stacks: Axum, Go-std, Zig-std, Odin-std, `Bun.serve`, Spring
Boot (leaderboard parity), http-kit.

## 7. Harness + testing

`harness/` vendors upstream, adapts three lines:

- `test-xitdb.sh` = `test/test.sh` verbatim (42 checks, golden
  `feed.json`/`post-*.json` byte compare, JWT edges, trim/500-char /
  special-char round-trip, like 201->200 + re-read, feed-top-20),
  swapping only `XITDB_PATH` setup and `/health` regex. 42/42 on a
  fresh copy; dirty-copy rerun fails goldens, as upstream.
- `run.sh` = `test/run.sh` port: `build.sh` -> fresh `feed.xitdb`
  copy -> `start.sh` (<=60s healthy) -> `test-xitdb.sh` -> teardown.
- `bench/load.js` + `bench/nginx.conf` vendored unchanged: k6 loop
  (feed -> get -> 15% like -> 2% post + think-times); pass = p95
  <500ms, p99 <1s, <1% errors; score = max VUs surviving a 5-min
  hold. `docker-compose.yml` runs all 7 on 3001-3007 + optional
  Nginx so `k6 run -e BASE_URL=... -e VUS=...` works per-server
  locally pre-droplet.
- CI: `--small` seed + `test-xitdb.sh` per server per PR; `--full` +
  k6 smoke (VUS=100, 1m) nightly/on-demand.

## 8. Milestones & success criteria

- M0: spec approved -> `xitdb-benches/` skeleton locally.
- M1 (v1 done): TS/Bun `--small` + `--full` green, Rust/Axum 42/42
  on fresh full `feed.xitdb` + local k6 smoke green, other 6
  scaffolded (boot + `/health`).
- M2 fan-out, one PR per server: Go/std -> TS/Bun.serve -> Zig/std
  -> Clojure/http-kit -> Odin/std -> Java/Spring (last: heaviest on
  2GB). Each green = 42/42 + k6 smoke on full dataset.
- M3 shootout: local 7-way hold at fixed VUs, then optional
  $12-droplet batch (warm-up -> double-to-fail -> narrow-to-250 ->
  5-min hold). Results to `LEADERBOARD-XITDB.md` (primary
  xitdb-vs-xitdb, secondary vs SQLite).

## 9. Approaches considered

1. Rust-reference-first, then fan out (chosen): fastest to de-risk
   layout, exact JSON, JWT-per-request, fsync, like atomicity;
   harness already honors the droplet contract; risk of Rust choices
   leaking mitigated by freezing `schema-xitdb.md` first.
2. Harness + 7 stubs in parallel: best for immediate parallelization;
   rejected for v1 because a layout fix would touch 7 servers at once
   before any one proves the model.
3. Thin vendor of upstream (submodule + `XITDB_PATH` shim): stays in
   sync automatically; rejected because SQLite assumptions (WAL
   pragmas, `ANALYZE`, golden `.db` flow) leak and every xitdb need
   becomes a patch.
