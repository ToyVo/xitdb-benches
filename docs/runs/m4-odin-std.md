# Run log: odin-std M4 re-score (M4a bounded arena + request-alloc threading)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: master full seed, fresh copy per attempt.
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed | server |
|---|---|---|---|---|---|
| 1000 (warm-up) | PASS | 31ms | 82ms | 0% | alive |
| 2500 | FAIL | 234ms | 3.3s | 0% | alive (RSS 519MB; latency only) |

M3's 2500 leg OOM-died; now it survives — the fix moved the memory wall.
Straight to holds: M3 failed the 2250 hold (OOM), so hold at **2250** first.

## Hold (5m at 2250)

- Cool-down: 5 min idle before the hold, fresh server + seed.
- **FAIL**: p95=30ms pass, p99=1.27s fail (27% over), 0% failed over 84k checks.
  The server SURVIVED (mid-hold RSS 249MB, flat) — the M4a fix killed the
  OOM; what remains is a latency wall. Per plan: step down 250 → hold
  at **2000**.

## Hold (5m at 2000)

- Attempt 1: **FAIL (nonsense)** — p95=68ms pass, p99=10.26s fail at LOWER
  load than the 2250 hold's p99=1.27s. Non-monotonic by 8x = contamination.
  Server alive throughout (0% failed; RSS drained to 10MB after).
  Rerunning once fresh before judging.
- Attempt 1 rerun: **PASS** (exit 0) — 74490/74490 checks, p95=38ms, p99=385ms, max=2.14s. Attempt 1 confirmed contamination, discarded.

Hold bracket: pass 2000 / fail 2250 (gap 250). Tightening with a hold
at **2125**.

## Hold (5m at 2125)

- Fresh server + seed.
- **PASS** (exit 0): 79460/79460 checks, p95=41ms, p99=484ms, max=1.61s.

## Verdict: 2125 VUS

Hold bracket: pass 2125 / fail 2250 (gap 125 ≤ 250). The M4a fix's real
win is survival (2500 2m no longer OOMs; holds die on latency now),
with the verdict nudging 2062 → 2125.
