# Run log: go-std-sqlite M4 (twin)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: sqlite master full seed, fresh copy.
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 142ms | 513ms | 0% |
| 2500 | FAIL | 2.19s | 3.06s | 0% |
| 1750 | PASS | 382ms | 941ms | 0% |
| 2125 | PASS | 497ms | 876ms | 0% (3ms of headroom) |
| 2312 | PASS | 105ms | 657ms | 0% |

Bracket: pass 2312 / fail 2500 (gap 188 ≤ 250). Verdict candidate: **2312**.

## Notes

- Non-monotonic 2m legs (2125 p95 497ms, then 2312 p95 105ms) — noisy
  box; the bracket still closes honestly.

## Hold (5m at 2312)

- Cool-down: 5 min idle before the hold.
- **PASS** (exit 0): 85830/85830 checks, p95=184ms, p99=616ms.

## Verdict: 2312 VUS

Versus: xitdb go-std 2250 vs sqlite 2312 on this box — xVAS 0.97x,
a dead heat. Go's wall is elsewhere than the store (HTTP layer) for
both engines.
