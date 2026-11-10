# Run log: clj-httpkit M4 re-score (unchanged code)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: history-flavor master full seed, fresh copy.
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 20ms | 38ms | 0% |
| 5000 | PASS | 23ms | 70ms | 0% |

Unchanged code; M3 established the 2m bracket (pass 5625 / fail 5781).
Straight to the M3 verdict hold at 5187; work down only if it fails.

## Hold (5m at 5187)

- Cool-down: 5 min idle before the hold.
- **PASS** (exit 0): 193714/193714 checks, p95=24ms, p99=82ms, max=1.22s.

## Verdict: 5187 VUS (reproduces M3 exactly)
