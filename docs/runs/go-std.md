# Run log: go-std (M3 scoring)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Seed: master full seed, fresh copy (`/root/score-go.xitdb`).
- Server: `XITDB_PATH=/root/score-go.xitdb PORT=80 HOST=0.0.0.0 JWT_SECRET=twelve-dollar-challenge bash start.sh`
- Driver: xb-k6 (s-2vcpu-4gb, k6 v1.8.2), same invocation as rust run.

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 18ms | 43ms | 0% |
| 2500 | FAIL | 516ms | 1.22s | 0% (marginal — 3% over the p95 line) |
| 1750 | PASS | 37ms | 692ms | 0% |
| 2125 | PASS | 71ms | 418ms | 0% |
| 2312 | PASS | 100ms | 308ms | 0% |
| 2406 | FAIL | 848ms | 1.55s | 0% |

Bracket: pass 2312 / fail 2406 (gap 94 ≤ 250). Verdict candidate: **2312**.

## Notes

- Failure mode is pure latency like rust, but the knee is much lower and
  softer: p99 degrades (692ms at 1750) well before p95 crosses.
- Zero failed requests at every level.

## Hold (5m at 2312)

- Cool-down: 5 min idle before the hold.
- **PASS** (exit 0): 86089/86089 checks, p95=129ms, p99=569ms, max=997ms.

## Verdict: 2312 VUS
