# Run log: ts-bun (M3 scoring)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Seed: master full seed, fresh copy (`/root/score-ts.xitdb`).
- Server: `XITDB_PATH=/root/score-ts.xitdb PORT=80 HOST=0.0.0.0 JWT_SECRET=twelve-dollar-challenge bash start.sh`
- Driver: xb-k6 (s-2vcpu-4gb, k6 v1.8.2), same invocation as rust run.

## INVALID first session (zombie-go contamination)

The go-std server was never stopped (its argv is the relative `./bin/server`,
so the `pkill -f go-std/bin/server` pattern missed; `pgrep` false-negatived).
Bun failed to bind (`Failed to start server. Is port 80 in use?` in
`/tmp/prof-score-ts.log`), so every leg below actually hit the still-running
**go** server on its (unlinked) DB file. Thrown out; redone below.

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 23ms | 195ms | 0% |
| 2500 | PASS | 181ms | 711ms | 0% |
| 5000 | FAIL | 3.2s | 3.6s | 0% |
| 3750 | FAIL | 950ms | 1.46s | 0% |
| 3125 | FAIL | 355ms | 1.48s | 0% |
| 2812 | PASS | 102ms | 319ms | 0% |
| 2968 | PASS | 197ms | 797ms | 0% |
| hold 2968 #1 | FAIL | 393ms | 1.04s | 0% |
| hold 2968 #2 | FAIL | 200ms | 1.99s | 0% |
| hold 2718 | PASS | 159ms | 617ms | 0% |

(Observation only, non-protocol: go serving a second session on a larger DB
passed 2500 at p95 181ms where its scored session failed 2500 at p95 516ms —
shared-CPU noise or DB-state effect, not a scored result. Go's verdict stays
2312 per protocol.)

## Valid session (fresh seed, real ts-bun)

- Zombie go killed by PID; port 80 verified free before starting bun.

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 20ms | 81ms | 0% |
| 2500 | FAIL | 274ms | 1.16s | 0% (p99 only) |
| 1750 | PASS | 34ms | 109ms | 0% |
| 2125 | PASS | 201ms | 918ms | 0% |
| 2312 | PASS | 101ms | 694ms | 0% |
| 2406 | PASS | 251ms | 585ms | 0% |

Bracket: pass 2406 / fail 2500 (gap 94 ≤ 250). Verdict candidate: **2406**.

## Hold (5m at 2406)

- Cool-down: 5 min idle before the hold.
- Attempt 1: **FAIL (marginal)** — p95=375ms pass, p99=1.05s (5% over), 0% failed.
  Plan rule: one retry after a 5-minute idle cool-down.
- Attempt 2 (run `ts2-hold2406b`) died mid-run: k6-box sshd wedged, k6 got SIGHUP; doesn't count.
  Switched to detached remote legs (immune to local SSH death); reran as `ts2-hold2406c`.
- Attempt 2 rerun: **PASS** (exit 0) — 89386/89386 checks, p95=166ms, p99=483ms, max=1.45s.

## Verdict: 2406 VUS
