# xitdb-benches

$12 Server Challenge API on **xitdb** instead of SQLite — 7 language
servers racing each other primarily, the published SQLite leaderboard
secondarily.

- `SPEC-XITDB.md` — upstream SPEC + xitdb deltas (`XITDB_PATH`, root-read health, fsync durability).
- `schema-xitdb.md` — frozen canonical layout (all 7 share it).
- `seed/` — single TS/Bun generator → `feed.xitdb` + `tokens.json`.
- `harness/` — `test-xitdb.sh` (42 checks), `run.sh`, vendored `bench/load.js` + `bench/nginx.conf`.
- `servers/<name>/` — one per stack; each honors `install.sh`/`build.sh`/`start.sh` + `HOST`/`PORT`/`XITDB_PATH`/`JWT_SECRET`.
- `docker-compose.yml` — local 7x run (rust 3001 … java 3007).

Status: M1 — Rust/Axum reference green; other 6 scaffolded (boot + `/health`).
