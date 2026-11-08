# Run log: odin-std (M3 scoring)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Seed: master full seed, fresh copy per attempt (`/root/score-odin.xitdb`).
- Server: `XITDB_PATH=/root/score-odin.xitdb PORT=80 HOST=0.0.0.0 JWT_SECRET=twelve-dollar-challenge bash start.sh`
- Driver: xb-k6 (s-2vcpu-4gb, k6 v1.8.2).

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed | server |
|---|---|---|---|---|---|
| 1000 (warm-up) | PASS | 20ms | 131ms | 0% | alive |
| 2500 | FAIL | — | — | 99.8% refused | **OOM-killed** (anon 1.79GB) |
| 1500 | PASS | 14ms | 33ms | 0% | alive (RSS 346MB mid-leg) |
| 2000 | PASS | 25ms | 214ms | 0% | alive (RSS 453MB mid-leg, drains after) |
| 2250 | PASS | 21ms | 99ms | 0% | alive after |

Bracket: pass 2250 / fail 2500 (gap 250). Verdict candidate: **2250**.

## Notes

- Same per-connection-memory wall as zig, steeper (~230KB/conn sustained):
  2500 conns OOM the 2GB box. Memory is transient (freed on close, no leak).
- Latency is superb until the wall (p99 < 220ms at 2000).

## Hold (5m at 2250)

- **FAIL**: 82% refused, p99 48s — OOM-killed mid-hold (dmesg).
  Per-conn memory grows with requests served, so 2m legs mask what 5m
  holds expose. Death ≈ ~90-100k requests into the run.
  Stepping down to a hold at **1500** (~68k reqs/5m).

## Hold (5m at 1500)

- Fresh server + seed. Mid-hold: alive, RSS 647MB.
- **PASS**: 55962/55962 checks, p95=21ms, p99=87ms, max=436ms.

Hold bracket: pass 1500 / fail 2250 (gap 750). Narrowing with a hold
at **1875**.

## Hold (5m at 1875)

- Fresh server + seed.
- **PASS**: 70028/70028 checks, p95=19ms, p99=61ms, max=389ms.

Hold bracket: pass 1875 / fail 2250 (gap 375). Closing with a hold
at **2062**.

## Hold (5m at 2062)

- Fresh server + seed.
- **PASS**: 76976/76976 checks, p95=21ms, p99=203ms, max=1.16s.

## Verdict: 2062 VUS

Hold bracket: pass 2062 / fail 2250 (gap 188 ≤ 250). Note the 2m legs
passed 2250 easily — only the 5m hold exposes the per-request memory
growth. Scoring by holds was essential here.
