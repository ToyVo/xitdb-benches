# SPEC-XITDB (delta from upstream SPEC.md)

Upstream: https://github.com/arjaythedev/twelve-dollar-server-challenge/blob/main/SPEC.md
This file records only the xitdb deltas. Everything else (5 endpoints,
exact compact JSON, key order, error table, JWT rules, k6 loop, scoring)
is verbatim upstream.

## Deltas

- `SQLITE_PATH` → `XITDB_PATH`: path to a fresh copy of `feed.xitdb`
  (canonical layout in `schema-xitdb.md`). `start.sh` copies the seed
  file fresh; servers never generate at boot.
- Health: `SELECT 1` → xitdb root read (open root `HashMap`, read
  `meta` or `count()`). Success → 200
  `{"status":"ok","db":"ok","uptime_s":<int>}`; failure → 503
  `{"status":"degraded","db":"unreachable","error":<string>}`.
- Durability: WAL + `synchronous=NORMAL`-or-stronger → `FileCore`
  fsync:true, one xitdb txn per mutating request, 201 means committed
  + fsynced. Group commit allowed only if each response waits its commit.
- `JWT_SECRET`: `twelve-dollar-challenge` (same). `HOST`/`PORT`:
  `127.0.0.1`/`3000` behind Nginx, `0.0.0.0`/`80` direct (same).
- Feed ordering: `ORDER BY created_at DESC, id DESC` implemented via
  `feed_key = created_at + '\0' + id_padded_10` in the `feed`
  SortedMap; read = `count()` → `iter_from_index(count-20)` → reverse.
- Post object key order frozen: `id,body,created_at,author,like_count`.
  `like_count` is stored state (denormalized at write), not a cache
  under rule 5. No response/query caches, table copies, or JWT
  memoization; verify HS256 signature + `exp` + `alg==HS256` every request.
