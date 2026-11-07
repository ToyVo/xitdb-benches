# Run log: rust-axum (M3 scoring)

- load.js sha: `14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972`
- Seed: master full seed (`/root/seed-master/feed.xitdb`, 966MB, deterministic seed 42),
  fresh copy per server start (`/root/score-rust.xitdb`).
- Server: `XITDB_PATH=/root/score-rust.xitdb PORT=80 HOST=0.0.0.0 JWT_SECRET=twelve-dollar-challenge bash start.sh`
- Driver: xb-k6 (s-2vcpu-4gb after resize, k6 v1.8.2), `k6 run -e BASE_URL=http://178.128.235.251 -e TOKENS=/root/tokens.json -e VUS=<n> -e DURATION=<d> /root/load.js`

## Ladders (2m legs unless noted)

| VUS | result | p95 | p99 | failed |
|---|---|---|---|---|
| 1000 (warm-up) | PASS | 10ms | 24ms | 0% |
| 2500 | FAIL (infra) | 6ms | 11ms | 27% dial timeouts — fd limit 1024, fixed in start.sh (`ulimit -n 65536`), fresh seed |
| 2500 | PASS | 18ms | 43ms | 0% |
| 5000 | PASS | 187ms | 718ms | 0% |
| 10000 | FAIL | 8.2s | 9.3s | 0% (latency only, server stays up) |
| 7500 | FAIL | 3.5s | 4.3s | 0% |
| 6250 | FAIL | 3.2s | 4.6s | 0% |
| 5625 | FAIL | 1.7s | 2.9s | 0% |
| 5312 | FAIL | 1.3s | 2.5s | 0% |
| 5156 | FAIL | 767ms | 1.08s | 0% |

Bracket: pass 5000 / fail 5156 (gap 156 ≤ 250). Verdict candidate: **5000**.

## Notes

- First 2500 failure was infrastructure, not the server: the 1gb k6 driver
  OOM-starved (fixed by resizing to s-2vcpu-4gb), then the bench's 1024 fd
  soft limit vs 2500 keep-alive conns (fixed via `ulimit -n 65536` in all
  start.sh scripts, committed as f93b500).
- Failure mode above the knee is pure latency (p95 cliff between 5000 and
  5156); zero failed requests at every level — the server never falls over.
- One 7500 leg died ~30s in from a hung SSH session (no k6 process, no OOM);
  clean rerun recorded above.

## Hold (5m at 5000)

- Cool-down: 5 min idle before the hold.
- **PASS** (exit 0): 185652/185652 checks, p95=299ms, p99=711ms, max=2.06s.

## Verdict: 5000 VUS
