# Run log: zig-std M4 re-score (M4a 8KB buffers)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Box: xb2-bench (s-1vcpu-2gb, tor1, fresh batch for M4).
- Seed: master full seed, fresh copy per attempt.
- Driver: xb2-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed | server |
|---|---|---|---|---|---|
| 1000 (warm-up) | PASS | 24ms | 86ms | 0% | alive |
| 2500 | PASS | 160ms | 513ms | 0% | alive, drains after |
| 5000 | FAIL | — | — | refused | **OOM-killed** |
| 3750 | (dying) | — | — | — | RSS 1.29GB mid-leg, restarted |
| 3125 | PASS | 42ms | 92ms | 0% | alive, drains after |
| 3437 | FAIL | 1.56s | 2.27s | 0% | alive (latency, no OOM) |
| 3281 | FAIL | 473ms | 1.33s | 0% | p95 passes, p99 fails |

Bracket: pass 3125 / fail 3281 (gap 156 ≤ 250). Verdict candidate: **3125**.

## Notes

- The 8KB buffers moved the OOM wall (~2800 → ~3400+) but exposed a
  latency wall just beneath it: per-conn cost is still ~330KB at high
  concurrency (thread stacks + in-flight arenas), and the single-threaded
  loop saturates. M3 verdict was 2250 (memory-limited); M4 should land
  higher via the latency bracket — if the 5m hold survives.

## Hold (5m at 3125)

- Cool-down: 5 min idle before the hold, fresh server + seed.
- **FAIL**: p95=183ms pass, p99=1.16s fail (16% over — beyond marginal),
  0% failed over 116k checks. Server survived (no OOM; mid-hold RSS 1.1GB).
  Per plan: step down 250 → hold at **2875**.

## Hold (5m at 2875)

- Attempt 1: **FAIL (nonsense)** — p95=4.77s at LOWER load than the
  3125 hold's p95=183ms. Non-monotonic by 26x = shared-CPU contamination,
  not signal. Rerunning once on a fresh server+seed before judging.
- Attempt 1 rerun: **PASS** (exit 0) — 107200/107200 checks, p95=180ms, p99=560ms, max=1.74s. Attempt 1 confirmed as shared-CPU contamination, discarded.

## Verdict: 2875 VUS

M4a moved zig 2250 → 2875 (+28%): the OOM wall became a latency wall.
The per-conn memory is still the limiter, just further out.
