# Run log: rust-axum M4 re-score (fixed code = same code; A1 no-change)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: master full seed, fresh copy (`/root/score-rust-feed.xitdb`).
- Server: `XITDB_PATH=... PORT=80 HOST=0.0.0.0 JWT_SECRET=twelve-dollar-challenge bash start.sh`
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 9ms | 20ms | 0% |
| 2500 | PASS | 40ms | 425ms | 0% |
| 5000 | FAIL | 502ms | 1.69s | 0% (marginal p95) |
| 3750 | PASS | 393ms | 923ms | 0% |
| 4375 | FAIL | 521ms | 2.04s | 0% |
| 4062 | PASS | 349ms | 932ms | 0% |
| 4218 | FAIL | 909ms | 3.05s | 0% |

Bracket: pass 4062 / fail 4218 (gap 156 ≤ 250). Verdict candidate: **4062**.

## Notes

- Same binary as M3 (no code change) but this box holds less (M3: 5000).
  Shared-CPU variance between droplets — the versus table must compare
  M4-vs-M4 on this box, never M3-vs-M4.

## Hold (5m at 4062)

- Cool-down: 5 min idle before the hold.
- **PASS** (exit 0): 150919/150919 checks, p95=178ms, p99=775ms, max=1.95s.

## Verdict: 4062 VUS
