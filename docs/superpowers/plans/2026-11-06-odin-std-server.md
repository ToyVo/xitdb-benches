# Odin/std Feed Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conformant `$12`-challenge feed server in `servers/odin-std` (hand-rolled HTTP/1.1 on `core:net` + vendored `odin-xitdb`), green on the committed goldens.

**Architecture:** Mirror of the references: `database_init` + HashMap root with the 5 frozen collections; reads via `*_get_cursor` (no txn), mutations via single `database_run_context` each plus an explicit `core_sync` if the commit path leaves the header un-synced (verify at implementation — the sibling impls all do); thread per connection under one mutex; compact JSON with fixed field order.

**Tech Stack:** Odin dev-2026-10, vendored `odin-xitdb` (`vendor/xitdb/`, MIT), std-only everything (`core:net`, `core:thread`, `core:sync`, `core:crypto/hmac`+`sha2`, `core:encoding/base64`, hand-rolled JSON framing).

**Spec:** `/Users/collindie/Code/xitdb-benches/SPEC-XITDB.md` + `/Users/collindie/Code/xitdb-benches/schema-xitdb.md`; behavior reference `servers/go-std/*.go` + `servers/zig-std/src/main.zig` (route edge cases: multi-slash like → 404, frameless POST handling); goldens `harness/golden-{small,full}/` (fixed targets — NEVER regenerate).

## Global Constraints

- Repo root: `/Users/collindie/Code/xitdb-benches`; `servers/odin-std/` Odin package (`src/` package main, `tests/` package `server_tests`, `vendor/xitdb/`); every task ends committed there.
- xitdb vendored at commit `b760ee9d6ff4b54421d0272c12f74d62c12c4856` (2026-11-06) with `vendor/README.md` (source + sha + date + MIT note); no network at build time. Internal imports use relative paths (`import xitdb "../vendor/xitdb"` from `src/`, mirroring upstream's own `import xitdb "../xitdb"` test pattern).
- DB: buffered file core + `database_init(&core, sha1_hasher())`; string keys hashed internally (no manual hashing — unlike Zig); commit path must leave data+header durable before 201 (prove with the Task 3 durability test; add explicit `core_sync` after each mutating txn if the path doesn't).
- Layout frozen: root keys `users,posts,feed,likes,meta`; `feedKey = createdAt + "\x00" + zero-padded-10 id` (Odin strings support `\x00` escapes); post JSON key order identical; `Content-Type: application/json`.
- Env: `XITDB_PATH`, `JWT_SECRET=twelve-dollar-challenge`, `HOST=127.0.0.1`, `PORT=3000`; server-borne keep-alive (held open until client closes; no idle-timeout knob to misconfigure).
- HTTP/1.1 hand-rolled: parse request line + headers (need: `authorization`, `content-length`, `expect`), route on method + query-stripped path, read exactly `content-length` bytes for `POST /posts` (other routes ignore the body; frameless body-methods get a normal response with `connection: close`, mirroring the Zig fix — std has no discard helper here either).
- Auth: hand-rolled HS256 — 3 parts, base64url-decode header, require `"alg":"HS256"` (parsed, not substring-matched), HMAC-SHA256 over `header.payload` with loop-accumulated constant-time compare, base64url-decode payload, `sub` = all-digit string `≥1` (full u64, miss → 404, matching Rust/Go/Zig), `username` = string, numeric `exp` with 60s leeway; verify every request; auth-before-id.
- Body rule: ASCII-whitespace trim, empty → required; UTF-8 codepoint count `> 500` → too-long (rune semantics, matching Rust/Go/Zig).
- `created_at`: millis wall-clock → hand-rolled civil-date `YYYY-MM-DDTHH:MM:SS.mmmZ` UTC (port the proven algorithm from `zig-std/src/validate.zig`, vectors included).
- `POST /:id/like`: `201 already_liked:false` first, `200 already_liked:true` repeat, count bumps once, atomic in one txn.
- Route parity with the references: multi-segment like ids (`/posts/a/b/like`) and unknown paths → 404 `not found` (NOT 400); `GET /posts/abc` → 400.

## Review Focus

- String-key hashing is internal here — but a wrong hasher/empty id on open silently misses everything (all reads 404, no error) — pinned in Task 2 (round-trip on a fresh DB) + Task 3 (smoke on the TS-written seed proves cross-impl agreement).
- Header durability after commit (the sibling impls all need an explicit post-commit sync) — pinned in Task 3 (write → close → reopen → read-back test).
- Hand-rolled HTTP framing risks: hanging on unknown-length bodies, breaking keep-alive reuse, mis-parsing folded/continued headers — pinned in Task 3 (smoke covers keep-alive reuse across mixed routes; suite's connection patterns prove it in Task 4).
- Hand-rolled JWT attack surface: `alg:none`, bad signature (non-constant-time compare would also count), ignored `exp`, type-confused claims — pinned in Task 1 (one vector each).
- Civil-date math (leap days, millis rollover) — pinned in Task 1 (epoch, 2024-01-01, 2024-03-01 leap, seed-timestamp vectors, same values as the Zig suite).

---

## File Structure

`servers/odin-std/` (existing stubs replaced):

- `vendor/xitdb/` + `vendor/README.md` (source, sha, date, MIT note).
- `src/validate.odin` — pure, testable: `feed_key`, `valid_post_id`, `trim_body`, `format_millis`, `hash not needed (internal)`.
- `src/auth.odin` — `verify_jwt` returning `(Auth_Ok, Auth_Err)` + `b64url_decode`, constant-time `secure_equal`.
- `src/store.odin` — `open_store`, `health`, `get_feed`, `get_post`, `create_post`, `like_post`, `Post` struct + `post_json` (manual framing, per-string escape helper for `"` `\` + `<0x20` → `\u00XX`).
- `src/main.odin` — `core:net` listen/accept loop, `core:thread` per conn (detached), shared mutex, request parse/route/respond, env wiring.
- `tests/*_test.odin` — package `server_tests`, `@(test)` procs, `core:testing` expects; store tests on temp-file DBs (never seed files); run via `odin test tests/`.
- `install.sh` (pinned `odin-linux-amd64-dev-2026-10.tar.gz`) / `build.sh` (`odin build src -out:server -o:speed`) / `start.sh` (`exec ./server`); `README.md` (mirror zig README + hand-rolled-HTTP note).

Reference reads: vendored `xitdb/{database,collections,cursor}.odin` (init/run_context/get/put/count/get_index/pagination procs, `Writeable_Data` constructors, `core_sync`), `zig-std/src/{validate.zig,main.zig}` (civil algorithm + keep-alive/edge-case handling to mirror).

---

### Task 1: Vendor + pure validation + auth

**Files:**
- Create: `servers/odin-std/vendor/xitdb/` (copy), `vendor/README.md`, `src/validate.odin`, `src/auth.odin`, `tests/validate_test.odin`, `tests/auth_test.odin`
- Test: `odin test tests/`

**Interfaces:**
- Consumes: none.
- Produces:
  - `feed_key(created_at: string, id: u64) -> string`
  - `valid_post_id(s: string) -> (u64, bool)`
  - `trim_body(s: string) -> (string, string)` (value + `""`, or `""` + message)
  - `format_millis(ms: i64) -> string`
  - `verify_jwt(token, secret: string, now_s: i64) -> (Auth_Ok, Auth_Err)` (exactly one set)

- [ ] **Step 1: Vendor the library**

Run: `git clone --depth 1 https://github.com/boxxxie/odin-xitdb /tmp/odin-xitdb-src && cp -r /tmp/odin-xitdb-src/xitdb servers/odin-std/vendor/ && du -sh servers/odin-std/vendor/xitdb`
Expected: `vendor/xitdb/` lands (~600KB); record commit `b760ee9...` + date in `vendor/README.md`.

- [ ] **Step 2: Write failing tests** (`@(test)` procs)

```odin
@(test) test_feed_key :: proc(t: ^testing.T) { /* "...\x000000000007" + ordering */ }
@(test) test_post_ids :: proc(t: ^testing.T) { /* "1"→1; "0","-1","abc","1.5",""→invalid; u64-max→valid */ }
@(test) test_trim_body :: proc(t: ^testing.T) { /* padded/whitespace/501/500/500xé */ }
@(test) test_format_millis :: proc(t: ^testing.T) { /* epoch, 2024-01-01, 2024-03-01, seed ts */ }
@(test) test_jwt_vectors :: proc(t: ^testing.T) { /* good/bad-sig/expired/garbage/alg-none/numeric+missing claims/30s-leeway */ }
```

(Sign test tokens with the implementation's own HMAC helper + a hand-built `alg:none` token.)

- [ ] **Step 3: Run to verify fail**

Run: `odin test tests/ 2>&1 | tail -5`
Expected: FAIL — `validate.odin`/`auth.odin` missing (vendor itself must load cleanly).

- [ ] **Step 4: Implement `src/validate.odin` + `src/auth.odin`** with the exact signatures. Auth: split `.` (3 parts), b64url-decode header → parsed `alg` must equal `HS256`, HMAC-SHA256 over the joined first two segments → accumulate `|=` differences (constant-time), b64url-decode payload → minimal JSON field extraction for `sub`/`username`/`exp` with type checks + 60s leeway on numeric exp.

- [ ] **Step 5: Run to verify pass**

Run: `odin test tests/ 2>&1 | tail -3`
Expected: PASS, zero failures.

- [ ] **Step 6: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/odin-std && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: odin vendor + validation + jwt vectors"
```

### Task 2: Store over vendored xitdb

**Files:**
- Create: `servers/odin-std/src/store.odin`, `tests/store_test.odin`
- Test: `odin test tests/`

**Interfaces:**
- Consumes: `feed_key/valid_post_id` from Task 1.
- Produces: `open_store/health/get_feed/get_post/create_post/like_post` + `Post` + `post_json` per File Structure.

- [ ] **Step 1: Write failing store tests** (temp-file DBs, hand-seeded through the store)

```odin
@(test) test_store_round_trip :: proc(t: ^testing.T) { /* create→id 1/trimmed/count 0/created_at shape; get 1 equals; get 999→nil; 2nd→feed [2,1] */ }
@(test) test_store_like :: proc(t: ^testing.T) { /* false→true, count 1, missing→nil */ }
@(test) test_store_missing :: proc(t: ^testing.T) { /* get/like nil, empty feed, health true */ }
@(test) test_txn_rule :: proc(t: ^testing.T) { /* putCursor-descend outside run_context: record behavior (Rust throws / Go+Zig allow); whichever → ledgered ruling, planned shape kept */ }
```

- [ ] **Step 2: Run to verify fail**

Run: `odin test tests/ 2>&1 | tail -5`
Expected: FAIL — `store.odin` missing.

- [ ] **Step 3: Implement `src/store.odin`**: open buffered file + `database_init(&core, sha1_hasher())`; root via read/write hash-map inits; reads descend with `hash_map_get_cursor` (nil = absent); mutations in `database_run_context` ctx procs with `put_cursor` + sorted/set inits; feed = `sorted_map_count` → `sorted_map_get_index_kv_pair(start..count)` → point gets → reverse; `post_json` manual framing with the escape helper. Prove-or-add the post-commit `core_sync` here (durability test in Task 3 gates it).

- [ ] **Step 4: Run to verify pass**

Run: `odin test tests/ 2>&1 | tail -3`
Expected: PASS, Tasks 1+2 green.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/odin-std && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: odin xitdb store + like/feed semantics"
```

### Task 3: HTTP server + wiring

**Files:**
- Create: `servers/odin-std/src/main.odin`; Modify: `servers/odin-std/{install,build,start}.sh`, `servers/odin-std/README.md`
- Test: live small-DB smoke with curl + a durability check (write → close → reopen → read-back)

**Interfaces:**
- Consumes: `Store` + validate/auth from Tasks 1–2.
- Produces: listening server honoring env; exact bytes per SPEC-XITDB.

- [ ] **Step 1: Write the failing smoke** (nothing serving)

Run: `PORT=3014 bash servers/odin-std/start.sh & sleep 1; curl -sf http://127.0.0.1:3014/health; echo "EXIT:$?"`
Expected: FAIL — `server` binary missing.

- [ ] **Step 2: Implement `src/main.odin`**: `net.listen_tcp` + accept loop with `thread.create_and_start` per conn (detached) under one mutex; per-conn keep-alive loop (parse request line + headers, route, `content-length`-gated body read for `POST /posts` only, respond with content-length, close on frameless body-methods or client close); auth-before-id; `uptime_s`; catch-all 404; env wiring with sane defaults.

- [ ] **Step 3: Wire scripts + README**: `install.sh` (pinned `odin-linux-amd64-dev-2026-10.tar.gz`), `build.sh` (`cd "$(dirname "$0")" && odin build src -out:server -o:speed`), `start.sh` (`exec "$(dirname "$0")/server"`); README (run block, Nginx-or-direct, thread-per-conn model, vendoring note, hand-rolled-HTTP note, optimizations — mirror zig README + durability note).

- [ ] **Step 4: Run smoke + durability to verify pass** (fresh small seed)

Run: `cp /tmp/xb-small/feed.xitdb /tmp/xb-odin-smoke.db && XITDB_PATH=/tmp/xb-odin-smoke.db PORT=3014 ./servers/odin-std/server & sleep 2; curl -s http://127.0.0.1:3014/posts/1 | head -c 120; curl -s http://127.0.0.1:3014/feed | python3 -c "import json,sys;print(len(json.load(sys.stdin)['posts']))"`
Expected: post-1 bytes + `20`. Then: create+like via curl, kill server, reopen DB read-back of the created post (durability gate for the `core_sync` decision).

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/odin-std && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: odin http feed server"
```

### Task 4: Gate + CI + docs

**Files:**
- Modify: `.github/workflows/ci.yml` (add `odin-std` job), `LEADERBOARD-XITDB.md` (odin row)
- Test: `harness/run.sh` (small + full) + k6 smoke

**Interfaces:**
- Consumes: Tasks 1–3 + committed goldens (targets, never regenerated).
- Produces: leaderboard odin row (local numbers, labeled).

- [ ] **Step 1: Run small gate**

Run: `bash harness/run.sh servers/odin-std 2>&1 | tail -2`
Expected: `passed=42 failed=0`.

- [ ] **Step 2: Run full gate**

Run: `SIZE=full bash harness/run.sh servers/odin-std 2>&1 | tail -2`
Expected: `passed=42 failed=0`.

- [ ] **Step 3: k6 smoke** (persistent full seed + fresh copy, VUS=50/30s)

Run: `bun ./seed/generate-xitdb.ts --full /tmp/xb-odin-k6 && cp /tmp/xb-odin-k6/feed.xitdb /tmp/xb-odin-k6run.db && (XITDB_PATH=/tmp/xb-odin-k6run.db PORT=3000 ./servers/odin-std/server &) && sleep 2 && k6 run -e BASE_URL=http://127.0.0.1:3000 -e VUS=50 -e DURATION=30s -e RAMP_UP=10s -e TOKENS=/tmp/xb-odin-k6/tokens.json harness/bench/load.js 2>&1 | grep -E "p\(95\)|p\(99\)|checks_failed"; pkill -f 'odin-std/server'`
Expected: thresholds `✓`, `0.00%`.

- [ ] **Step 4: Add CI job** (`laytan/setup-odin@v2` with `release: dev-2026-10` + `bash harness/run.sh servers/odin-std`, small) and record local numbers in `LEADERBOARD-XITDB.md` odin row.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add -A && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: odin-std green small+full + ci"
```
