# Run log: java-spring (M3 scoring)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Seed: master full seed, fresh copy (`/root/score-java.xitdb`).
- Server: `XITDB_PATH=/root/score-java.xitdb PORT=80 HOST=0.0.0.0 JWT_SECRET=twelve-dollar-challenge bash start.sh`
- Driver: xb-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 29ms | 105ms | 0% |
| 2500 | PASS | 296ms | 978ms | 0% |
| 5000 | FAIL | 2.5s | 3.1s | 0% |
| 3750 | FAIL | 513ms | 1.07s | 0% (marginal) |
| 3125 | PASS | 191ms | 494ms | 0% |
| 3437 | FAIL | 956ms | 2.3s | 0% |
| 3281 | PASS | 403ms | 765ms | 0% |

Bracket: pass 3281 / fail 3437 (gap 156 ≤ 250). Verdict candidate: **3281**.

## Notes

- Steep wall between 3125 and 3437 (p95 191ms → 956ms); zero failed
  requests at every level. No memory drama (JVM capped at -Xmx1g).

## Hold (5m at 3281)

- Cool-down: 5 min idle before the hold.
- **FAIL** (not marginal): p95=1.15s, p99=2.86s, 0% failed over 121k checks.
  Same 2m-vs-5m tail growth seen on clj (2m p95 403ms → 5m 1.15s).
  Per plan: step down 250 → hold at **3031**.

## Hold (5m at 3031)

- **FAIL (split)**: p95=392ms pass, p99=1.91s fail, 0% failed over 112k checks.
  The p99 tail (p99/p95 ≈ 5x) points at GC pauses or CPU steals.
  Per plan: step down 250 → hold at **2781**.

## Hold (5m at 2781)

- **FAIL**: p95=495ms pass (5ms of headroom), p99=1.76s fail, 0% failed.
  p99 is flat (~1.8s) across 3031→2781 while p95 scales — the tail may be
environmental (disk stalls?) rather than load-driven. Holding at **2000**
to discriminate, with iostat sampled mid-hold.

## Hold (5m at 2000)

- **PASS**: 74588/74588 checks, p95=70ms, p99=254ms, max=481ms.
  The tail is load-driven (254ms here vs 1760ms at 2781) — no environmental
gremlin. Hold bracket: pass 2000 / fail 2781 (gap 781). Narrowing with a
hold at **2390**.

## Hold (5m at 2390)

- **PASS**: 89093/89093 checks, p95=66ms, p99=250ms, max=502ms.

Hold bracket: pass 2390 / fail 2781 (gap 391). Closing with a hold
at **2585**.

## Hold (5m at 2585)

- **PASS**: 96217/96217 checks, p95=71ms, p99=308ms, max=611ms.

## Verdict: 2585 VUS

Hold bracket: pass 2585 / fail 2781 (gap 196 ≤ 250). The p99 tail is
violently load-driven (250ms at 2390 → 1760ms at 2781); holds, not 2m
legs, set the verdict.
