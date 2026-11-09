# M4a Server-Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four measured server-side bottlenecks from the M3 droplet shootout so the xitdb servers race on the store, not on their own scaffolding.

**Architecture:** Four independent per-server fixes, each validated by the existing 42-check suite plus a local before/after k6 or RSS gate on the same Mac. No API, seed, or harness changes.

**Tech Stack:** Rust 1.85 (Axum), Go 1.23 (net/http), Zig 0.17 (std), Odin dev-2026-10 (std).

**Spec:** `SPEC-XITDB.md` (byte-identical API), `schema-xitdb.md` (frozen layout), `docs/runs/*.md` (measured walls: rust mutex knee 5000→5156, go slot reads, zig 630MB/2000conns, odin 4MB/conn arena).

## Global Constraints

- Every task keeps all 42 conformance checks green on small AND full seeds (`bash harness/run.sh servers/<name>`, `SIZE=full` second run).
- No response-body byte may change: goldens in `harness/golden-small|full/` are the oracle.
- No new runtime dependencies; no toolchain changes.
- One commit per task, message `fix: <server> <what>`; push only when all four tasks land.

## Review Focus

- A lock change that deadlocks a write behind a held read guard (like-before-post ordering) — expect no new hangs under the 42 suite + k6 writes; pinned by each task's k6 leg which includes likes/posts.
- A buffer shrink that truncates the largest feed body (~30KB with 50 long posts) — expect byte-identical feed.json; pinned by the full-seed 42 run in every task.
- A cursor change that reorders tied `created_at` rows — expect golden order; pinned by the 42 suite's feed test.
- RSS gates measured with different connection counts than stated — expect the exact VUS/duration in the step; pinned by the step's command line.
- A "fix" that only moves the knee a few percent (noise on shared hardware) — expect ≥20% headroom gain or an RSS-ratio gate, not vibes; pinned by each task's numeric gate.

---

### Task A1: rust-axum read/write lock split

**Files:**
- Modify: `servers/rust-axum/src/main.rs` (`Shared.db` field ~line 29, all `moved.db.lock()` sites ~lines 324-500)
- Test: existing `cargo test` (5 tests) + `harness/run.sh`

**Interfaces:**
- Consumes: `Db` type with `&self` read methods and `&mut self` write methods (already split: handlers drop the guard before building JSON).
- Produces: `Shared { db: RwLock<Db>, .. }`; GET handlers take `.read()`, like/post handlers take `.write()`.

- [ ] **Step 1: Change `Shared.db` from `Mutex<Db>` to `RwLock<Db>` and update all lock sites**

Run: `rg -n "\.lock\(\)" servers/rust-axum/src/main.rs` must show zero hits after; `read()` on GET paths (`feed`, `get_post`, `health`, login reads), `write()` on like/create paths.

- [ ] **Step 2: Run unit tests + both conformance gates**

Run: `(cd servers/rust-axum && cargo test)` Expected: 5 passed.
Run: `bash harness/run.sh servers/rust-axum` then `SIZE=full bash harness/run.sh servers/rust-axum` Expected: `passed=42 failed=0` twice.

- [ ] **Step 3: Before/after k6 at VUS=1000 on local full seed**

Run (stash the fix to get `before`, or build both binaries first): start server on a full-seed copy, `k6 run -e BASE_URL=http://127.0.0.1:3000 -e VUS=1000 -e DURATION=2m harness/bench/load.js`.
Expected: `after` p95 ≤ `before` p95 (no regression required; improvement is the hope, parity is the gate).

- [ ] **Step 4: Commit**

```bash
git add servers/rust-axum/src/main.rs
git commit -m "fix: rust-axum RwLock so GETs run in parallel"
```

### Task A2: go-std single-pass reads

**Files:**
- Modify: `servers/go-std/store.go` (`readPost` ~line 96, `getPost` ~line 145, `getFeed` ~line 173)
- Test: existing `go test ./...` + `harness/run.sh`

**Interfaces:**
- Consumes: `xitdb-go` cursor API (whatever version `go.mod` pins).
- Produces: same `(*post, error)` / `([]post, error)` signatures with identical bytes.

- [ ] **Step 1: Collapse per-field cursor chains to one traversal per map**

Current waste (verified): `readPost` opens separate cursors for `id`, `body`, `created_at`, `author`, `like_count`; `getFeed` re-opens the posts map per row. Read the pinned `xitdb-go` cursor API and pick the minimal-traversal equivalent (range scan / single cursor walked once per map, fields decoded from the row bytes in one pass). Constraint, not prescription: the feed path must traverse each map once, not once per field per row.

- [ ] **Step 2: Run unit tests + both conformance gates**

Run: `(cd servers/go-std && go test ./...)` Expected: all pass.
Run: `bash harness/run.sh servers/go-std` then `SIZE=full ...` Expected: `passed=42 failed=0` twice.

- [ ] **Step 3: Before/after k6 at VUS=1000 on local full seed**

Same procedure as A1 Step 3. Expected: `after` p95 ≤ `before` p95.

- [ ] **Step 4: Commit**

```bash
git add servers/go-std/store.go
git commit -m "fix: go-std single-pass map reads"
```

### Task A3: zig-std small connection buffers

**Files:**
- Modify: `servers/zig-std/src/main.zig` (lines 254-255 conn buffers, line 67 request buffer)
- Test: existing `zig build test` + `harness/run.sh`

**Interfaces:**
- Consumes: `std.http.Server` reader/writer over caller buffers.
- Produces: same server with 8KB buffers; larger responses flush in chunks (no truncation).

- [ ] **Step 1: Shrink the three 64KB allocs to 8KB**

`conn_alloc.alloc(u8, 65536)` ×2 (in/out) and `arena.alloc(u8, 65536)` (request body) become `8192`. The ~30KB max feed body exercises multi-flush writes; correctness is proven by the full-seed 42 run, not by reasoning.

- [ ] **Step 2: Run unit tests + both conformance gates**

Run: `(cd servers/zig-std && zig build test)` Expected: pass.
Run: `bash harness/run.sh servers/zig-std` then `SIZE=full ...` Expected: `passed=42 failed=0` twice.

- [ ] **Step 3: RSS gate at 2000 conns**

Run: start server on a local full-seed copy; `k6 run -e BASE_URL=http://127.0.0.1:3000 -e VUS=2000 -e DURATION=2m harness/bench/load.js &`; at t=90s run `ps -o rss= -p <server pid>`.
Expected: RSS < 250MB (M3 measured 630MB with 64KB buffers).

- [ ] **Step 4: Commit**

```bash
git add servers/zig-std/src/main.zig
git commit -m "fix: zig-std 8KB conn buffers"
```

### Task A4: odin-std bounded per-connection arena

**Files:**
- Modify: `servers/odin-std/src/main.odin` (`serve_conn` ~line 381)
- Test: existing odin tests + `harness/run.sh`

**Interfaces:**
- Consumes: `serve_conn(sock)` loop reading requests off one socket.
- Produces: same loop with per-request scratch bounded and freed per iteration.

- [ ] **Step 1: Shrink the 4MB conn arena to 256KB and free per-request scratch each iteration**

Current shape (verified): `backing := make([]u8, 4MB)` per connection, `buf` (dynamic, arena-allocated) reused across iterations, request scratch allocated from the same arena with no reset — so memory grows per request until close. Change to: `backing := make([]u8, 256*1024)`; allocate the reusable `buf` from `context.allocator` (freed once at close); call `mem.arena_free_all(&arena)` at the top of each loop iteration so per-request scratch (JSON bodies, parsed values) is bounded by one request's worth (~30KB max).

- [ ] **Step 2: Run unit tests + both conformance gates**

Run: the odin test command in `servers/odin-std/README.md`. Expected: pass.
Run: `bash harness/run.sh servers/odin-std` then `SIZE=full ...` Expected: `passed=42 failed=0` twice.

- [ ] **Step 3: RSS gate at 1500 conns**

Same procedure as A3 Step 3 with `-e VUS=1500`.
Expected: RSS < 250MB (M3 measured 346MB mid-leg, worse at higher conns).

- [ ] **Step 4: Commit**

```bash
git add servers/odin-std/src/main.odin
git commit -m "fix: odin-std bounded per-conn arena"
```

## Self-Review

1. **Spec coverage:** byte parity → every task's double 42-gate; measured walls → A1 (mutex knee), A2 (slot reads), A3 (630MB), A4 (4MB arena + no reset). clj/ts/java have no server-code bug on record (CPU-shape knees) — explicitly out of scope.
2. **Step scan:** each step names one command and its expected output. A2 Step 1 leaves the cursor API choice open deliberately (pinned API unknown at plan time) with a checkable constraint.
3. **Type consistency:** A1 keeps `Shared`/`Db` names; A2 keeps `readPost`/`getPost`/`getFeed` signatures; A3/A4 change only sizes, no signatures.
4. **Review Focus:** all five lines have owning tasks and gates above.
5. **Proportion:** plan states decisions (which lock, which sizes, which gates); bodies stay in the code.
