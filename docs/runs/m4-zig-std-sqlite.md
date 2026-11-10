# Run log: zig-std-sqlite M4 (twin)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: sqlite master full seed, fresh copy.
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 71ms | 639ms | 0% |
| 2500 | FAIL | 466ms | 1.34s | 0% (p99) |
| 1750 | FAIL | 499ms | 1.84s | 0% (p95 by 1ms) |
| 1375 | PASS | 68ms | 154ms | 0% |
| 1562 | PASS | 367ms | 952ms | 0% |

Bracket: pass 1562 / fail 1750 (gap 188 ≤ 250). Verdict candidate: **1562**.

## Notes

- Hand-rolled SQLite FFI + single-threaded loop: the COUNT(*) subqueries
  dominate, and there's no connection-level parallelism to hide behind.

## Hold (5m at 1562)

- Cool-down: 5 min idle before the hold.
- **PASS** (exit 0): 58202/58202 checks, p95=189ms, p99=487ms.

## Verdict: 1562 VUS

Versus: xitdb zig-std 2875 vs sqlite 1562 on this box — xVAS 1.84x.
