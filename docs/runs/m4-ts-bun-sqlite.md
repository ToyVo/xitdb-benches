# Run log: ts-bun-sqlite M4 (twin)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: sqlite master full seed, fresh copy.
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 40ms | 92ms | 0% |
| 2500 | PASS | 52ms | 142ms | 0% |
| 5000 | FAIL | 1.54s | 2.41s | 0% |
| 3750 | PASS | 247ms | 812ms | 0% |
| 4375 | PASS | 405ms | 783ms | 0% |
| 4687 | FAIL | 486ms | 1.37s | 0% (p99) |
| 4531 | FAIL | 947ms | 1.99s | 0% |

Bracket: pass 4375 / fail 4531 (gap 156 ≤ 250). Verdict candidate: **4375**.

## Notes

- Bun+SQLite dramatically outscales Bun+xitdb here (4375 vs 2406
  bracket): bun:sqlite's B-tree reads + page cache beat the xitdb-ts
  read path per-op. Same handlers, same box.

## Hold (5m at 4375)

- Cool-down: 5 min idle before the hold.
- **FAIL** (not marginal): p95=1.23s, p99=2.43s, 0% failed over 160k checks.
  Same 2m-vs-5m growth (2m p95 405ms → 5m 1.23s).
  Per plan: step down 250 → hold at **4125**.

## Hold (5m at 4125)

- **FAIL**: p95=962ms, p99=3.07s, 0% failed over 151k checks.
  Per plan: step down 250 → hold at **3875**.

## Hold (5m at 3875)

- Attempt 1: **FAIL (marginal split)** — p95=337ms pass, p99=1.03s (3% over), 0% failed.
  Plan rule: one retry after a 5-minute idle cool-down.
- Attempt 2: **FAIL** — p95=802ms, p99=1.41s, 0% failed.
  Two consecutive fails → step down 250 per plan: hold at **3625**.

## Hold (5m at 3625)

- **FAIL**: p95=532ms, p99=1.46s, 0% failed over 134k checks.
  Per plan: step down 250 → hold at **3375**.

## Hold (5m at 3375)

- **FAIL**: p95=783ms, p99=1.79s, 0% failed over 124k checks.
  Per plan: step down 250 → hold at **3125**.

## Hold (5m at 3125)

- **FAIL**: p95=751ms, p99=1.49s, 0% failed over 115k checks.
  Five consecutive hold fails (4375→3125) while 2m legs passed to 4375:
  a steep duration-dependent wall (COUNT(*) over a likes table growing
  under write load is the prime suspect). Per plan: step down 250 →
  hold at **2875**.

## Hold (5m at 2875)

- **PASS** (exit 0): 106940/106940 checks, p95=187ms, p99=790ms.

## Verdict: 2875 VUS

Versus: xitdb ts-bun 2406 vs sqlite 2875 on this box — xVAS 0.84x.
SQLite wins: bun:sqlite's B-tree reads beat the xitdb-ts read path per-op,
more than the COUNT(*) subqueries cost. (Five failed holds above show a
steep duration wall, so the verdict sits well below the 2m bracket.)
