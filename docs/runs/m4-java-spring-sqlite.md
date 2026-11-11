# Run log: java-spring-sqlite M4 (twin)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: sqlite master full seed, fresh copy.
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 36ms | 619ms | 0% |
| 2500 | PASS | 80ms | 350ms | 0% |
| 5000 | FAIL | 350ms | 1.32s | 0% (p99) |
| 3750 | FAIL | 210ms | 1.43s | 0% (p99) |
| 3125 | PASS | 124ms | 509ms | 0% |
| 3437 | PASS | 125ms | 941ms | 0% |
| 3593 | PASS | 92ms | 496ms | 0% |

Bracket: pass 3593 / fail 3750 (gap 157 ≤ 250). Verdict candidate: **3593**.

## Notes

- p99-first shape like xitdb java, but the knee sits much higher.

## Hold (5m at 3593)

- Cool-down: 5 min idle before the hold.
- **FAIL** (not marginal): p95=198ms pass, p99=1.36s fail, 0% failed over 133k checks.
  Same 2m-vs-5m tail growth (2m p99 496ms → 5m 1.36s).
  Per plan: step down 250 → hold at **3343**.

## Hold (5m at 3343)

- **FAIL**: p95=341ms pass, p99=1.84s fail, 0% failed over 124k checks.
  Per plan: step down 250 → hold at **3093**.

## Hold (5m at 3093)

- **PASS** (exit 0): 115248/115248 checks, p95=103ms, p99=314ms.

## Verdict: 3093 VUS

Versus: xitdb java-spring 2585 vs sqlite 3093 on this box — xVAS 0.84x.
SQLite wins on the JVM too (xerial outreads xitdb-java per-op).
