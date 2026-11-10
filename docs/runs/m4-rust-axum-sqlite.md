# Run log: rust-axum-sqlite M4 (twin)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: sqlite master full seed, fresh copy (`/root/score-rust-sqlite-feed.db`).
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 16ms | 114ms | 0% |
| 2500 | FAIL | 404ms | 2.4s | 0% (p99) |
| 1750 | PASS | 17ms | 188ms | 0% |
| 2125 | FAIL | 160ms | 1s | 0% (p99, borderline) |
| 1937 | PASS | 147ms | 457ms | 0% |

Bracket: pass 1937 / fail 2125 (gap 188 ≤ 250). Verdict candidate: **1937**.

## Notes

- The COUNT(*) like-subquery per post (50 per feed) is the visible cost:
  p99-first degradation, same shape as Bun. xitdb's denormalized
  like_count avoids exactly this.
- k6-box SSH was badly wedged mid-ladder (rebooted once); legs run
  detached so no data was lost.

## Hold (5m at 1937)

- Cool-down observed (plus stall time) before the hold.
- **PASS** (exit 0): 72179/72179 checks, p95=184ms, p99=573ms.

## Verdict: 1937 VUS

Versus: xitdb rust-axum 4062 vs sqlite 1937 on this box — xVAS 2.10x.
Same handlers, same box, same method; the delta is the store + the
COUNT(*) joins the denormalized layout avoids.
