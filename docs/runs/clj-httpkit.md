# Run log: clj-httpkit (M3 scoring)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Seed: history flavor full seed (`/root/seed-master-history/feed-clj.xitdb`,
  634MB), fresh copy per server start (`/root/score-clj-feed-clj.xitdb`).
  Tokens: hashmap tokens.json (signature-only auth; smoke-verified 200).
- Server: `XITDB_PATH=/root/score-clj-feed-clj.xitdb PORT=80 HOST=0.0.0.0 JWT_SECRET=twelve-dollar-challenge bash start.sh`
- Driver: xb-k6 (s-2vcpu-4gb, k6 v1.8.2), same invocation as other runs.

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 18ms | 40ms | 0% |
| 2500 | PASS | 18ms | 37ms | 0% |
| 5000 | PASS | 26ms | 94ms | 0% |
| 10000 | FAIL | 3.0s | 37s | 0% (server stays up) |
| 7500 | FAIL | 505ms | 5.6s | 0% |
| 6250 | FAIL | 120ms | 2.9s | 0% |
| 5625 | PASS | 30ms | 194ms | 0% |
| 5937 | FAIL | 45ms | 1.5s | 0% |
| 5781 | FAIL | 53ms | 1.9s | 0% |

Bracket: pass 5625 / fail 5781 (gap 156 ≤ 250). Verdict candidate: **5625**.

## Notes

- http-kit + history design scales flat to 5000 (p99 94ms), then the p99
  tail explodes while p95 holds — same p99-first signature as Bun, higher up.
- Zero failed requests at every level; the JVM never wavers.

## Hold (5m at 5625)

- Cool-down: 5 min idle before the hold.
- **FAIL** (not marginal): p95=52ms pass, p99=1.84s, 0% failed over 208k checks.
  Note: same VUS passed 2m at p99 194ms — the tail grows ~9x from 2m to 5m
  (history file growth under write load and/or JVM drift; possibly noise).
  Per plan: step down 250 → hold at **5375**.

## Hold (5m at 5375)

- **FAIL**: p95=60ms pass, p99=2.07s fail, 0% failed over 200k checks.
  Same signature as 5625 — stepping down didn't move p99, so the 5m tail
  blowup is time-dependent, not load-dependent (history heap growth under
  sustained writes, JVM drift, or shared-CPU noise).
  Testing one level with 10x 2m-headroom: hold at **5000**.

## Hold (5m at 5000)

- **PASS**: 186624/186624 checks, p95=28ms, p99=138ms, max=1.81s.
  The 5m wall is load-dependent after all (between 5000 and 5375).
  Bracket: hold-pass 5000 / hold-fail 5375 (gap 375). Closing with a hold
  at **5187**.

## Hold (5m at 5187)

- **PASS**: 193555/193555 checks, p95=35ms, p99=296ms, max=2.1s.

## Verdict: 5187 VUS

Bracket: hold-pass 5187 / hold-fail 5375 (gap 188 ≤ 250). 2m legs
systematically underestimate the 5m p99 tail for this server — holds are
the source of truth here.
