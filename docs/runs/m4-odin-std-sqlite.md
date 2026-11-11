# Run log: odin-std-sqlite M4 (twin)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: sqlite master full seed, fresh copy per attempt.
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed | server |
|---|---|---|---|---|---|
| 1000 (warm-up) | PASS | 61ms | 130ms | 0% | alive |
| 2500 | FAIL | — | — | 99% refused | **OOM-killed** (anon 1.77GB) |
| 1500 | PASS | 23ms | 55ms | 0% | alive (RSS 186MB) |
| 2000 | PASS | 36ms | 124ms | 0% | alive (RSS 125MB) |
| 2250 | PASS | 56ms | 177ms | 0% | alive (RSS 139MB) |

Bracket: pass 2250 / fail 2500-OOM (gap 250). Verdict candidate: **2250**.

## Notes

- Same per-conn shape as xitdb odin (thread-per-conn + SQLite call
  depth ≈ heavier stacks), but the A4 arena discipline carries over:
  no request-lifetime growth, frees on close. Memory scales with
  concurrency past saturation (124KB/conn at 2000, 700KB/conn at 2500).

## Hold (5m at 2250)

- Cool-down: 5 min idle before the hold, fresh server + seed.
- **PASS** (exit 0): 83854/83854 checks, p95=140ms, p99=871ms.
  Server alive throughout, drained to 31MB after (no growth).

## Verdict: 2250 VUS

Versus: xitdb odin-std 2125 vs sqlite 2250 on this box — xVAS 0.94x,
a near tie with a slight SQLite edge.
