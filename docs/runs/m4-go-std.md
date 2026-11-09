# Run log: go-std M4 re-score (M4a single-pass reads)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: master full seed, fresh copy.
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 23ms | 126ms | 0% |
| 2500 | PASS | 92ms | 616ms | 0% |
| 5000 | FAIL | 6.3s | 7.1s | 0% |
| 3750 | FAIL | 1.38s | 2.46s | 0% |
| 3125 | FAIL | 1.89s | 2.25s | 0% |
| 2812 | FAIL | 648ms | 1.1s | 0% |
| 2656 | FAIL | 611ms | 1.47s | 0% |

Bracket: pass 2500 / fail 2656 (gap 156 ≤ 250). Verdict candidate: **2500**.

## Notes

- The M4a fix moved 2500 from fail (M3 p95 516ms) to pass (p95 92ms),
  but the knee is still immediately above — steep wall 2500→2656.

## Hold (5m at 2500)

- Cool-down: 5 min idle before the hold.
- **FAIL** (not marginal): p95=552ms, p99=2.62s, 0% failed over 92k checks.
  Same 2m-vs-5m tail growth as M3's clj/java/odin (2m p95 92ms → 5m 552ms).
  Per plan: step down 250 → hold at **2250**.

## Hold (5m at 2250)

- **PASS** (exit 0): 83622/83622 checks, p95=128ms, p99=824ms, max=1.95s.

## Verdict: 2250 VUS

The M4a fix improved 2m legs (2500 now passes) but the 5m verdict is
unchanged from M3 (2312) within noise — the hold tail, not the read
path, decides.
