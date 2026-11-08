# LEADERBOARD-XITDB

Primary: xitdb-vs-xitdb on the same box. Secondary: vs upstream SQLite
numbers (https://benchmarks.arjaythedev.com/12-dollar-server).

Score = max VUs surviving a 5-min hold (`bench/load.js`,
sha `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`)
with p95<500ms, p99<1s, <1% errors.

Box: DigitalOcean Basic `s-1vcpu-2gb` (1 vCPU, 2GB), tor1, Ubuntu 24.04,
direct `:80`, k6 v1.8.2 from a same-region `s-2vcpu-4gb` driver.
Full seed (50k users / 500k posts / ~2M likes, 966MB); clj scored on the
history-flavor seed (634MB). Each server: fresh seed copy, warm-up, double,
narrow, cool-down, 5-min hold. Full logs in `docs/runs/`.

| Server | VUs | p95 | p99 | Notes |
|---|---|---|---|---|
| clj-httpkit | 5187 | 35ms | 296ms | flat to 5000, then a 5m p99 cliff; holds (not 2m legs) set the verdict |
| rust-axum | 5000 | 299ms | 711ms | steep knee 5000→5156; zero failed requests at every level |
| java-spring | 2585 | 71ms | 308ms | violent p99 wall 2390→2781 (250ms→1.76s); -Xmx1g, no memory drama |
| ts-bun | 2406 | 166ms | 483ms | p99-first shape; hold needed one retry (marginal) then passed |
| go-std | 2312 | 129ms | 569ms | soft knee; p99 degrades well before p95 |
| zig-std | 2250 | 258ms | 704ms | ~330KB/conn OOMs the box above ~2800 conns; superb latency until the wall |
| odin-std | 2062 | 21ms | 203ms | per-request conn-lifetime growth OOMs 5m holds; 2m legs pass 2250 easily |

Order of finish: rust → go → ts (one invalid session thrown out, rescored)
→ zig → clj → odin → java. Two servers (zig, odin) are memory-wall-limited
on 2GB; the other five are latency-limited. Nobody drops requests until
their wall — every failure above is latency or OOM, never errors at low load.
