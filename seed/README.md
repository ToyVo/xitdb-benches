# seed/

Single TS/Bun generator → `feed.xitdb` + `tokens.json` for all 7 servers.

```bash
cd seed && bun install
bun ./generate-xitdb.ts --small /tmp/xb-small   # 1k users / 10k posts / ~20k likes
bun ./verify.ts /tmp/xb-small/feed.xitdb --small
bun ./generate-xitdb.ts --full /tmp/xb-full     # 50k / 500k / ~2M
bun test                                         # mulberry32 + feedKey unit tests
```

Notes:

- PRNG and row logic ported line-for-line from upstream
  `seed/generate.mjs` (mulberry32 seed 42). Like timestamps omitted
  (not API-visible); like user sets stay deterministic.
- Hasher id is `Hasher.stringToId('sha1')` to match Rust/Go/Zig file
  headers (xitdb-ts tests default to id 0 — do not use that here).
- Fixed fileId `8n` for byte-stable runs (tokens carry wall-clock `iat`).
- Writes chunked (10k posts/txn) to bound memory; on-disk layout is
  identical to one bulk txn. `meta` carries
  `{next_post_id, seed_sha, users, posts, likes}` counts for fast verify.
