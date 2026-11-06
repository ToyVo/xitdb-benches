# LEADERBOARD-XITDB

Primary: xitdb-vs-xitdb on the same box. Secondary: vs upstream SQLite
numbers (https://benchmarks.arjaythedev.com/12-dollar-server).

Score = max VUs surviving a 5-min hold (`bench/load.js`) with p95<500ms,
p99<1s, <1% errors.

| Server | VUs | p95 | p99 | Notes |
|---|---|---|---|---|
| rust-axum | — | — | — | M1 reference; local smoke VUS=100 p95=10ms p99=16ms, pending M3 hold |
| go-std | — | — | — | local smoke VUS=50 p95=12ms p99=28ms (Mac, full seed); 42/42 small+full; pending M3 hold |
| ts-bun | — | — | — | local smoke VUS=50 p95=8ms p99=12ms (Mac, full seed); 42/42 small+full; pending M3 hold |
| zig-std | — | — | — | scaffold |
| clj-httpkit | — | — | — | scaffold |
| odin-std | — | — | — | scaffold |
| java-spring | — | — | — | scaffold |
