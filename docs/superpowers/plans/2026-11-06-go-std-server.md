# Go/std Feed Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conformant `$12`-challenge feed server in `servers/go-std` (stdlib `net/http` + `xitdb-go`), green on the committed goldens.

**Architecture:** Mirror of the Rust reference: root `HashMap` with the 5 frozen collections; reads via `GetCursor` (no txn), mutations via single `RunContext` each; whole-DB `sync.Mutex` (stdlib spawns a goroutine per conn); compact JSON emitted with frozen key order.

**Tech Stack:** Go 1.23, stdlib `net/http` (+ `ServeMux` 1.22 patterns), `github.com/xit-vcs/xitdb-go v0.18.0`, `github.com/golang-jwt/jwt/v5 v5.3.1`.

**Spec:** `/Users/collindie/Code/xitdb-benches/SPEC-XITDB.md` + `/Users/collindie/Code/xitdb-benches/schema-xitdb.md` (frozen layout); behavior reference `/Users/collindie/Code/xitdb-benches/servers/rust-axum/src/main.rs`; goldens `/Users/collindie/Code/xitdb-benches/harness/golden-{small,full}/` (fixed targets — NEVER regenerate in this plan).

## Global Constraints

- Repo root: `/Users/collindie/Code/xitdb-benches`; module `xitdb-bench-go`; `go 1.23`; `go.mod`/`go.sum` committed; every task ends committed there.
- Layout frozen: root keys `users,posts,feed,likes,meta`; `feedKey = createdAt + "\x00" + zero-padded-10 id`; post key order `id,body,created_at,author,like_count`; `Content-Type: application/json`.
- Hasher: `xitdb.Hasher{Hash: sha1.New, ID: xitdb.BytesToID([4]byte{'s','h','a','1'})}` (matches Rust `Sha1Hasher` header); core `xitdb.NewCoreFile(f)`; commit path syncs per txn (`database.go:996-999`), so 201-after-`RunContext`-return means durable.
- Env: `XITDB_PATH` (fresh copy), `JWT_SECRET=twelve-dollar-challenge`, `HOST=127.0.0.1`, `PORT=3000`; `http.Server{IdleTimeout: 70s}` (≥65s Nginx rule).
- Auth: HS256 only, verify signature + `exp` + 60s leeway (parity with Rust `jsonwebtoken` default) every request; `sub` = all-digits `≥1`, `username` = string; auth-before-id.
- Body rule: trim (`strings.TrimSpace`), empty → required; `utf8.RuneCountInString > 500` → too-long (same rune semantics as Rust `chars()`).
- `created_at`: `time.Now().UTC().Format("2006-01-02T15:04:05.000Z")` (always 3-digit millis, UTC, ≤60s drift).
- JSON: `json.Encoder` with `SetEscapeHTML(false)` (seed is pure ASCII so goldens can't diverge, but exactness must not depend on that); trailing newline OK (harness strips one).
- `POST /:id/like`: `201 already_liked:false` first, `200 already_liked:true` repeat, count bumps exactly once, atomic in one `RunContext` under the mutex.

## Review Focus

- Missing-key reads: `GetCursor` on absent `posts/<id>` or absent set member must yield post-not-found / not-liked, never 500 — pinned in Task 2 (`TestMissingKeySemantics`).
- `PutCursor` outside `RunContext`: if `xitdb-go` throws like Rust's `ExpectedTxStart`, all descents stay as planned (reads via `GetCursor`, writes inside txn) — pinned in Task 2 (`TestTxnRule`); any deviation gets a ledgered ruling.
- Overflow id `"18446744073709551616"` (>uint64) must be 400, not 404/500 — pinned in Task 1 (`TestValidPostID/overflow_rejected`).
- 500-char rule on multibyte: 500×`é` accepted, 501×`a` rejected (`RuneCountInString`, matching Rust) — pinned in Task 1 (`TestTrimBody/multibyte_counts_runes`).
- 60s exp leeway parity: token expired 30s ago accepted, expired 1h rejected — pinned in Task 1 (`TestVerifyJWT/leeway_parity`).

---

## File Structure

`servers/go-std/` (existing stubs replaced):

- `go.mod` — `module xitdb-bench-go`, `go 1.23`, pinned `xitdb-go v0.18.0` + `jwt/v5 v5.3.1`; `go.sum` committed.
- `validate.go` — pure fns, no xitdb import: `feedKey(createdAt string, id uint64) string`, `validPostID(s string) (uint64, bool)`, `trimBody(body string) (string, string)` (ok value or error message), `verifyJWT(token, secret string) (userID uint64, username string, errMsg string)` (`""` errMsg = ok).
- `store.go` — `type Store struct { mu sync.Mutex; db *xitdb.Database; secret string; boot time.Time }`, `openStore(path, secret string) (*Store, error)`; `health() bool`; `getFeed() ([]post, error)`; `getPost(id uint64) (*post, bool, error)`; `createPost(user, body string) (post, error)`; `likePost(id, user uint64) (already bool, found bool, error)`; `type post struct { ID uint64; Body, CreatedAt, Author string; LikeCount uint64 }` + `func (p post) json() string`.
- `main.go` — routes only: `GET /health`, `GET /feed`, `GET /posts/{id}`, `POST /posts`, `POST /posts/{id}/like`, fallback 404; `writeJSON(w, status, body)`, `writeErr(w, status, msg)`; `bearer(r)`, auth-then-id ordering in like handler.
- `validate_test.go`, `store_test.go` — Task 1/2 tests (store tests use `t.TempDir()` DBs, never the seed).
- `install.sh`/`build.sh` (`go build -o bin/server .`)/`start.sh` (`exec ./bin/server`, env-honoring) — replace stubs; `README.md` (Nginx-or-direct + optimizations, mirroring rust README).

Reference reads: `xitdb-go` `sorted_map.go` (`Count`, `GetIndexKeyValuePair`), `hashset.go` (`GetCursor`), `database.go` (`RunContext`, `RootCursor`), `hasher.go` (ID pattern in `high_level_test.go:27-36`).

---

### Task 1: Scaffold + pure validation

**Files:**
- Create: `servers/go-std/go.mod`, `servers/go-std/validate.go`, `servers/go-std/validate_test.go`
- Test: `go test ./...` in `servers/go-std`

**Interfaces:**
- Consumes: none (pure).
- Produces:
  - `feedKey(createdAt string, id uint64) string`
  - `validPostID(s string) (uint64, bool)`
  - `trimBody(body string) (trimmed string, errMsg string)` (`""` = ok)
  - `verifyJWT(token, secret string) (userID uint64, username string, errMsg string)` (`""` = ok; else `missing bearer token` is the caller's job — extractor, not this fn)

- [ ] **Step 1: Write failing tests** in `validate_test.go`

```go
func TestFeedKey(t *testing.T) {
    if got := feedKey("2025-01-01T00:00:00.000Z", 7); got != "2025-01-01T00:00:00.000Z\x000000000007" {
        t.Fatalf("bad feedKey %q", got)
    }
    if !(feedKey("2025-01-01T00:00:00.000Z", 7) < feedKey("2025-01-01T00:00:00.000Z", 8)) {
        t.Fatal("feedKey ordering broken")
    }
}
func TestValidPostID(t *testing.T) {
    // "1"->(1,true); "0","-1","abc","1.5",""->(_,false); "999999999" ok
    // "18446744073709551616" (2^64) -> (_,false)   // overflow_rejected
}
func TestTrimBody(t *testing.T) {
    // "  hi "->("hi",""); "   "->(required); 123 handled by caller (non-string);
    // 501x'a'->(too-long); 500x'b' ok; 500x'é' ok  // multibyte_counts_runes
}
func TestVerifyJWT(t *testing.T) {
    // good->(1,"alice",""); bad-sig/expired-1h/garbage/alg-none->"invalid or expired token"
    // sub "abc"/missing username->"invalid token payload"
    // expired-30s->ok                                          // leeway_parity
}
```

(Exact messages: `body is required`, `body must be at most 500 characters`, `invalid or expired token`, `invalid token payload`. Sign test tokens with `jwt.NewWithClaims(HS256, ...)` + crafted `alg:none` token.)

- [ ] **Step 2: Run to verify fail**

Run: `cd servers/go-std && go test ./... 2>&1 | tail -5`
Expected: FAIL — no Go files.

- [ ] **Step 3: Implement `go.mod` + `validate.go`** with the exact signatures above. JWT via `jwt.ParseWithClaims` + `jwt.WithValidMethods([]string{"HS256"})` + `jwt.WithLeeway(60*time.Second)`; claims struct `{Sub string; Username *string (json); Exp *int64 (json)}` — exp enforced by parser, sub/username checked by hand.

- [ ] **Step 4: Run to verify pass**

Run: `cd servers/go-std && go test ./... 2>&1 | tail -3`
Expected: PASS (`ok ... 4/4`-style, zero failures).

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/go-std && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: go pure validation + jwt vectors"
```

### Task 2: Store layer over xitdb-go

**Files:**
- Create: `servers/go-std/store.go`, `servers/go-std/store_test.go`
- Test: `go test -run 'TestStore|TestMissing|TestTxn' ./...`

**Interfaces:**
- Consumes: `feedKey` from Task 1.
- Produces: `Store` + `openStore/health/getFeed/getPost/createPost/likePost` + `post.json()` per File Structure.

- [ ] **Step 1: Write failing store tests** (temp DBs via `t.TempDir()`, hand-seeded through the store itself — never the seed files)

```go
func TestStoreRoundTrip(t *testing.T) {
    // open empty; createPost(7,"  hi ") -> id 1, trimmed, count 0, created_at matches ^\d{4}-...\.000Z$;
    // getPost(1) equals it; getPost(999) -> found=false; getFeed returns newest-first [2,1] after 2nd create
}
func TestStoreLikeIdempotent(t *testing.T) {
    // likePost(1, 7) -> (false,true); again -> (true,true); count==1; likePost(999,7) -> found=false
}
func TestMissingKeySemantics(t *testing.T) {
    // get on absent map keys / absent set member returns found=false with nil error (pins nil-vs-err)
}
func TestTxnRule(t *testing.T) {
    // PutCursor-descend outside RunContext: records the actual behavior;
    // plan expects an error (mirroring Rust ExpectedTxStart) — if allowed, ledger a ruling and keep the planned shape anyway
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd servers/go-std && go test -run 'TestStore|TestMissing|TestTxn' ./... 2>&1 | tail -5`
Expected: FAIL — `store.go` missing.

- [ ] **Step 3: Implement `store.go`**: root via `xitdb.NewWriteHashMap(db.RootCursor())`; reads descend with `GetCursor` (nil = absent); mutations in `db.RunContext(func(w *xitdb.WriteCursor) error {...})` with `PutCursor` + `NewWriteHashSet`/`NewWriteSortedMap`; feed = `Count()` → `GetIndexKeyValuePair(start..count)` → 20 point gets → reverse; `post.json()` manual `fmt.Sprintf` framing with the 3 strings escaped by a `jstr` helper (a `json.Encoder` with `SetEscapeHTML(false)`, trailing newline trimmed — never default `json.Marshal`, which HTML-escapes).

- [ ] **Step 4: Run to verify pass**

Run: `cd servers/go-std && go test ./... 2>&1 | tail -3`
Expected: PASS, Tasks 1+2 green.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/go-std && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: go xitdb store + like/feed semantics"
```

### Task 3: HTTP server + wiring

**Files:**
- Create: `servers/go-std/main.go`; Modify: `servers/go-std/{install,build,start}.sh`, `servers/go-std/README.md`
- Test: live small-DB smoke with curl (no new Go tests — handlers are thin over Task 1/2-tested fns)

**Interfaces:**
- Consumes: `Store` + `trimBody/validPostID/verifyJWT` from Tasks 1–2.
- Produces: listening server honoring `XITDB_PATH/JWT_SECRET/HOST/PORT`; routes + exact bytes per SPEC-XITDB.

- [ ] **Step 1: Write the failing smoke** (server not yet serving — connection refused)

Run: `PORT=3011 bash servers/go-std/start.sh & sleep 1; curl -sf http://127.0.0.1:3011/health; echo "EXIT:$?"`
Expected: FAIL — `bin/server` missing (start.sh execs nothing).

- [ ] **Step 2: Implement `main.go`**: `ServeMux` patterns `GET /health`, `GET /feed`, `GET /posts/{id}`, `POST /posts`, `POST /posts/{id}/like`; body read fully + `json.Unmarshal` (error → `malformed JSON body`); `trimBody` on the string field (missing/non-string → `body is required`); like handler auths before id-check; `writeJSON` sets `application/json` + status; `uptime_s = int(time.Since(boot).Seconds())`; unknown paths → 404 `not found` (mux catch-all `/`).

- [ ] **Step 3: Wire scripts + README**: `install.sh` (go toolchain pinned), `build.sh` (`cd "$(dirname "$0")" && go build -o bin/server .`), `start.sh` (`exec "$(dirname "$0")/bin/server"`; binary reads env itself); README (run block, Nginx-or-direct, optimizations — mirror rust README).

- [ ] **Step 4: Run smoke to verify pass** (fresh small seed)

Run: `cp /tmp/xb-small/feed.xitdb /tmp/xb-go-smoke.db && XITDB_PATH=/tmp/xb-go-smoke.db PORT=3011 go run . & sleep 2; curl -s http://127.0.0.1:3011/posts/1 | head -c 120; curl -s http://127.0.0.1:3011/feed | python3 -c "import json,sys;print(len(json.load(sys.stdin)['posts']))"`
Expected: post-1 bytes + `20`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/go-std && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: go std http feed server"
```

### Task 4: Gate + CI + docs

**Files:**
- Modify: `.github/workflows/ci.yml` (add `go-std` job), `servers/go-std/README.md` (results line)
- Test: `harness/run.sh` (small + full) + k6 smoke

**Interfaces:**
- Consumes: Tasks 1–3 + committed goldens (targets, never regenerated).
- Produces: `LEADERBOARD-XITDB.md` go-std row (local numbers, labeled as such).

- [ ] **Step 1: Run small gate**

Run: `bash harness/run.sh servers/go-std 2>&1 | tail -2`
Expected: `passed=42 failed=0`.

- [ ] **Step 2: Run full gate**

Run: `SIZE=full bash harness/run.sh servers/go-std 2>&1 | tail -2`
Expected: `passed=42 failed=0` (proves byte-identical goldens incl. `golden-full`).

- [ ] **Step 3: k6 smoke** (fresh full copy, VUS=50/30s)

Run: `bun ./seed/generate-xitdb.ts --full /tmp/xb-go-k6 && cp /tmp/xb-go-k6/feed.xitdb /tmp/xb-go-k6run.db && (XITDB_PATH=/tmp/xb-go-k6run.db PORT=3000 ./servers/go-std/bin/server &) && sleep 2 && k6 run -e BASE_URL=http://127.0.0.1:3000 -e VUS=50 -e DURATION=30s -e RAMP_UP=10s -e TOKENS=/tmp/xb-go-k6/tokens.json harness/bench/load.js 2>&1 | grep -E "p\(95\)|p\(99\)|checks_failed"; pkill -f 'go-std/bin/server'`
Expected: thresholds `✓`, `0.00%`.

- [ ] **Step 4: Add CI job** (`setup-go` 1.23 + `bash harness/run.sh servers/go-std`, small) and record local numbers in `LEADERBOARD-XITDB.md` go-std row.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add -A && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: go-std green small+full + ci"
```
