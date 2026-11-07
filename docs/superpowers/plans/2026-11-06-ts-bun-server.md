# TS/Bun.serve Feed Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conformant `$12`-challenge feed server in `servers/ts-bun` (`Bun.serve` + `xitdb-ts`), green on the committed goldens.

**Architecture:** Mirror of the Rust/Go references: root `HashMap` with the 5 frozen collections; reads via `getCursor` (no txn), mutations via single `runContext` each **followed by `core.sync()`** (the commit path syncs data but not the header write — without it 201 is not durable); single-threaded event loop, no lock; compact JSON with construction-ordered keys.

**Tech Stack:** Bun 1.4.4, `xitdb@0.28.0` (npm), `jose@6.2.15` (HS256 verify).

**Spec:** `/Users/collindie/Code/xitdb-benches/SPEC-XITDB.md` + `/Users/collindie/Code/xitdb-benches/schema-xitdb.md`; behavior reference `servers/rust-axum/src/main.rs` + `servers/go-std/{validate,store,main}.go`; goldens `harness/golden-{small,full}/` (fixed targets — NEVER regenerate).

## Global Constraints

- Repo root: `/Users/collindie/Code/xitdb-benches`; `servers/ts-bun` Bun project (`package.json` + `bun.lock` committed); every task ends committed there.
- Layout frozen: root keys `users,posts,feed,likes,meta`; `feedKey = createdAt + "\0" + id.padStart(10,"0")`; post key order `id,body,created_at,author,like_count`; `Content-Type: application/json`.
- Hasher: `new Hasher("SHA-1", Hasher.stringToId("sha1"))` (matches Rust/Go headers); file core `new CoreBufferedFile(XITDB_PATH)`; **`db.core.sync()` after every mutating `runContext`** (flush+fsync; 201 means durable).
- Env: `XITDB_PATH`, `JWT_SECRET=twelve-dollar-challenge`, `HOST=127.0.0.1`, `PORT=3000`; `Bun.serve({hostname, port, idleTimeout: 70})` (≥65s Nginx rule; Bun default is 10s).
- Auth: `jwtVerify` with `algorithms: ["HS256"]` + `clockTolerance: 60` (parity with Rust/Go) **awaited every request, no memoization**; `sub` = all-digits `≥1` (as `BigInt`), `username` = string; auth-before-id.
- Body rule: `body.trim()`, empty → required; `body.length > 500` → too-long (**JS UTF-16 length is the reference semantics here** — matches upstream exactly).
- Id rule: `/^\d+$/`, `BigInt ≥ 1`, and `≤ Number.MAX_SAFE_INTEGER` (beyond 2^53 is spec out-of-scope → 400).
- `created_at`: `new Date().toISOString()` (always `YYYY-MM-DDTHH:MM:SS.mmmZ`, UTC).
- JSON: `JSON.stringify` on construction-ordered literals (no HTML escaping in `JSON.stringify` — exact bytes by construction).
- `POST /:id/like`: `201 already_liked:false` first, `200 already_liked:true` repeat, count bumps once, atomic in one `runContext`.

## Review Focus

- Missing-key reads: `getCursor` returning `null` must yield post-not-found / not-liked, never 500 — pinned in Task 2 (`store › missing keys`).
- Durability: header write after commit is un-synced by the library, so a missing `core.sync()` loses commits on crash — pinned in Task 2 (`store › second handle sees committed write` proves flush path; the `sync()` syscall itself is code-path reasoning, noted in code comment).
- Overflow id `"9".repeat(30)` (>2^53) must be 400, not 404/500 — pinned in Task 1 (`validate › overflow rejected`).
- Numeric `sub`/`username` must be `invalid token payload` (jose yields `unknown` payload — check `typeof`, don't struct-cast) — pinned in Task 1 (`auth › numeric claims`).
- 60s exp leeway parity: expired-30s accepted, expired-1h rejected — pinned in Task 1 (`auth › leeway parity`).

---

## File Structure

`servers/ts-bun/` (existing stubs replaced):

- `package.json` — `xitdb@0.28.0` + `jose@6.2.15` pinned; `bun.lock` committed.
- `src/validate.ts` — pure, no xitdb import: `feedKey(createdAt: string, id: number): string`, `validPostId(s: string): number | null`, `trimBody(body: unknown): { ok: true; value: string } | { ok: false; error: string }`.
- `src/auth.ts` — `verifyJWT(token: string, secret: string): Promise<{ userId: number; username: string } | { error: string }>` (exactly one of the two shapes; `error` is the spec message).
- `src/store.ts` — `openStore(path: string): Store`; `Store { health(): boolean; getFeed(): Post[]; getPost(id): Post | null; createPost(username, body): Post; likePost(id, userId): { already: boolean } | null }`; `Post { id, body, createdAt, author, likeCount }` + `postToJson(p): string` (manual framing, `JSON.stringify` per string).
- `src/index.ts` — `Bun.serve` only: method+pathname switch, `req.json()` in try/catch (→ `malformed JSON body`), auth-then-id in like route, `json(status, body): Response`, uptime from boot `Date.now()`.
- `src/validate.test.ts`, `src/auth.test.ts`, `src/store.test.ts` — `bun test` (store tests on `CoreMemory`, never seed files).
- `install.sh` (pinned Bun 1.4.4) / `build.sh` (`bun install --frozen-lockfile`) / `start.sh` (`exec bun run src/index.ts`) — replace stubs; `README.md` (mirror go README).

Reference reads: `xitdb-ts` `read-sorted-map.ts` (`count`, `getIndexKeyValuePair` → `{valueCursor,...}`), `read-hash-map.ts`/`read-hash-set.ts` (`getCursor` → `ReadCursor | null`), `read-cursor.ts` (`readUint`, `readBytes(max)`), `writeable-data.ts` (`Uint`, `Bytes`), generator `seed/generate-xitdb.ts` (write side, proven).

---

### Task 1: Pure validation + auth vectors

**Files:**
- Create: `servers/ts-bun/package.json`, `servers/ts-bun/src/validate.ts`, `servers/ts-bun/src/auth.ts`, `servers/ts-bun/src/validate.test.ts`, `servers/ts-bun/src/auth.test.ts`
- Test: `bun test` in `servers/ts-bun`

**Interfaces:**
- Consumes: none.
- Produces:
  - `feedKey(createdAt: string, id: number): string`
  - `validPostId(s: string): number | null`
  - `trimBody(body: unknown): { ok: true; value: string } | { ok: false; error: string }`
  - `verifyJWT(token: string, secret: string): Promise<{ userId: number; username: string } | { error: string }>`

- [ ] **Step 1: Write failing tests**

```typescript
// validate.test.ts: feedKey("2025-01-01T00:00:00.000Z", 7) === "...\x000000000007" + ordering;
// validPostId: "1"→1, "0"/"-1"/"abc"/"1.5"/""→null, "9".repeat(30)→null (overflow rejected)
// trimBody: "  hi "→"hi", "   "→required, 123→required, "a".repeat(501)→too-long, "b".repeat(500) ok
// auth.test.ts: good→{1,"alice"}; bad-sig/expired-1h/garbage/alg-none→"invalid or expired token";
//   sub "abc"/missing username/numeric sub/numeric username→"invalid token payload"; expired-30s→ok (leeway parity)
```

(Sign test tokens with `jose` `SignJWT`; craft `alg:none` as unsigned `header.payload.` — must be rejected.)

- [ ] **Step 2: Run to verify fail**

Run: `bun test ./servers/ts-bun 2>&1 | tail -5`
Expected: FAIL — modules missing.

- [ ] **Step 3: Implement `package.json` + `src/validate.ts` + `src/auth.ts`** with the exact signatures. Auth via `jwtVerify(token, new TextEncoder().encode(secret), { algorithms: ["HS256"], clockTolerance: 60 })` in try/catch (any throw → token error); then `typeof` checks on `payload.sub`/`payload.username` + `BigInt` range for sub (safe-integer gate for the numeric id).

- [ ] **Step 4: Run to verify pass**

Run: `bun test ./servers/ts-bun 2>&1 | tail -3`
Expected: PASS, zero failures.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/ts-bun && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: ts pure validation + jwt vectors"
```

### Task 2: Store over xitdb-ts (memory-backed tests)

**Files:**
- Create: `servers/ts-bun/src/store.ts`, `servers/ts-bun/src/store.test.ts`
- Test: `bun test src/store.test.ts`

**Interfaces:**
- Consumes: `feedKey` from Task 1.
- Produces: `openStore` + `Store` + `Post` + `postToJson` per File Structure.

- [ ] **Step 1: Write failing store tests** (`CoreMemory` DBs, hand-seeded through the store — never seed files)

```typescript
// store › round trip: createPost("alice","hi") → id 1, trimmed, count 0, createdAt matches /^\d{4}-…\.\d{3}Z$/;
//   getPost(1) deep-equals; getPost(999) → null; 2nd create → getFeed newest-first [2,1]
// store › like idempotent: likePost(1,7) → {already:false}; again → {already:true}; count==1; likePost(999,7) → null
// store › missing keys: getPost(99999) → null (not throw); empty-db getFeed → []; health() true
// store › second handle sees committed write: create via store A on a temp FILE db, open handle B on same file, B.getPost(1) found
//   (proves the flush path; crash-durability of the header rests on core.sync(), called in every mutating method — see code comment)
```

- [ ] **Step 2: Run to verify fail**

Run: `bun test ./servers/ts-bun/src/store.test.ts 2>&1 | tail -5`
Expected: FAIL — `store.ts` missing.

- [ ] **Step 3: Implement `src/store.ts`**: root via `new WriteHashMap(db.rootCursor())`; reads descend with `getCursor` (`null` = absent); mutations in `db.runContext(cursor => {...})` with `putCursor` + `WriteHashSet`/`WriteSortedMap`, **`db.core.sync()` before returning from every mutating method**; feed = `count()` → `getIndexKeyValuePair(start..count)` → `valueCursor.readBytes()` ids → point gets → reverse; `postToJson` manual framing (`{"id":…,"body":…,"created_at":…,"author":…,"like_count":…}`).

- [ ] **Step 4: Run to verify pass**

Run: `bun test ./servers/ts-bun 2>&1 | tail -3`
Expected: PASS, Tasks 1+2 green.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/ts-bun && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: ts xitdb store + like/feed semantics"
```

### Task 3: HTTP server + wiring

**Files:**
- Create: `servers/ts-bun/src/index.ts`; Modify: `servers/ts-bun/{install,build,start}.sh`, `servers/ts-bun/README.md`
- Test: live small-DB smoke with curl (handlers are thin over tested fns)

**Interfaces:**
- Consumes: `Store` + validate/auth from Tasks 1–2.
- Produces: `Bun.serve` on `HOST`/`PORT` honoring `XITDB_PATH`/`JWT_SECRET`; exact bytes per SPEC-XITDB.

- [ ] **Step 1: Write the failing smoke** (nothing serving)

Run: `PORT=3012 bash servers/ts-bun/start.sh & sleep 2; curl -sf http://127.0.0.1:3012/health; echo "EXIT:$?"`
Expected: FAIL — refused (no `node_modules`, `src/index.ts` missing).

- [ ] **Step 2: Implement `src/index.ts`**: `Bun.serve({ hostname: HOST, port: PORT, idleTimeout: 70, fetch(req) {...} })`; switch on `req.method + new URL(req.url).pathname` (`GET /health`, `GET /feed`, `GET /posts/:id` via segment split, `POST /posts`, `POST /posts/:id/like`, else 404 `not found`); `await req.json()` in try/catch; like route awaits auth before id-check; `uptime_s = Math.floor((Date.now()-boot)/1000)`; every response `new Response(body, {status, headers: {"content-type":"application/json"}})`.

- [ ] **Step 3: Wire scripts + README**: `install.sh` (pinned Bun 1.4.4 via official installer), `build.sh` (`cd "$(dirname "$0")" && bun install --frozen-lockfile`), `start.sh` (`exec bun run src/index.ts`); README (run block, Nginx-or-direct with `idleTimeout: 70`, optimizations — mirror go README + the `core.sync()` durability note).

- [ ] **Step 4: Run smoke to verify pass** (fresh small seed)

Run: `cp /tmp/xb-small/feed.xitdb /tmp/xb-ts-smoke.db && XITDB_PATH=/tmp/xb-ts-smoke.db PORT=3012 bun run ./servers/ts-bun/src/index.ts & sleep 2; curl -s http://127.0.0.1:3012/posts/1 | head -c 120; curl -s http://127.0.0.1:3012/feed | python3 -c "import json,sys;print(len(json.load(sys.stdin)['posts']))"`
Expected: post-1 bytes + `20`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/ts-bun && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: ts bun.serve feed server"
```

### Task 4: Gate + CI + docs

**Files:**
- Modify: `.github/workflows/ci.yml` (add `ts-bun` job), `LEADERBOARD-XITDB.md` (ts-bun row)
- Test: `harness/run.sh` (small + full) + k6 smoke

**Interfaces:**
- Consumes: Tasks 1–3 + committed goldens (targets, never regenerated).
- Produces: leaderboard ts-bun row (local numbers, labeled).

- [ ] **Step 1: Run small gate**

Run: `bash harness/run.sh servers/ts-bun 2>&1 | tail -2`
Expected: `passed=42 failed=0`.

- [ ] **Step 2: Run full gate**

Run: `SIZE=full bash harness/run.sh servers/ts-bun 2>&1 | tail -2`
Expected: `passed=42 failed=0`.

- [ ] **Step 3: k6 smoke** (persistent full seed + fresh copy, VUS=50/30s)

Run: `bun ./seed/generate-xitdb.ts --full /tmp/xb-ts-k6 && cp /tmp/xb-ts-k6/feed.xitdb /tmp/xb-ts-k6run.db && (XITDB_PATH=/tmp/xb-ts-k6run.db PORT=3000 bun run ./servers/ts-bun/src/index.ts &) && sleep 2 && k6 run -e BASE_URL=http://127.0.0.1:3000 -e VUS=50 -e DURATION=30s -e RAMP_UP=10s -e TOKENS=/tmp/xb-ts-k6/tokens.json harness/bench/load.js 2>&1 | grep -E "p\(95\)|p\(99\)|checks_failed"; pkill -f 'ts-bun/src/index.ts'`
Expected: thresholds `✓`, `0.00%`.

- [ ] **Step 4: Add CI job** (`setup-bun` 1.4.4 + `bash harness/run.sh servers/ts-bun`, small) and record local numbers in `LEADERBOARD-XITDB.md` ts-bun row.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add -A && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: ts-bun green small+full + ci"
```
