# harness/

Conformance + benchmark harness (xitdb port of upstream `test/` + `bench/`).

```bash
# full gate, small seed (PR CI)
bash harness/run.sh servers/rust-axum
# full seed (nightly / pre-publish)
SIZE=full bash harness/run.sh servers/rust-axum
# suite only (server already running on a FRESH db)
bash harness/test-xitdb.sh http://127.0.0.1:3000 harness/golden-small
# regenerate goldens (only when seed logic or bytes intentionally change)
bash harness/gen-golden.sh small|full
# skeleton contracts
bash harness/contracts.sh
```

Files:

- `test-xitdb.sh` — verbatim port of upstream `test/test.sh` (42 checks).
  Only deltas: `GOLDEN_DIR` (`golden-small` default, 2nd arg overrides).
- `run.sh` — port of upstream `test/run.sh`: generates a fresh
  `feed.xitdb` (`--$SIZE`), builds, starts, waits ≤60s for `/health`,
  runs the suite, tears down. Needs bun + curl/jq/openssl.
- `gen-golden.sh` — captures `golden-{small,full}/feed.json +
  post-{1,mid,last}.json` from a fresh boot. Deterministic by
  construction (fixed PRNG + fixed fileId); re-run and diff to confirm.
- `golden-small/` (1k/10k seed) / `golden-full/` (50k/500k seed).
- `bench/load.js` + `bench/nginx.conf` — vendored byte-identical from
  upstream. k6: `k6 run -e BASE_URL=... -e VUS=100 bench/load.js`.
- `contracts.sh` — skeleton gate (all 7 honor install/build/start).
