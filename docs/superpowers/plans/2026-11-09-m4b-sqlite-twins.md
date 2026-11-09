# M4b SQLite-Twins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A SQLite twin for each of the 7 servers, sharing everything except the store layer, so droplet re-runs compare engines instead of implementations.

**Architecture:** Each twin is a copy of its xitdb server directory with only the store module replaced by same-interface SQLite code; one shared SQLite seed tool feeds all twins; the harness learns a `STORE=sqlite` switch. Twin responses must be byte-identical to xitdb goldens.

**Tech Stack:** Upstream `schema.sql` verbatim; per-language SQLite drivers (pinned per task); `bun:sqlite` for the seed tool.

**Spec:** `SPEC-XITDB.md` (byte-identical API — twins obey it too), upstream `schema.sql` below (vendored verbatim in B0), `docs/runs/*.md` (what not to repeat).

Upstream schema (fixed — twins use exactly this):
```sql
CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id),
  body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
CREATE TABLE likes (user_id INTEGER NOT NULL REFERENCES users(id),
  post_id INTEGER NOT NULL REFERENCES posts(id),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (user_id, post_id));
CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
CREATE INDEX posts_user_id_idx ON posts (user_id);
CREATE INDEX likes_post_id_idx ON likes (post_id);
```

Canonical twin SQL (same in every language, adapted to driver placeholders):
- feed: `SELECT p.id,p.body,p.created_at,u.username,(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id) FROM posts p JOIN users u ON u.id=p.user_id ORDER BY p.created_at DESC,p.id DESC LIMIT 50`
- post: same `WHERE p.id=?`
- like: `INSERT OR IGNORE INTO likes(user_id,post_id,created_at) VALUES(?,?,?)` then the count subquery
- create post: `INSERT INTO posts(user_id,body,created_at) VALUES(?,?,?)` (server formats `created_at`, same millisecond format as xitdb path)
- login: `SELECT id,username FROM users` (read into the same auth map shape)

## Global Constraints

- Twin directory names are `servers/<name>-sqlite` (e.g. `servers/rust-axum-sqlite`); each has `install.sh`/`build.sh`/`start.sh` with the same contract (env `HOST`/`PORT`/`JWT_SECRET`/`XITDB_PATH`, where `XITDB_PATH` points at `feed.db` — wart kept so handlers stay byte-identical).
- Handlers, auth, validation, and HTTP layers are copied VERBATIM from the xitdb server; only store files + dependency manifests + install.sh may differ.
- Each twin passes 42/42 on small AND full seeds (which also proves cross-engine byte parity, since goldens are shared).
- Record each driver's exact version in the twin's README.md.
- One commit per task.

## Review Focus

- `like_count` as COUNT(*) vs stored integer diverging after runtime likes — expect identical counts; pinned by every task's full-seed 42 run (suite likes posts) plus k6 write legs in B9.
- Feed tie order (`created_at` equal → `id DESC`) differing from the xitdb scan — expect golden order; pinned by the feed golden in every task's 42 run.
- Integer-vs-text rendering (`id` as JSON number, never quoted) — expect byte parity; pinned by goldens.
- Auth drift between twin and original — expect zero auth diffs (`diff` the auth files in each twin task's first step).
- `created_at` written by the twin in a different millisecond format — expect the server-side formatter reused verbatim; pinned by post-creation goldens.

---

### Task B0: shared SQLite seed tool

**Files:**
- Create: `seed/schema.sql` (verbatim upstream copy above), `seed/generate-sqlite.ts`
- Test: row counts + a feed query byte-check (step 2)

**Interfaces:**
- Consumes: the row stream from `seed/generate-xitdb.ts` (same mulberry32(42) users/posts/likes; refactor the row computation into an importable function if cheap, else duplicate the ~40 lines and note it).
- Produces: `seed/generate-sqlite.ts --small|--full <outDir>` writing `<outDir>/feed.db` (schema.sql applied, rows inserted, `tokens.json` copied identically).

- [ ] **Step 1: Vendor schema.sql verbatim and write generate-sqlite.ts**

`bun:sqlite` for writes. Users/posts/likes rows identical to the xitdb seed (same ids, usernames, bodies, timestamps, like pairs). `tokens.json` byte-identical to the xitdb seed's.

- [ ] **Step 2: Verify seed parity**

Run: `bun ./generate-sqlite.ts --small /tmp/sql-small` then compare counts against the xitdb small seed (users/posts/likes equal) and run the canonical feed SQL with `LIMIT 1`, rendering one post's JSON by hand against `harness/golden-small/post-1.json`.
Expected: counts equal; hand-rendered bytes match (proves rows + strings are golden-compatible before any twin exists).

- [ ] **Step 3: Commit**

```bash
git add seed/schema.sql seed/generate-sqlite.ts
git commit -m "feat: sqlite seed twin of the xitdb seed"
```

### Task B1: rust-axum-sqlite (twin template)

**Files:**
- Create: `servers/rust-axum-sqlite/` (full copy of `servers/rust-axum/`, then replace store usage)
- Test: `harness/run.sh` (with B8's STORE switch; until B8 lands, seed manually per step 3)

**Interfaces:**
- Consumes: `seed/generate-sqlite.ts` (B0), rusqlite with `bundled` feature (check MSRV ≤1.85 at build; fallback: rusqlite without bundled + `libsqlite3-dev` in install.sh).
- Produces: twin passing the same gates as the original.

- [ ] **Step 1: Copy and diff-guard**

Run: `cp -r servers/rust-axum servers/rust-axum-sqlite` then `diff -r` the auth/validate/HTTP/handler files against the original after the task — expected output: identical except `Cargo.toml`, `install.sh`, store code, README.
Pin rusqlite version in `Cargo.toml` (record it in `servers/rust-axum-sqlite/README.md`).

- [ ] **Step 2: Replace the store calls with the canonical SQL**

Same function signatures the handlers already call; bodies run the canonical queries from this plan's header via rusqlite (prepare once at startup, bind per request). `like_count` = COUNT(*) subquery. Timestamps formatted by the existing `format_millis_z`.

- [ ] **Step 3: Seed manually and run both conformance gates**

Run: `bun ./seed/generate-sqlite.ts --small /tmp/b1 && XITDB_PATH=/tmp/b1/feed.db bash harness/run.sh servers/rust-axum-sqlite` — note: until B8 lands, `run.sh` regenerates an xitdb seed; override by pointing `XITDB_PATH` after its seed step is wrong. Instead for now: `cd` into the flow manually (build, start with `XITDB_PATH=/tmp/b1/feed.db`, run `harness/contracts.sh` against `PORT=3000`). Expected: 42/42. Repeat with `--full`.
(When B8 lands, re-verify via `STORE=sqlite bash harness/run.sh servers/rust-axum-sqlite`.)

- [ ] **Step 4: Local k6 smoke**

Run: full-seed twin up, `k6 run -e BASE_URL=http://127.0.0.1:3000 -e VUS=50 -e DURATION=2m harness/bench/load.js`. Expected: exit 0 (records the M1-style smoke number in the commit message).

- [ ] **Step 5: Commit**

```bash
git add servers/rust-axum-sqlite
git commit -m "feat: rust-axum-sqlite twin"
```

### Tasks B2–B7: remaining twins (same template, pins below)

Each task = copy dir, diff-guard non-store files, swap store to the canonical SQL with the pinned driver, 42/42 small+full, k6 VUS=50 smoke, commit `feat: <name>-sqlite twin`. Driver pins (verify at build; record exact version in twin README):

- [ ] **B2 go-std-sqlite:** `modernc.org/sqlite` (pure Go, no cgo) via `database/sql`. Store file: `servers/go-std-sqlite/store.go`.
- [ ] **B3 ts-bun-sqlite:** `bun:sqlite` built-in (no new dep). Store file: `servers/ts-bun-sqlite/src/store.ts`.
- [ ] **B4 zig-std-sqlite:** system `libsqlite3` (`apt-get install -y libsqlite3-dev` in install.sh; Mac note: `brew install sqlite` + CPATH) via `@cImport` in a new `store_sqlite.zig`. Only needs open/prepare/bind/step/column_*/finalize/close.
- [ ] **B5 clj-httpkit-sqlite:** `org.xerial/sqlite-jdbc 3.46.1.0` + `org.clojure/java.jdbc 0.7.12` in `deps.edn` (JVM-bundled natives, no apt). Serves the hashmap-flavor equivalent: plain `feed.db` (NOT history). Store file: `src/store.clj`.
- [ ] **B6 odin-std-sqlite:** hand-written `sqlite3` FFI in `src/sqlite.odin` (`foreign import "system:sqlite3"`, procedures: `open_v2`, `prepare_v2`, `bind_int64/bind_text`, `step`, `column_int64/column_text`, `finalize`, `close`, `errmsg`); `libsqlite3-dev` in install.sh.
- [ ] **B7 java-spring-sqlite:** `org.xerial/sqlite-jdbc 3.46.1.0` via Maven Central (existing repo config) + plain `java.sql`. Store file: replace `Store.java` internals, same method signatures.

### Task B8: harness learns STORE=sqlite

**Files:**
- Modify: `harness/run.sh`, `harness/contracts.sh`, `docker-compose.yml`, `.github/workflows/ci.yml`
- Test: one xitdb gate + one sqlite gate through the new switch (steps 2-3)

**Interfaces:**
- Consumes: `seed/generate-sqlite.ts` (B0), twin dirs (B1-B7).
- Produces: `STORE=sqlite bash harness/run.sh servers/<name>-sqlite` working; CI covering all 14 servers.

- [ ] **Step 1: Add the STORE switch**

In `run.sh`: `STORE="${STORE:-xitdb}"`; when `sqlite`, seed with `bun ./generate-sqlite.ts "--$SIZE" "$SEED_DIR"` and set `SEED_FILE=feed.db` (XITDB_PATH export unchanged). In `contracts.sh`: extend the server-name list with the 7 `-sqlite` names (read the file's enumeration first — keep its shape). In `docker-compose.yml`: add 7 services on host ports 3008-3014 mirroring the existing seven. In `ci.yml`: add 7 `run.sh` lines next to their xitdb siblings (same runners/images).

- [ ] **Step 2: Gate one xitdb + one sqlite server through the switch**

Run: `bash harness/run.sh servers/rust-axum` and `STORE=sqlite bash harness/run.sh servers/rust-axum-sqlite`. Expected: `passed=42 failed=0` twice.

- [ ] **Step 3: Commit**

```bash
git add harness/run.sh harness/contracts.sh docker-compose.yml .github/workflows/ci.yml
git commit -m "feat: harness STORE=sqlite switch + twin wiring"
```

### Task B9: droplet re-score and versus table

**Files:**
- Create: `docs/runs/<name>-sqlite.md` (7 logs, same M3 procedure)
- Modify: `LEADERBOARD-XITDB.md` (add SQLite columns), `docs/droplet.md` (second batch notes)

**Interfaces:**
- Consumes: M4a-fixed xitdb servers, B1-B7 twins, M3 Task 2 procedure (warm-up → double → narrow → cool-down → 5m hold, k6 box-to-box).
- Produces: per-engine verdicts on the same box.

- [ ] **Step 1: Provision a fresh batch box (M3 Task 1 procedure) and green-gate all 14**

Fresh droplet (same size/region class), all install.sh scripts, 42/42 small gates for 7 xitdb + 7 sqlite servers. Requires explicit user approval for the spend (~1 day of two droplets) before creating anything.

- [ ] **Step 2: Score all 14 per M3 Task 2, xitdb-first then twins**

Same ladder rules (double from 2500, narrow ±250, marginal-hold retry, step-down 250). One run log per server. Expect ~1h per server; run sequentially.

- [ ] **Step 3: Fill the versus table and commit**

Extend `LEADERBOARD-XITDB.md` with `SQLite VUs` + `xVAS` (xitdb-vs-sqlite ratio) columns and a paragraph on which gap layers (M4a fixes vs engine) moved which servers, with before/after xitdb numbers.

```bash
git add LEADERBOARD-XITDB.md docs/runs/*-sqlite.md docs/droplet.md
git commit -m "docs: m4 re-score with sqlite twins"
```

## Self-Review

1. **Spec coverage:** byte parity → shared goldens in every twin task; upstream schema → vendored verbatim in B0 + canonical SQL in header; M3 comparability → B9 reuses the exact procedure; fix-before-compare → M4a is a separate plan that must land first (B9 consumes it).
2. **Step scan:** B2-B7 compress deliberately (template in B1); each still names its driver pin, store file, and three gates. B1 Step 3 documents the pre-B8 manual flow so ordering stays flexible.
3. **Type consistency:** `XITDB_PATH` keeps its name everywhere (documented wart); twin dirs are `<name>-sqlite`; seed outputs `feed.db` + identical `tokens.json`.
4. **Review Focus:** all five lines map to gates above (like_count → 42 + B9 writes; tie order → feed golden; int rendering → goldens; auth drift → diff-guard; timestamp format → post goldens).
5. **Proportion:** decisions (pins, SQL, layout, gates) are in; handler bodies and SQL boilerplate stay out.
