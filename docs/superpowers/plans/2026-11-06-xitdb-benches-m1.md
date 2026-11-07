# xitdb-benches M1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up local repo `xitdb-benches` with shared harness + TS/Bun `feed.xitdb` generator + conformant Rust/Axum server green on the full dataset.

**Architecture:** New sibling repo `../xitdb-benches` (local, publish later); single TS/Bun generator emits canonical `feed.xitdb` per frozen layout; Rust/Axum reference server implements the 5 endpoints byte-identically; ported `test-xitdb.sh` + vendored `load.js` prove 42/42 + k6 smoke.

**Tech Stack:** Bun 1.x + `xitdb-ts` (pinned) for `seed/`; Rust 1.85 + Axum 0.8 + Tokio multi-thread for `servers/rust-axum`; bash + curl/jq/openssl + k6 for `harness/`; Docker Compose for local 7x run.

**Spec:** `docs/superpowers/specs/2026-11-06-xitdb-benches-design.md` (in `xitdb-rs`; copy to `xitdb-benches/SPEC-XITDB.md` in Task 1 — executors read both)

## Global Constraints

- New repo root: `/Users/collindie/Code/xitdb-benches` (sibling of `xitdb-rs`); local git, no remote yet; every task ends committed in that repo.
- Env contract: `XITDB_PATH` (fresh `feed.xitdb` copy), `JWT_SECRET=twelve-dollar-challenge`, `HOST`/`PORT` (`127.0.0.1:3000` behind Nginx, `0.0.0.0:80` direct); HTTP/1.1 keep-alive idle >=65s.
- Layout frozen: root HashMap keys `users,posts,feed,likes,meta`; `feed_key = created_at + '\0' + id_padded_10`; post key order `id,body,created_at,author,like_count`; compact JSON + `Content-Type: application/json`.
- Seed constants: mulberry32(42), USERS=50000, POSTS=500000, LIKES~=2000000, TOKEN_COUNT=20000, END=2026-01-01T00:00:00Z, `next_post_id=500001` after seed; flags `--full` (default) / `--small` (1k/10k/20k).
- Auth: HS256 verify signature + `exp` + `alg==HS256` every request, no memoization; `sub`=positive-int-string, `username`=string; auth-before-id.
- Writes: one xitdb txn per mutating request, `FileCore` fsync:true, 201 means committed+fsynced; `created_at` new rows = UTC `YYYY-MM-DDTHH:MM:SS.mmmZ` within 60s drift.
- Upstream vendors unchanged except noted: `bench/load.js`, `bench/nginx.conf` byte-identical; `test-xitdb.sh` = 42 checks verbatim (only `XITDB_PATH` + health regex differ).
- Rust: edition 2024, `Database<FileCore,Sha1Hasher>`, `Arc<Mutex<Db>>`, whole txn in `spawn_blocking`, never hold guard across `.await`; clippy `unwrap_used/expect_used` deny (use `eprintln!` paths like `benches/ops.rs`).

## Review Focus

- `GET /posts/0,-1,abc,1.5` returns 400 `invalid post id`, not 404 — pinned in Task 4.
- `POST /posts/abc/like` with no token returns 401 `missing bearer token` (auth before id), with valid token returns 400 — pinned in Task 4.
- `POST /posts` with `{"body":"   "}` / `123` / `{}` returns 400 `body is required`; 501-char-after-trim returns 400 `body must be at most 500 characters`; `{bad json` returns 400 `malformed JSON body` — pinned in Task 4.
- `Authorization: Bearer <alg=none|expired|bad-sig>` returns 401 `invalid or expired token`; `sub:"abc"` or missing `username` returns 401 `invalid token payload` — pinned in Task 4.
- Second `POST /posts/:id/like` returns 200 `already_liked:true` and `like_count` increments exactly once (repeat likes don't double-count) — pinned in Tasks 3+4.

---

## File Structure

New repo (`/Users/collindie/Code/xitdb-benches`):

- `README.md`, `.gitignore` (`*.db`, `feed.xitdb`, `target/`, `node_modules/`, `bin/`), `docker-compose.yml` (rust 3001 + 6 stub ports 3002-3007 + nginx option)
- `SPEC-XITDB.md` (copy of spec sections 5+3 deltas), `schema-xitdb.md` (frozen layout), `LEADERBOARD-XITDB.md` (stub table)
- `seed/package.json` (bun, pinned `xitdb-ts`), `seed/generate-xitdb.ts` (mulberry32 port + bulk txn), `seed/verify.ts` (counts + spot goldens), `seed/README.md`
- `servers/rust-axum/Cargo.toml`, `servers/rust-axum/src/main.rs` (5 endpoints + JWT + JSON), `servers/rust-axum/{install,build,start}.sh`, `servers/rust-axum/README.md`
- `servers/{go-std,ts-bun,zig-std,java-spring,clj-httpkit,odin-std}/{README.md,install.sh,build.sh,start.sh}` (scaffold stubs returning 501 + healthy `/health`)
- `harness/test-xitdb.sh` (42 checks), `harness/run.sh` (fresh-copy + ≤60s healthy + test), `harness/bench/load.js` + `harness/bench/nginx.conf` (vendored), `harness/README.md`
- `.github/workflows/ci.yml` (`--small` + test per server per PR)

Reference sources: upstream `SPEC.md`/`test/test.sh`/`bench/load.js` via `curl` (URLs in spec); `xitdb-rs` `examples/rest_server.rs:1-127` (Mutex pattern), `benches/ops.rs` (SortedMap `iter_from_index`, `black_box` reads), `src/sorted_map.rs:136-165` (`count`/`iter_from_index`), `src/lib.rs:1-103` (fsync + `spawn_blocking` docs).

---

### Task 1: Skeleton + contracts

**Files:**
- Create: `/Users/collindie/Code/xitdb-benches/{README.md,.gitignore,docker-compose.yml,SPEC-XITDB.md,schema-xitdb.md,LEADERBOARD-XITDB.md,harness/bench/load.js,harness/bench/nginx.conf}` + 7x `servers/<name>/{README.md,install.sh,build.sh,start.sh}`
- Test: `harness/contracts.sh` (asserts every server dir has executable install/build/start + README names stack)

**Interfaces:**
- Consumes: spec sections 2+8 (layout names, contract values).
- Produces:
  - `install.sh: () -> exit 0` (root toolchain install, `set -euo pipefail`), `build.sh: () -> exit 0` (pinned build, no prebuilts), `start.sh: () -> foreground server on $HOST:$PORT` honoring `$XITDB_PATH,$JWT_SECRET,$HOST=127.0.0.1,$PORT=3000`.
  - `SPEC-XITDB.md` contains `XITDB_PATH`, `feed_key`, key order, `twelve-dollar-challenge`; `schema-xitdb.md` contains the 5 root keys + txn rules.

- [ ] **Step 1: Write failing contracts test**

```bash
# harness/contracts.sh asserts: for each servers/*/ -> install.sh, build.sh, start.sh exist + executable + README mentions stack; SPEC-XITDB.md greps XITDB_PATH + feed_key; docker-compose.yml greps 3001-3007
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash /Users/collindie/Code/xitdb-benches/harness/contracts.sh`
Expected: FAIL — repo does not exist.

- [ ] **Step 3: `git init` new repo + write all skeleton files** (copy upstream `bench/load.js`, `bench/nginx.conf` byte-identical via curl; 6 stub servers return `501 {"error":"not implemented"}` except `GET /health` returns `{"status":"ok","db":"ok","uptime_s":0}`; rust dir gets placeholder `start.sh` replaced in Task 3; `docker-compose.yml` maps rust:3001, go:3002, ts:3003, zig:3004, clj:3005, odin:3006, java:3007).

- [ ] **Step 4: Run contracts to verify pass**

Run: `bash /Users/collindie/Code/xitdb-benches/harness/contracts.sh && cat /Users/collindie/Code/xitdb-benches/SPEC-XITDB.md | head -5`
Expected: PASS (7/7 servers contract-ok).

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add -A && git -C /Users/collindie/Code/xitdb-benches commit -m "chore: xitdb-benches skeleton + droplet contract"
```

### Task 2: TS/Bun generator (single source of truth)

**Files:**
- Create: `/Users/collindie/Code/xitdb-benches/seed/{package.json,generate-xitdb.ts,verify.ts,README.md}`
- Test: `bun test` in `seed/` (mulberry32 vector + feed_key ordering) + `verify.ts` counts

**Interfaces:**
- Consumes: skeleton `schema-xitdb.md` root keys from Task 1.
- Produces:
  - `generate-xitdb.ts: (outDir: string, opts: {size: "small"|"full"}) -> Promise<{db: "feed.xitdb", tokens: "tokens.json"}>` writing §3 bulk txn + `meta{next_post_id}`.
  - `verify.ts: (dbPath: string) -> {users: number, posts: number, likes: number}` asserting small=1k/10k/20k, full=50k/500k/~2M (±2% likes expo variance).

- [ ] **Step 1: Write failing seed tests**

```typescript
// seed/generator.test.ts: mulberry32(42) first three outputs equal generate.mjs values; feedKey("2025-01-01T00:00:00.000Z", 7) === "2025-01-01T00:00:00.000Z\x000000000007" and sorts before id 8 same-ts
```

- [ ] **Step 2: Run to verify fail**

Run: `bun test /Users/collindie/Code/xitdb-benches/seed 2>&1 | tail -10`
Expected: FAIL — no such directory.

- [ ] **Step 3: Implement `package.json` (pinned `xitdb-ts`), `generate-xitdb.ts`** porting `generate.mjs` lines 1-137 exactly (constants, `mulberry32`, `pick/expo/sentence/postBody/ts`, user/post/like loops) but sinking rows into §3 collections in 2k batches + `tokens.json` via `Bun.HMAC-SHA256` HS256; `--small` scales USERS/POSTS/LIKES to 1k/10k/20k with same code path.

- [ ] **Step 4: Run seed tests + `--small` generate + verify**

Run: `bun test ./seed 2>&1 | tail -3 && bun ./seed/generate-xitdb.ts --small /tmp/xb-small && bun ./seed/verify.ts /tmp/xb-small/feed.xitdb`
Expected: PASS + `users=1000 posts=10000 likes~=20000 next_post_id=10001`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add seed && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: bun generator small+full feed.xitdb"
```

### Task 3: Rust/Axum conformant server

**Files:**
- Create: `/Users/collindie/Code/xitdb-benches/servers/rust-axum/{Cargo.toml,src/main.rs}`; Modify: `servers/rust-axum/start.sh` (copy `$XITDB_PATH` fresh, exec binary)
- Test: `cargo test` in `servers/rust-axum` (unit: feed_key, id-validate, body-trim, JWT-reject vectors) — full 42/42 runs in Task 4

**Interfaces:**
- Consumes: `generate-xitdb.ts` `--small` output (`/tmp/xb-small/feed.xitdb`) + `tokens.json`; `schema-xitdb.md` collection names.
- Produces:
  - `fn feed_key(created_at: &str, id: u64) -> String` (`{created_at}\x00{id:010}`).
  - `fn is_valid_post_id(s: &str) -> Option<u64>` (digits only, no leading `+/-/space`, `>=1`, rejects `0,abc,1.5`, beyond-`u64` → None).
  - `fn trim_validate_body(v: &serde_json::Value) -> Result<String, &'static str>` (`body is required` / `body must be at most 500 characters`).
  - `fn verify_jwt(token: &str, secret: &str) -> Result<(u64,String), &'static str>` (`missing bearer token` handled in extractor; returns `invalid or expired token` vs `invalid token payload` per §4).
  - Endpoints: `GET /health`, `GET /feed`, `GET /posts/:id`, `POST /posts`, `POST /posts/:id/like` with exact compact JSON + key order + status codes (§4).

- [ ] **Step 1: Write failing unit tests** (`src/main.rs` `#[cfg(test)]`): `feed_key` ordering, `is_valid_post_id` table (`1→1, 0→None, -1→None, abc→None, 1.5→None`), `trim_validate_body` table (`"  hi "`→`hi`, `"   "`→`required`, `501×a`→`too long`), `verify_jwt` vectors (good, bad-sig, expired, alg=none, sub=abc, no-username) signed with `twelve-dollar-challenge`.

- [ ] **Step 2: Run to verify fail**

Run: `cargo test -p xitdb-bench-rust 2>&1 | tail -8`
Expected: FAIL — crate missing.

- [ ] **Step 3: Implement `Cargo.toml` (axum 0.8, tokio rt-multi-thread, `xitdb = { path = "/Users/collindie/Code/xitdb-rs" }` for v1 local pin, jsonwebtoken pinned, serde_json pinned) + `src/main.rs`** extending `xitdb-rs/examples/rest_server.rs` Mutex pattern: new `FileCore` open per boot (fsync:true), `GET`s do root-read txn without writer hold, mutating routes do one `run_context` (fsync before 201) inside `spawn_blocking`; JSON built by struct with ordered fields via manual `format!` (not derived order-dependent) to freeze `id,body,created_at,author,like_count`; `uptime_s = Instant::now().elapsed().as_secs()`.

- [ ] **Step 4: Run units to verify pass**

Run: `cargo test -p xitdb-bench-rust 2>&1 | tail -3`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/rust-axum && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: rust axum conformant feed server"
```

### Task 4: Harness port + v1 green gate

**Files:**
- Create: `/Users/collindie/Code/xitdb-benches/harness/{test-xitdb.sh,run.sh,README.md}`, `.github/workflows/ci.yml`; Modify: `servers/rust-axum/README.md` (Nginx-or-direct + optimizations)
- Test: `harness/test-xitdb.sh` itself (42 checks) + `harness/run.sh rust-axum` + k6 smoke

**Interfaces:**
- Consumes: Task 2 `--small/--full` DBs + Task 3 server + Task 1 stubs.
- Produces:
  - `test-xitdb.sh: (baseUrl: string) -> exit 0` iff 42/42 (golden `feed.json`/`post-*.json` regen from `--small` on first run, then byte-compare; JWT/openssl vectors; like 201→200; feed-top-20).
  - `run.sh: (serverDir: string) -> exit 0` (fresh `feed.xitdb` copy → `build.sh` → `start.sh` → wait ≤60s `GET /health` 200 → `test-xitdb.sh` → teardown).

- [ ] **Step 1: Write the failing gate** — generate `--small` goldens placeholder (empty `harness/golden/`), so `test-xitdb.sh` fails on byte compare.

Run: `bash harness/run.sh servers/rust-axum 2>&1 | tail -15`
Expected: FAIL — `test-xitdb.sh` missing.

- [ ] **Step 2: Port `test/test.sh` → `test-xitdb.sh`** (verbatim; only `SQLITE_PATH`→`XITDB_PATH` setup, `/health` regex unchanged shape, `JWT_SECRET` default kept) + `test/run.sh` → `run.sh` (fresh-copy + ≤60s wait) + regen `harness/golden/{feed.json,post-*.json}` from a clean `--small` boot.

- [ ] **Step 3: Run small gate to verify pass**

Run: `bun ./seed/generate-xitdb.ts --small /tmp/xb-gate && bash harness/run.sh servers/rust-axum 2>&1 | tail -5`
Expected: `passed=42 failed=0`.

- [ ] **Step 4: Run full gate + k6 smoke**

Run: `bun ./seed/generate-xitdb.ts --full /tmp/xb-full && XITDB_SEED=/tmp/xb-full/feed.xitdb bash harness/run.sh servers/rust-axum 2>&1 | tail -3 && k6 run -e BASE_URL=http://127.0.0.1:3000 -e VUS=100 -e DURATION=1m harness/bench/load.js 2>&1 | tail -8`
Expected: 42/42 on full + k6 `p(95)<500 p(99)<1000 failed<1%` (smoke; full 5-min hold is M3, not gate).

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add harness servers/rust-axum/README.md .github && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: harness port + v1 rust green on full dataset"
```
