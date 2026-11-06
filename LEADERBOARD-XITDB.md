# LEADERBOARD-XITDB

Primary: xitdb-vs-xitdb on the same box. Secondary: vs upstream SQLite
numbers (https://benchmarks.arjaythedev.com/12-dollar-server).

Score = max VUs surviving a 5-min hold (`bench/load.js`) with p95<500ms,
p99<1s, <1% errors.

| Server | VUs | p95 | p99 | Notes |
|---|---|---|---|---|
| rust-axum | — | — | — | M1 reference, pending M3 hold |
| go-std | — | — | — | scaffold |
| ts-bun | — | — | — | scaffold |
| zig-std | — | — | — | scaffold |
| clj-httpkit | — | — | — | scaffold |
| odin-std | — | — | — | scaffold |
| java-spring | — | — | — | scaffold |
