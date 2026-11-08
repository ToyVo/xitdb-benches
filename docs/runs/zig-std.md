# Run log: zig-std (M3 scoring)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Seed: master full seed, fresh copy per attempt (`/root/score-zig.xitdb`).
- Server: `XITDB_PATH=/root/score-zig.xitdb PORT=80 HOST=0.0.0.0 JWT_SECRET=twelve-dollar-challenge bash start.sh`
- Driver: xb-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs)

| VUS | result | p95 | p99 | failed | server |
|---|---|---|---|---|---|
| 1000 (warm-up) | PASS | 14ms | 36ms | 0% | alive |
| 2500 | PASS | 49ms | 537ms | 0% | (unchecked) |
| 5000 | FAIL | 501ms | 13.3s | 88% | **OOM-killed** (anon 1.46GB) |
| 3750 | FAIL | — | — | high | **OOM-killed** |
| 3125 | FAIL | — | — | high | **OOM-killed** |
| 2812 | FAIL | 4ms | 2.5s | 95% | **OOM-killed** |
| 2656 | FAIL | 94ms | 1.4s | 0% | dead after body |
| 2578 | PASS (exit 0) | 129ms | 397ms | 0% | dead after body |

Zig's wall is survival, not latency: per-connection arenas accumulate under
keep-alive until the OOM killer fires. Verdict must be a level that survives
a full 5-minute hold. Candidate: **2500**.

## Hold (5m at 2500)

- Fresh server + seed. Cool-down observed.
- **FAIL**: p95=631ms, p99=1.99s, 5.61% failed requests.
- (Methodology note: several mid-batch "server dead" readings were an
  artifact — `pidof zig` never matches; the binary is named `server`.
  Only dmesg OOM lines and k6 summaries are trustworthy. The four
  collapsed legs (5000/3750/3125/2812) match the four dmesg oom-kills.)

## Hold (5m at 2250)

- Fresh server + seed. Mid-hold sample: alive, RSS 747MB, 0 oom-kills.
- **PASS**: 83658/83658 checks, p95=258ms, p99=704ms, max=1.97s.

## Verdict: 2250 VUS

Failure mode: per-connection memory (~330KB/conn: 128KB buffers + thread
stacks + in-flight request arenas) OOMs the 2GB box above ~2800 sustained
conns. Latency is excellent until the memory wall.
