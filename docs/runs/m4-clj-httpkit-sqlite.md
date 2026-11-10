# Run log: clj-httpkit-sqlite M4 (twin)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: sqlite master full seed, fresh copy.
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 99ms | 187ms | 0% |
| 2500 | FAIL | 1.95s | 2.4s | 0% |
| 1750 | FAIL | 151ms | 1.08s | 0% (p99) |
| 1375 | PASS | 262ms | 522ms | 0% |
| 1562 | FAIL | 2.03s | 3.01s | 0% |

Bracket: pass 1375 / fail 1562 (gap 187 ≤ 250). Verdict candidate: **1375**.

## Notes

- JVM+JDBC + COUNT(*) subqueries: the twin tops out early. The xitdb
  twin's single-deref feed (one snapshot read, no joins) is exactly the
  shape SQLite punishes most here.

## Hold (5m at 1375)

- Cool-down: 5 min idle before the hold.
- **PASS** (exit 0): 50968/50968 checks, p95=180ms, p99=933ms (close).

## Verdict: 1375 VUS

Versus: xitdb clj-httpkit 5187 vs sqlite 1375 on this box — xVAS 3.77x,
the widest gap. The single-deref snapshot feed is xitdb-optimal and
SQL-pessimal in equal measure.
