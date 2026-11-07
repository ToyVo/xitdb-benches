# M3 Droplet Shootout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Score all 7 conformant servers on one $12 droplet with the upstream procedure, and publish the numbers in `LEADERBOARD-XITDB.md`.

**Architecture:** User-operated runbook (the agent has no droplet access): provision exactly the upstream box, prove every server green on it with the small seed, then score each on a fresh full seed one at a time — warm-up, double-to-fail, narrow to ±250, confirm with a 5-minute hold — and record full k6 summaries plus notes.

**Tech Stack:** DigitalOcean Basic droplet (1 vCPU, 2 GB RAM, no swap, Ubuntu 24.04 x86_64); k6 from a separate machine; this repo's `install.sh`/`build.sh`/`start.sh` + `harness/bench/load.js`.

**Spec:** `docs/superpowers/specs/2026-11-06-xitdb-benches-design.md` (§§6–8: harness, milestones, scoring) + upstream challenge README scoring section (warm-up 1000 VUs/2 min unscored; find-limit from 2500 doubling; narrow to within 250; confirm 5-min hold; pass = p95 < 500ms, p99 < 1s, < 1% errors).

## Global Constraints

- One server on the droplet at a time; nothing else tuned (no kernel params, no pinning); in-process settings only.
- Every scored run starts from a FRESH full-seed copy (`feed.xitdb`, or `feed-clj.xitdb` for clj-httpkit); the seed file itself is never served.
- Direct serve on `0.0.0.0:80` for all scored runs (saves the 14–20% Nginx CPU); one Nginx confirmation run for the overall leader only, using vendored `harness/bench/nginx.conf` on `127.0.0.1:3000`.
- k6 runs from a separate machine (`BASE_URL` Sowohl khẩu the droplet's IP); `TOKENS` points at the matching seed's `tokens.json`.
- `LEADERBOARD-XITDB.md` keeps the exact columns (Server, VUs, p95, p99, Notes) — primary xitdb-vs-xitdb; SQLite stays a secondary reference to the published upstream numbers (no SQLite re-runs).
- Each server's 42/42 gate must pass ON THE DROPLET (small seed) before it may be scored; a server that OOMs scores its last passing hold.

## Review Focus

- Shared-CPU noise (1 vCPU shared with OS): a hold that fails marginally gets ONE retry after a 5-minute idle cool-down; two consecutive fails step down 250 — decided in Task 2 procedure, recorded in the run log.
- History growth on clj-httpkit (every write appends a moment): holds are measured on a growing file, which is the honest number for that design — noted in its leaderboard row, not normalized away.
- Disk pressure (7 × ~1GB seeds + growth): delete each run's working copy before the next server; `df -h` check is part of the per-server setup — in Task 2 steps.
- Token/JWT expiry mid-batch: tokens live 10 years; a non-issue, stated so nobody re-checks it mid-batch.
- Upstream load.js drift: vendor hash recorded before the batch; if upstream changed it mid-batch, freeze the vendored copy and note the hash — in Task 1 steps.

---

### Task 1: Droplet provisioning + on-box green gate

**Files:**
- Create: `docs/droplet.md` (runbook: provision → install → build → small-gate matrix)
- Modify: none (code changes only if a server fails on-box)

**Interfaces:**
- Consumes: each server's `install.sh`/`build.sh`/`start.sh` + `harness/` scripts.
- Produces: a droplet where `bash harness/run.sh servers/<name>` passes 42/42 for all 7 (small seed), recorded in `docs/droplet.md` with versions (`<tool> --version` outputs).

- [ ] **Step 1: Provision the box**

Run (user, DigitalOcean console): create Basic droplet, 1 vCPU / 2 GB RAM / no swap, Ubuntu 24.04 x86_64, note its IP as `$DROPLET`; `ssh root@$DROPLET 'uname -a && free -h'`.
Expected: Ubuntu 24.04 x86_64, ~2GB, no swap line.

- [ ] **Step 2: Install toolchains via our scripts**

Run (user, as root on the droplet): `git clone <repo> && cd xitdb-benches && for s in rust-axum go-std ts-bun zig-std java-spring clj-httpkit odin-std; do bash servers/$s/install.sh; done`.
Expected: each prints its pinned version (rust 1.85.0, go 1.23.x, bun 1.4.4, zig 0.17.0, temurin 21 + maven 3.10.0, clojure CLI, odin dev-2026-10); any failure stops the batch and is fixed before proceeding.

- [ ] **Step 3: Small-gate matrix on the box**

Run (user, non-root): `for s in rust-axum go-std ts-bun zig-std java-spring clj-httpkit odin-std; do (FLAVOR=history for clj only) bash harness/run.sh servers/$s; done`.
Expected: seven `passed=42 failed=0` lines; record tool versions + any install.sh fixes as commits.

- [ ] **Step 4: Commit the runbook**

```bash
git add docs/droplet.md && git commit -m "docs: droplet provision + on-box gates"
```

### Task 2: Scoring procedure (per server, one at a time)

**Files:**
- Create: `docs/runs/<server>.md` (one log per server: commands, k6 summaries, verdict)
- Modify: none

**Interfaces:**
- Consumes: green-gated droplet from Task 1 + `harness/bench/load.js` (record `sha256sum` first).
- Produces: per-server max-VU verdict + full k6 tail for the leaderboard.

- [ ] **Step 1: Freeze load.js + fresh full seed + warm-up** (example: rust-axum; repeat per server, `feed-clj` for clj)

Run (user): `sha256sum harness/bench/load.js | tee docs/runs/loadjs.sha` — all scored runs use this exact file.

Run (user): generate full seed on the droplet (`bun ./seed/generate-xitdb.ts --full /srv/seed-full` once, copy per run), start the server on the copy, `k6 run -e BASE_URL=http://$DROPLET -e VUS=1000 -e DURATION=2m bench/load.js`.
Expected: completes (unscored); server stays up.

- [ ] **Step 2: Find the limit**

Run (user): `k6 run ... -e VUS=2500`, doubling VUS until a run fails thresholds, then binary-narrow to within 250.
Expected: a failing VUS and a passing VUS ≤250 apart; every command + result appended to `docs/runs/<server>.md`.

- [ ] **Step 3: Confirm with a 5-minute hold**

Run (user): one `DURATION=5m` hold at the passing number; on fail, step down 250 and hold again (max one retry after 5-min idle, per Review Focus).
Expected: a held VUS with p95 < 500ms, p99 < 1s, errors < 1%; `df -h` + `dmesg | grep -i oom` (empty) recorded; working copy deleted afterwards.

- [ ] **Step 4: Commit the run logs**

```bash
git add docs/runs/ && git commit -m "docs: m3 run logs <server>"
```

### Task 3: Leaderboard write-up + SQLite comparison

**Files:**
- Modify: `LEADERBOARD-XITDB.md`
- Test: re-read every `docs/runs/*.md` number into the table (two-person check: author fills, reviewer diffs against logs)

**Interfaces:**
- Consumes: `docs/runs/*.md` + upstream published leaderboard (secondary reference only).
- Produces: final table (Server, VUs, p95, p99, Notes) with per-entry notes (direct-vs-nginx, clj history-growth note, any OOM/step-down notes) + one paragraph comparing the top xitdb score against the published SQLite best without re-running SQLite.

- [ ] **Step 1: Fill the table from the logs**

Each row's VUs/p95/p99 copied verbatim from its confirmed hold; notes name direct-serve (all) plus the single nginx confirmation (leader only, if run).
Expected: `LEADERBOARD-XITDB.md` diff shows 7 filled rows, no `—` left.

- [ ] **Step 2: Review + commit + publish**

Reviewer diffs every cell against `docs/runs/`, then:
```bash
git add LEADERBOARD-XITDB.md && git commit -m "docs: m3 leaderboard" && git push origin HEAD:main
```
(Push needs the human's yes per harness norms; publishing the repo itself is a separate explicit yes.)
