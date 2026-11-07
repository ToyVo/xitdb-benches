# Zig/std Feed Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conformant `$12`-challenge feed server in `servers/zig-std` (Zig 0.17 `std.http.Server` + vendored reference `xitdb`), green on the committed goldens.

**Architecture:** Mirror of the Rust/Go/TS references: `Database(.file, u160)` root `HashMap` with the 5 frozen collections; reads via `getCursor` (no txn), mutations via single `runContext` each with `fsync:true`; `std.Thread` per connection under one `std.Thread.Mutex` (stdlib-spawned concurrency, one writer at a time); compact JSON with declaration-ordered keys.

**Tech Stack:** Zig 0.17.0, no dependencies (vendored `xitdb` `src/lib.zig`, MIT; std-only HTTP/JWT/JSON: `std.http.Server`, hand-rolled HS256 over `std.crypto`, `std.json.Stringify`).

**Spec:** `/Users/collindie/Code/xitdb-benches/SPEC-XITDB.md` + `/Users/collindie/Code/xitdb-benches/schema-xitdb.md`; behavior reference `servers/rust-axum/src/main.rs` + `servers/go-std/*.go`; goldens `harness/golden-{small,full}/` (fixed targets — NEVER regenerate).

## Global Constraints

- Repo root: `/Users/collindie/Code/xitdb-benches`; `servers/zig-std/` Zig package (`build.zig`, `build.zig.zon`); every task ends committed there.
- xitdb vendored at `servers/zig-std/vendor/lib.zig` (exact upstream `src/lib.zig`, MIT, with `vendor/README.md` recording source URL + sha + date); no network at build time.
- DB type: `xitdb.Database(.file, u160)`; open with `hash_id = HashId.fromBytes("sha1")`, `fsync = true`; hasher pattern from upstream `test.zig`: `Sha1.hash(key) → readInt(u160, big)` for EVERY `HashMap`/`HashSet` key (the binding hashes nothing for you — `getCursor`/`put` take `u160`).
- Layout frozen: root keys (hashed) `users,posts,feed,likes,meta`; `feedKey = createdAt + "\x00" + zero-padded-10 id` (byte-string `SortedMap` keys need no hashing); post key order `id,body,created_at,author,like_count`; `Content-Type: application/json`.
- Env: `XITDB_PATH`, `JWT_SECRET=twelve-dollar-challenge`, `HOST=127.0.0.1`, `PORT=3000`; connections stay open until the client closes (trivially satisfies the ≥65s Nginx rule; no idle-timeout knob to misconfigure).
- Auth: hand-rolled HS256 — split 3 parts, base64url-decode header, parse `{alg,typ}` and require `alg == "HS256"`, `HmacSha256` verify with `timing.safeEqual`, base64url-decode payload, `sub` = all-digit string `≥1`, `username` = string, `exp` numeric with 60s leeway (parity with Rust/Go/TS); verify every request, no memoization; auth-before-id.
- Body rule: ASCII-whitespace trim (`std.mem.trim(u8, s, &std.ascii.whitespace)`), empty → required; `utf8CountCodepoints > 500` → too-long (rune semantics, matching Rust/Go).
- Id rule: all-ASCII-digits, `parseUnsigned(u64)`, `≥1`; full u64 range accepted (miss → 404), matching Rust/Go (NOT the TS 2^53 cap — spec-silent; pinned by test).
- `created_at`: hand-rolled millis→`YYYY-MM-DDTHH:MM:SS.mmmZ` UTC (`formatMillis`, civil-date algorithm), always 3-digit millis.
- `POST /:id/like`: `201 already_liked:false` first, `200 already_liked:true` repeat, count bumps once, atomic in one `runContext`.

## Review Focus

- `HashMap`/`HashSet` take `u160` hashes, not strings — an unhashed lookup silently misses (404s everywhere, no error) — pinned in Task 2 (round-trip on a hashed seed + Task 3 smoke on the TS-written seed proves cross-impl hash agreement).
- `putCursor`-outside-`runContext` behavior (Rust throws, Go allows) — pinned in Task 2 (`txn rule` probe; whichever it is gets a ledgered ruling, planned shape kept).
- Full-u64 id accepted with miss→404 (Rust/Go-consistent, TS-divergent) — pinned in Task 1 (`u64 max valid`) + Task 2 (miss → null).
- Hand-rolled JWT attack surface: `alg:none` accepted, bad signature accepted, `exp` ignored, or non-constant-time compare — pinned in Task 1 (one failing vector each).
- `formatMillis` civil math (leap days, month lengths, negative/millis rollover) — pinned in Task 1 (epoch, 2024-01-01, 2024-03-01 leap, seed-timestamp vectors).

---

## File Structure

`servers/zig-std/` (existing stubs replaced):

- `vendor/lib.zig` + `vendor/README.md` (source, sha, date, MIT note).
- `build.zig` (`exe` ReleaseFast + `test` step), `build.zig.zon` (no deps).
- `src/validate.zig` — pure, testable: `feedKey(alloc, createdAt, id)`, `validPostId(s) ?u64`, `trimBody(s) TrimResult`, `formatMillis(alloc, ms)`, `hashKey(s) u160`.
- `src/auth.zig` — `verifyJWT(alloc, token, secret, now_s) AuthResult` (`{user_id, username}` or `{err: msg}`), `base64UrlDecode`, constant-time compare.
- `src/store.zig` — `Store{ db, mutex, secret, boot_ms }`, `openStore(alloc, path, secret)`, `health/deinit`, `getFeed(alloc)`, `getPost(alloc, id)`, `createPost(alloc, username, body)`, `likePost(alloc, id, user_id)`; `Post` struct + `postJson(alloc, p)` (manual framing, `std.json.Stringify` per string).
- `src/main.zig` — `std.http.Server` accept loop, `std.Thread.spawn` per conn (detached), routes, `(handler) uptime_ms`, env wiring.
- Inline `test` blocks in each `src/*.zig` — `zig build test` (store tests on `testing.tmpDir` file DBs, never seed files). Single package: files wire via relative `@import("validate.zig")` / `@import("vendor/lib.zig")` from `src/`.
- `install.sh` (pinned zig 0.17.0 tarball) / `build.sh` (`zig build -Doptimize=ReleaseFast`) / `start.sh` (`exec ./zig-out/bin/server`); `README.md` (mirror go README + vendoring note + single-thread→thread-per-conn model).

Reference reads: upstream `src/test.zig` (`hashInt`, `DB.init` per kind, `runContext` usage, `ExpectedTxStart` probe), `src/lib.zig` (`HashMap`/`SortedMap`/`HashSet` method lists, `InitOptsFile`, `KeyValuePairCursor{valueCursor,...}`, `Iter`).

---

### Task 1: Vendor + pure validation + auth

**Files:**
- Create: `servers/zig-std/vendor/lib.zig`, `vendor/README.md`, `build.zig`, `build.zig.zon`, `src/validate.zig`, `src/auth.zig` (+ inline tests)
- Test: `zig build test`

**Interfaces:**
- Consumes: none.
- Produces:
  - `hashKey(s: []const u8) u160` (Sha1 → big-endian u160)
  - `feedKey(alloc, createdAt: []const u8, id: u64) ![]u8`
  - `validPostId(s: []const u8) ?u64`
  - `trimBody(s: []const u8) TrimResult` (`{ .ok: []const u8 } | { .err: [:0]const u8 }` with the two spec messages)
  - `formatMillis(alloc, ms: i64) ![]u8`
  - `verifyJWT(alloc, token: []const u8, secret: []const u8, now_s: i64) !AuthResult`

- [ ] **Step 1: Vendor lib.zig** (pinned commit, not floating master)

Run: `curl -sL https://raw.githubusercontent.com/xit-vcs/xitdb/<SHA>/src/lib.zig -o servers/zig-std/vendor/lib.zig && wc -c servers/zig-std/vendor/lib.zig`
Expected: file lands (~265KB); record the SHA + date in `vendor/README.md` (with the MIT attribution line).

- [ ] **Step 2: Write failing tests** (inline `test` blocks in the new files)

```zig
test "feedKey" { /* "...\x000000000007" + ordering */ }
test "post ids" { /* "1"→1; "0","-1","abc","1.5",""→null; "18446744073709551615"→max (u64 max valid) */ }
test "trimBody" { /* "  hi "→"hi"; spaces→required; 501×'a'→too-long; 500×'b' + 500×'é' ok */ }
test "formatMillis" { /* 0→1970-01-01T00:00:00.000Z; 1704067200000→2024-01-01T00:00:00.000Z;
                         1709251200000→2024-03-01T00:00:00.000Z (leap); 1735680034152→2025-01-01T00:00:34.152Z */ }
test "jwt vectors" { /* good→{1,"alice"}; bad-sig/expired-1h/garbage/alg-none→token error;
                        sub "abc"/numeric sub/missing+numeric username→payload error; expired-30s→ok */ }
```

- [ ] **Step 3: Run to verify fail**

Run: `zig build test 2>&1 | tail -5`
Expected: FAIL — `validate.zig`/`auth.zig` missing (vendor fetch itself must succeed).

- [ ] **Step 4: Implement `src/validate.zig` + `src/auth.zig`** with the exact signatures. Auth: split on `.` (3 parts), `base64.url_safe_no_pad` decode header → `std.json.parseFromSlice(struct{alg: []u8, typ: []u8})` → `alg` must equal `HS256`; `HmacSha256.create(mac, msg, key)` over `header_b64.payload_b64` → `timing.safeEqual`; payload parsed into `struct{ sub: json.Value, username: json.Value, exp: json.Value }` with `typeof`-equivalent checks (string vs number vs null) + 60s leeway on numeric exp.

- [ ] **Step 5: Run to verify pass**

Run: `zig build test 2>&1 | tail -3`
Expected: PASS, zero failures.

- [ ] **Step 6: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/zig-std && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: zig vendor + validation + jwt vectors"
```

### Task 2: Store over vendored xitdb

**Files:**
- Create: `servers/zig-std/src/store.zig` (+ inline tests)
- Test: `zig build test`

**Interfaces:**
- Consumes: `feedKey/validPostId/hashKey` from Task 1.
- Produces: `Store` + `openStore/health/getFeed/getPost/createPost/likePost` + `Post` + `postJson` per File Structure.

- [ ] **Step 1: Write failing store tests** (temp file DBs via `testing.tmpDir`, hand-seeded through the store)

```zig
test "store round trip" { /* empty→create("alice","hi")→id 1/trimmed/count 0/createdAt regex-ish (len 24, ends 'Z');
                             getPost(1) equals; getPost(999)→null; 2nd create→feed [2,1] */ }
test "store like idempotent" { /* (false found)(true found), count 1, like(999)→null */ }
test "store missing keys" { /* getPost→null, like→null, empty feed→0 items, health true */ }
test "txn rule" { /* putCursor-descend outside runContext: record behavior (Rust throws / Go allows);
                     whichever → ledgered ruling, planned shape (reads getCursor, writes runContext) kept */ }
```

- [ ] **Step 2: Run to verify fail**

Run: `zig build test 2>&1 | tail -5`
Expected: FAIL — `store.zig` missing.

- [ ] **Step 3: Implement `src/store.zig`**: `DB = lib.Database(.file, u160)`; `openStore` opens/creates the file (`Dir.cwd().createFile`), `DB.init(io, .{ .file, .hash_id = fromBytes("sha1"), .fsync = true })`; root via `DB.HashMap(.read_write).init(db.rootCursor())`; reads descend with `getCursor(hashKey(..))` (`null` = absent); mutations in `db.runContext(struct{...}{}.run)`-style ctx with `putCursor` + `SortedMap/HashSet` inits; feed = `count()` → `getIndexKeyValuePair(start..count)` → `valueCursor.readBytesAlloc` ids → point gets → reverse; `postJson` manual framing with `std.json.Stringify` per string into an `Allocating` writer.

- [ ] **Step 4: Run to verify pass**

Run: `zig build test 2>&1 | tail -3`
Expected: PASS, Tasks 1+2 green.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/zig-std && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: zig xitdb store + like/feed semantics"
```

### Task 3: HTTP server + wiring

**Files:**
- Create: `servers/zig-std/src/main.zig`; Modify: `servers/zig-std/{install,build,start}.sh`, `servers/zig-std/README.md`
- Test: live small-DB smoke with curl

**Interfaces:**
- Consumes: `Store` + validate/auth from Tasks 1–2.
- Produces: listening server honoring env; exact bytes per SPEC-XITDB.

- [ ] **Step 1: Write the failing smoke** (nothing serving)

Run: `PORT=3013 bash servers/zig-std/start.sh & sleep 1; curl -sf http://127.0.0.1:3013/health; echo "EXIT:$?"`
Expected: FAIL — `zig-out/bin/server` missing.

- [ ] **Step 2: Implement `src/main.zig`**: `std.http.Server.init(alloc, .{ .reuse_address = true })`, `listen(addr)`, accept loop with `std.Thread.spawn(.{}, handleConn, .{...})` detached; per-conn arena allocator; parse `request.head.{method,target}` + headers (Authorization) + full body; route table mirroring the Go server (incl. auth-before-id, `uptime_s`, catch-all 404); `respond(conn, status, json_body)` with `content-type: application/json` + `content-length`, keep-alive by default (only close on client close / parse error).

- [ ] **Step 3: Wire scripts + README**: `install.sh` (pinned zig 0.17.0 linux tarball, `install.sh` pattern from go-std), `build.sh` (`cd "$(dirname "$0")" && zig build -Doptimize=ReleaseFast`), `start.sh` (`exec "$(dirname "$0")/zig-out/bin/server"`); README (run block, Nginx-or-direct, thread-per-conn model, vendoring note, optimizations — mirror go README + `fsync:true` durability note).

- [ ] **Step 4: Run smoke to verify pass** (fresh small seed)

Run: `cp /tmp/xb-small/feed.xitdb /tmp/xb-zig-smoke.db && XITDB_PATH=/tmp/xb-zig-smoke.db PORT=3013 ./servers/zig-std/zig-out/bin/server & sleep 2; curl -s http://127.0.0.1:3013/posts/1 | head -c 120; curl -s http://127.0.0.1:3013/feed | python3 -c "import json,sys;print(len(json.load(sys.stdin)['posts']))"`
Expected: post-1 bytes + `20`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/zig-std && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: zig std http feed server"
```

### Task 4: Gate + CI + docs

**Files:**
- Modify: `.github/workflows/ci.yml` (add `zig-std` job), `LEADERBOARD-XITDB.md` (zig-std row)
- Test: `harness/run.sh` (small + full) + k6 smoke

**Interfaces:**
- Consumes: Tasks 1–3 + committed goldens (targets, never regenerated).
- Produces: leaderboard zig-std row (local numbers, labeled).

- [ ] **Step 1: Run small gate**

Run: `bash harness/run.sh servers/zig-std 2>&1 | tail -2`
Expected: `passed=42 failed=0`.

- [ ] **Step 2: Run full gate**

Run: `SIZE=full bash harness/run.sh servers/zig-std 2>&1 | tail -2`
Expected: `passed=42 failed=0`.

- [ ] **Step 3: k6 smoke** (persistent full seed + fresh copy, VUS=50/30s)

Run: `bun ./seed/generate-xitdb.ts --full /tmp/xb-zig-k6 && cp /tmp/xb-zig-k6/feed.xitdb /tmp/xb-zig-k6run.db && (XITDB_PATH=/tmp/xb-zig-k6run.db PORT=3000 ./servers/zig-std/zig-out/bin/server &) && sleep 2 && k6 run -e BASE_URL=http://127.0.0.1:3000 -e VUS=50 -e DURATION=30s -e RAMP_UP=10s -e TOKENS=/tmp/xb-zig-k6/tokens.json harness/bench/load.js 2>&1 | grep -E "p\(95\)|p\(99\)|checks_failed"; pkill -f 'zig-out/bin/server'`
Expected: thresholds `✓`, `0.00%`.

- [ ] **Step 4: Add CI job** (`mlugg/setup-zig@v2` with `version: 0.17.0` + `bash harness/run.sh servers/zig-std`, small) and record local numbers in `LEADERBOARD-XITDB.md` zig-std row.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add -A && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: zig-std green small+full + ci"
```
