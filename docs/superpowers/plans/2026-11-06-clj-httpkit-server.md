# Clojure/http-kit Feed Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conformant `$12`-challenge feed server in `servers/clj-httpkit` (http-kit + `xitdb-clj`), green on the committed goldens via a history-rooted seed flavor.

**Architecture:** The one structural exception in the shootout: `xitdb-clj` roots every file in a history `ArrayList` (its atom model), so it cannot serve the HashMap-rooted `feed.xitdb`. Task 1 teaches the TS generator a `--flavor history` mode (same rows, `ArrayList` root + moment 0, id-0 header) that xitdb-clj opens in `:compat` mode; the server is then a mirror of the other references — denormalized moment map, lazy `page` feed reads, one `swap!` + explicit `sync` per mutation.

**Tech Stack:** Clojure CLI 1.12.6.1673 + JDK 21; `io.github.codeboost/xitdb-clj 0.7.2`, `http-kit 2.8.0`, `cheshire 5.13.0`, `buddy/buddy-sign 3.6.1-359` (all resolve today), `tools.build` for the uberjar.

**Spec:** `/Users/collindie/Code/xitdb-benches/SPEC-XITDB.md` + `/Users/collindie/Code/xitdb-benches/schema-xitdb.md` (same 5-key moment map; root kind is the only delta); behavior reference `servers/go-std/*.go`; goldens `harness/golden-{small,full}/` (content-identical across flavors — fixed targets, NEVER regenerate).

## Global Constraints

- Repo root: `/Users/collindie/Code/xitdb-benches`; `servers/clj-httpkit/` Clojure project (`deps.edn` + `build.clj`); every task ends committed there.
- Flavor contract: `feed.xitdb` (HashMap root, sha1-id header, fileId 8n) stays byte-identical; `feed-clj.xitdb` (ArrayList root with the canonical map as moment 0, id-0 header, fileId 8n) carries the same rows; `tokens.json` shared. Generator default flavor keeps current bytes exactly (Task 1 proves by diff).
- Moment layout frozen: string keys `users,posts,feed,likes,meta`; posts are `{"id" long, "body" str, "created_at" str, "author" str, "like_count" long}`; `feedKey` identical; post JSON key order identical; `Content-Type: application/json`.
- Reads go through `@db` (shared read handle, thread-safe per `wrap-db`); writes are ONE `swap!` each (atom lock inside, no extra lock).
- Durability: `xitdb-java`'s `commitRoot` syncs data but NOT the header write, so every mutating `swap!` is followed by `(.sync (.-core (.-rwdb db)))` — 201 means durable. (`Database.core` is public; `Core.sync()` flushes + fsyncs.)
- Env: `XITDB_PATH` (fresh `feed-clj.xitdb` copy), `JWT_SECRET`, `HOST`, `PORT`; `start.sh` runs `java -Xmx1g -jar` (2GB droplet budget).
- Auth: buddy `unsign` with `{:alg :hs256}` + 60s leeway (or manual exp check if `:leeway` unsupported — Task 2 test decides), verified every request; `sub` = all-digit string `≥1`, `username` = string; auth-before-id.
- Body rule: `clojure.string/trim`, empty → required; `(.length s) > 500` → too-long (JVM UTF-16 length IS the upstream reference semantics, same as TS).
- Id rule: `^[0-9]+$`, unsigned-64 `≥1` (`Long/parseUnsignedLong`); full range accepted, miss → 404 (Rust/Go/Zig-consistent).
- `created_at`: `java.time.Instant/now` formatted `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` UTC (always 3-digit millis).
- `POST /:id/like`: `201 already_liked:false` first, `200 already_liked:true` repeat, count bumps once.

## Review Focus

- History-vs-HashMap roots are mutually unreadable at the root — the clj flavor must actually open in xitdb-clj and read post-1 — pinned in Task 1 (interop assertion) and Task 4 (gates run on `feed-clj`).
- The header write after commit is un-synced by the library — a missing post-`swap!` `sync` loses commits on crash — pinned in Task 3 (write → close → reopen → read-back test).
- buddy `:leeway` support is unverified — pinned in Task 2 (`leeway_parity` vector: expired-30s accepted; manual exp fallback if the option is ignored).
- Numeric `sub`/`username` must be `invalid token payload`, not a signature error — pinned in Task 2 (numeric vectors, cf. the Go fix).
- `count` on the on-disk sorted map is assumed for the feed window — pinned in Task 3 (25-post fixture → newest 20; fails loudly if `count` is absent).

---

## File Structure

`servers/clj-httpkit/` (existing stubs replaced):

- `deps.edn` — `org.clojure/clojure 1.12.0`, `xitdb-clj 0.7.2`, `http-kit 2.8.0`, `cheshire 5.13.0`, `buddy-sign 3.6.1-359`, `tools.build` (build alias); Clojars repo declared; `:paths ["src"]` + `:aliases {:test {:extra-paths ["test"]}}` (suite needs no extra dep).
- `build.clj` — tools.build uberjar (`:main server`, `target/server.jar`).
- `src/validate.clj` — pure: `feed-key`, `valid-post-id` (→ long or nil), `trim-body` (→ `[true v]` / `[false msg]`).
- `src/auth.clj` — `verify-jwt` (→ `{:user-id :username}` / `{:error msg}`).
- `src/store.clj` — `open-store` (path → db), `health?`, `get-feed`, `get-post`, `create-post!`, `like-post!`, `post->json` (manual framing, `cheshire/generate-string` per string).
- `src/server.clj` — http-kit `run-server` + Ring handler; env wiring; `-main` blocks on `@(promise)` (foreground for `run.sh`).
- `test/validate_test.clj`, `test/auth_test.clj`, `test/store_test.clj` — `clojure -M:test` (`:memory` DBs + one temp-file durability test; never seed files).
- `install.sh` (Temurin JDK 21 + Clojure CLI 1.12.6.1673 pinned) / `build.sh` (`clojure -T:build uber`) / `start.sh` (`exec java -Xmx1g -jar target/server.jar`); `README.md` (mirror go README + history-root note + sync note).

Seed changes (Task 1, shared): `seed/generate-xitdb.ts` gains `--flavor hashmap|history` (default `hashmap`; row logic untouched; history wraps the same chunk writes in one `appendContext` with an id-0 `Hasher`); `seed/verify.ts` gains `--flavor` (history descends `ArrayList` index 0 first).

---

### Task 1: History seed flavor + interop proof

**Files:**
- Modify: `seed/generate-xitdb.ts`, `seed/verify.ts`
- Test: small history generation + Clojure one-liner interop assertion (no committed Clojure files yet)

**Interfaces:**
- Consumes: none (extends proven generator).
- Produces:
  - `generate-xitdb.ts --flavor history <dir>` → `feed-clj.xitdb` + shared-shape `tokens.json`
  - `verify.ts <db> [--small|--full] --flavor history` → OK on the clj file

- [ ] **Step 1: Prove the default is byte-stable first** (baseline before refactor)

Run: `bun ./seed/generate-xitdb.ts --small /tmp/xb-base && sha256sum /tmp/xb-base/feed.xitdb | tee /tmp/xb-base.sha`
Expected: records the hash the refactor must preserve.

- [ ] **Step 2: Refactor + flavorize**: extract the per-chunk write body into `writeChunk(root, ...)` used by both paths; hashmap path keeps today's per-chunk `runContext` calls; history path opens `new WriteArrayList(db.rootCursor())` + ONE `appendContext(array.getSlot(-1), cursor => { root = new WriteHashMap(cursor); all chunks })` with `new Hasher("SHA-1")` (id 0) and output `feed-clj.xitdb`; `verify.ts` learns `--flavor` (history: `ReadArrayList` index 0 → moment map, then identical checks). CLI: `--flavor hashmap` default.

- [ ] **Step 3: Verify no-drift + interop**

Run: `bun ./seed/generate-xitdb.ts --small /tmp/xb-reread`, then compare byte size with `/tmp/xb-base/feed.xitdb` + `verify.ts --small` OK. (NOT sha equality: txn trailers carry random commitIds per `commitRoot(randomU64())`, so full files are never byte-stable — identical rows and same txn grouping is the invariant.)
Expected: size equality + verify OK (default path untouched).

Run: `bun ./seed/generate-xitdb.ts --small --flavor history /tmp/xb-clj && bun ./seed/verify.ts /tmp/xb-clj/feed-clj.xitdb --small --flavor history`
Expected: `users=1000 posts=10000 likes~=20000` + OK.

Run: `clojure -M -e "(require '[xitdb.db :as xdb]) (with-open [db (xdb/xit-db \"/tmp/xb-clj/feed-clj.xitdb\")] (println (xdb/db-mode db)) (println (get-in @db [\"posts\" \"1\" \"author\"])))"` (run with the probe classpath: `CLJ_CONFIG`/`-Sdeps` pointing at a deps map with xitdb-clj 0.7.2, or reuse `/tmp/clj-probe`)
Expected: `:compat` + the golden-small post-1 author.

- [ ] **Step 4: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add seed && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: history-rooted clj seed flavor"
```

### Task 2: Pure validation + auth

**Files:**
- Create: `servers/clj-httpkit/deps.edn`, `src/validate.clj`, `src/auth.clj`, `test/validate_test.clj`, `test/auth_test.clj`
- Test: `clojure -M:test` (add a `:test` alias running cognitect test-runner? NO new dep — use `clojure -M -e "(require ...)(run-tests ...)"`; plan states the exact command)

**Interfaces:**
- Consumes: none.
- Produces:
  - `feed-key [created-at id]`, `valid-post-id [s]` (→ long/nil), `trim-body [b]` (→ `[true v]` / `[false msg]`)
  - `verify-jwt [token secret]` (→ `{:user-id :username}` / `{:error msg}`)

- [ ] **Step 1: Write failing tests**

```clojure
;; validate-test: feed-key format+ordering; valid-post-id table ("1"->1, "0","-1","abc","1.5",""->nil, 2^64->nil);
;; trim-body: padded/trims, whitespace/numeric/missing->required, 501->too-long, 500 ok, 500xé ok
;; auth-test: good->{1,"alice"}; bad-sig/expired-1h/garbage/alg-none->token error;
;;   string/numeric sub, missing/numeric username->payload error; expired-30s->ok (leeway_parity)
```

(Sign test tokens with `buddy.sign.jwt/sign` HS256 + hand-built `alg:none` token.)

- [ ] **Step 2: Run to verify fail**

Run: `clojure -M:test -e "(require 'validate-test 'auth-test) ((requiring-resolve 'clojure.test/run-tests) 'validate-test 'auth-test)"`
Expected: FAIL — namespaces missing.

- [ ] **Step 3: Implement `deps.edn` + `src/*.clj`** with the exact signatures. JWT via `buddy.sign.jwt/unsign` `{:alg :hs256}` plus `:leeway 60` if honored (else manual `exp` check: accept when `(- now exp) <= 60`); `sub`/`username` type-checked by hand (`string?`, digits, unsigned range).

- [ ] **Step 4: Run to verify pass**

Run: same as Step 2.
Expected: PASS, zero failures.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/clj-httpkit && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: clj pure validation + jwt vectors"
```

### Task 3: Store + HTTP server + wiring

**Files:**
- Create: `servers/clj-httpkit/src/{store,server}.clj`, `test/store_test.clj`, `build.clj`
- Modify: `servers/clj-httpkit/{install,build,start}.sh`, `servers/clj-httpkit/README.md`
- Test: `clojure` suite + live small-DB smoke with curl

**Interfaces:**
- Consumes: validate/auth from Task 2.
- Produces: listening server honoring env; exact bytes per SPEC-XITDB.

- [ ] **Step 1: Write failing store tests** (`:memory` DBs + one temp-file durability test)

```clojure
;; round-trip: create -> id 1/trimmed/count 0/createdAt regex; get 1 equals; get 999 nil; 2nd create -> feed ids [2 1]
;; like: first false->200-shape {:already false}, repeat {:already true}, count 1, missing nil
;; missing: get/like nil, empty feed [], health true
;; durability: temp file db, create, close, reopen, getPost found (proves flush+sync path)
;; feed window: 25-post fixture -> get-feed returns newest 20 (proves count+page)
```

- [ ] **Step 2: Run to verify fail**

Run: `clojure -M:test -e "(require 'store-test) ((requiring-resolve 'clojure.test/run-tests) 'store-test)"`
Expected: FAIL — `store.clj` missing.

- [ ] **Step 3: Implement `src/store.clj`**: `open-store` (`xit-db` path, no opts — file's own header decides mode); reads via `@db` + `get-in`; feed via `(take 20 (reverse (xs/page feed (max 0 (- (count feed) 20)) 20)))`; mutations via single `swap!` each building the full new moment with `assoc-in` (posts/feed-entry/likes-set/meta-next), then `(.sync (.-core (.-rwdb db)))`; `post->json` manual framing with `cheshire/generate-string` per string. `src/server.clj`: Ring handler (method+uri switch, `slurp` body in try/catch, auth-then-id, `uptime_s`, 404 fallback), `run-server` + `-main` blocking on `@(promise)`; responses `{:status :headers {"Content-Type" "application/json"} :body}`.

- [ ] **Step 4: Wire scripts + smoke**: `install.sh` (Temurin 21 + Clojure CLI 1.12.6.1673 tarballs), `build.sh` (`clojure -T:build uber`), `start.sh` (`exec java -Xmx1g -jar target/server.jar`); README (mirror go README + history-root + sync notes). Smoke on fresh small `feed-clj`: post-1 bytes + feed 20 + create/like round-trip via curl.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/clj-httpkit && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: clj http-kit feed server"
```

### Task 4: Gate + CI + docs

**Files:**
- Modify: `harness/run.sh` (`FLAVOR` env, default `hashmap`: selects `--flavor` + `feed*.xitdb` name), `.github/workflows/ci.yml` (add `clj-httpkit` job), `LEADERBOARD-XITDB.md` (clj row)
- Test: `harness/run.sh` (small + full, `FLAVOR=history`) + k6 smoke

**Interfaces:**
- Consumes: Tasks 1–3 + committed goldens (reused unchanged — content is flavor-independent).
- Produces: leaderboard clj row (local numbers, labeled).

- [ ] **Step 1: Extend `run.sh` compatibly** (`FLAVOR="${FLAVOR:-hashmap}"`; generator gets `--flavor $FLAVOR`; `XITDB_PATH` points at `feed.xitdb` or `feed-clj.xitdb` accordingly; golden dir unchanged) + re-run `contracts.sh` + one rust small gate (proves default path untouched).

- [ ] **Step 2: Run small gate**

Run: `FLAVOR=history bash harness/run.sh servers/clj-httpkit 2>&1 | tail -2`
Expected: `passed=42 failed=0`.

- [ ] **Step 3: Run full gate**

Run: `FLAVOR=history SIZE=full bash harness/run.sh servers/clj-httpkit 2>&1 | tail -2`
Expected: `passed=42 failed=0`.

- [ ] **Step 4: k6 smoke** (persistent full clj seed + fresh copy, VUS=50/30s; same shape as the ts-bun step with `TOKENS=/tmp/xb-clj-k6/tokens.json`) + CI job (`DeLaGuardo/setup-clojure@13`: `clojure-version 1.12.6.1673`, JDK 21) + leaderboard row.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add -A && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: clj-httpkit green small+full + ci"
```
