# Run log: ts-bun M4 re-score (unchanged code)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: master full seed, fresh copy.
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 378ms | 831ms | 0% (noisy window) |
| 2500 | PASS | 205ms | 369ms | 0% |
| 5000 | FAIL | 6.1s | 16.6s | 0% |
| 3750 | FAIL | 3.3s | 4.8s | 0% |
| 3125 | FAIL | 1.4s | 1.7s | 0% |
| 2812 | FAIL | 887ms | 1.34s | 0% |
| 2656 | PASS | 244ms | 443ms | 0% |

Bracket: pass 2656 / fail 2812 (gap 156 ≤ 250). Verdict candidate: **2656**.

## Hold (5m at 2656)

- Cool-down: 5 min idle before the hold.
- **FAIL** (not marginal): p95=1.37s, p99=2.13s, 0% failed over 97k checks.
  Same 2m-vs-5m growth (2m p95 244ms → 5m 1.37s).
  Per plan: step down 250 → hold at **2406**.

## Hold (5m at 2406)

- Attempt 1: **FAIL (marginal split)** — p95=480ms pass, p99=1.07s (7% over), 0% failed.
  Plan rule: one retry after a 5-minute idle cool-down.
- Attempt 2: **PASS** (exit 0) — 88983/88983 checks, p95=240ms, p99=932ms, max=2.04s.

## Verdict: 2406 VUS
