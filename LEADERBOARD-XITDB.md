# LEADERBOARD-XITDB

Primary: xitdb-vs-xitdb on the same box. Secondary: vs upstream SQLite
numbers (https://benchmarks.arjaythedev.com/12-dollar-server).

Score = max VUs surviving a 5-min hold (`bench/load.js`,
sha `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`)
with p95<500ms, p99<1s, <1% errors.

## M3 (first droplet batch)

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

## M4 (fixed servers vs SQLite twins, same box)

Box: fresh `s-1vcpu-2gb` + `s-2vcpu-4gb` k6 driver, tor1, Ubuntu 24.04,
same script, same thresholds. xitdb servers carry the M4a fixes (go
single-pass reads, zig 8KB buffers, odin bounded arena; rust unchanged —
RwLock is type-impossible); twins serve the SQLite seed (275MB) with
byte-identical handlers. xVAS = xitdb VUs ÷ SQLite VUs on this box.

| Server | xitdb VUs | SQLite VUs | xVAS | Notes |
|---|---|---|---|---|
| clj-httpkit | 5187 | 1375 | **3.77x** | widest gap: single-deref snapshot feed vs 50 COUNT(*)s |
| rust-axum | 4062 | 1937 | **2.10x** | identical Axum handlers; denormalized like_count vs COUNT(*) |
| zig-std | 2875 | 1562 | **1.84x** | fix moved OOM→latency wall; twin capped by single-threaded COUNT(*)s |
| go-std | 2250 | 2312 | 0.97x | dead heat: wall is in shared HTTP code, not the store |
| odin-std | 2125 | 2250 | 0.94x | near tie; fix turned OOM deaths into headroom on both |
| ts-bun | 2406 | 2875 | 0.84x | bun:sqlite outreads xitdb-ts per-op |
| java-spring | 2585 | 3093 | 0.84x | xerial outreads xitdb-java per-op |

Reading the table: the engine gap is implementation-specific, not
universal. Where xitdb wins (Rust 2.1x, Clojure 3.8x, Zig 1.8x), the
common factor is read amplification the denormalized layout avoids —
50 posts × per-post lookups resolve to one stored object, while the
twins pay 50 `COUNT(*)` subqueries per feed. Where SQLite wins (Bun,
Java 0.84x), its B-tree + page cache beats the xitdb-ts/xitdb-java
per-op read path. Go and Odin tie: their ceilings live in shared
server code either way.

Caveats: M3-vs-M4 xitdb numbers are NOT comparable across batches
(same rust binary held 5000 on the M3 box, 4062 here — droplet variance).
Every xVAS above is same-box, same-batch, same-method. Full logs in
`docs/runs/m4-*.md`. Contaminated legs (shared-CPU noise) were rerun
and are marked as such in the logs, never silently kept.
