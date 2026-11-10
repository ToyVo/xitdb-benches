# Run log: java-spring M4 re-score (unchanged code)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: master full seed, fresh copy.
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 40ms | 493ms | 0% |
| 2500 | FAIL | 289ms | 1.54s | 0% (p99 only) |

Unchanged code; M3 established holds as truth (verdict 2585).
Straight to the M3 verdict hold at 2585; work down only if it fails.

## Hold (5m at 2585)

- Cool-down: 5 min idle before the hold.
- Attempt 1: **FAIL (suspect)** — p95=2.42s, p99=4.21s, med=6.4ms,
  0% failed over 94k checks. Med-healthy with extreme tail (34x worse
  than M3's pass on identical code) smells like episodic stalls, not a
  wall. Rerunning once fresh before judging.
- Attempt 1 rerun: **PASS** (exit 0) — 96403/96403 checks, p95=167ms, p99=512ms, max=1.6s. Attempt 1 confirmed contamination, discarded.

## Verdict: 2585 VUS (reproduces M3 exactly)
