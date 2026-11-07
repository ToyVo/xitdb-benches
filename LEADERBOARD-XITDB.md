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
| zig-std | — | — | — | local smoke VUS=50 p95=4ms p99=10ms (Mac, full seed); 42/42 small+full; pending M3 hold |
| clj-httpkit | — | — | — | local smoke VUS=50 p95=17ms p99=22ms (Mac, full clj seed, post-tune); 42/42 small+full; pending M3 hold |
| odin-std | — | — | — | local smoke VUS=50 p95=9ms p99=24ms (Mac, full seed); 42/42 small+full; pending M3 hold |
| java-spring | — | — | — | local smoke VUS=50 p95=11ms p99=28ms (Mac, full seed); 42/42 small+full; pending M3 hold |
