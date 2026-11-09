// Canonical feed.xitdb generator — TS/Bun port of upstream seed/generate.mjs.
// Same PRNG (mulberry32, seed 42), same constants and row logic; rows are
// sunk into the frozen xitdb layout (schema-xitdb.md) instead of SQLite TSVs.
//
// Usage:
//   bun ./seed/generate-xitdb.ts --small /tmp/xb-small   # 1k/10k/20k
//   bun ./seed/generate-xitdb.ts --full /tmp/xb-full     # 50k/500k/~2M (default)
//   bun ./seed/generate-xitdb.ts --small --flavor history /tmp/xb-clj
//   JWT_SECRET=... bun ./seed/generate-xitdb.ts --small /tmp/x
//
// Flavors (--flavor hashmap|history, default hashmap): same rows, different
// root. `hashmap` is the canonical feed.xitdb (HashMap root, sha1-id header)
// served by the Rust/Go/TS/Zig/Odin/Java servers. `history` is feed-clj.xitdb
// (ArrayList root with the canonical map as moment 0, id-0 header) for
// xitdb-clj, whose atom model requires a history root and which opens any
// non-clj1 header in string-key :compat mode.
//
// Interop notes:
// - Hasher id is Hasher.stringToId('sha1') so files match Rust/Go/Zig
//   (xitdb-ts tests default to id 0; we must NOT use that — except the
//   history flavor, which needs id 0 like xitdb-java's default).
// - Fixed fileId 8n so repeated runs are byte-stable apart from tokens.
// - Writes are chunked (10k posts/txn) to bound memory; layout identical
//   to a single bulk txn. Like timestamps are omitted (not API-visible).

import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  Bytes,
  CoreBufferedFile,
  Database,
  Hasher,
  Uint,
  WriteArrayList,
  WriteHashMap,
  WriteHashSet,
  WriteSortedMap,
} from "xitdb";

import { computeSeed, writeTokens, ts, SIZES, feedKey } from "./rows.ts";
// Re-exported for seed/generator.test.ts (imports this module).
export { mulberry32, feedKey } from "./rows.ts";

export type Flavor = "hashmap" | "history";

export async function generate(outDir: string, size: "small" | "full", flavor: Flavor = "hashmap"): Promise<void> {
  const { USERS, POSTS, usernames, userCreated, postUser, postCreatedAt,
    postBodyArr, perPost, likeTotal, likeUsers, likeStart } = computeSeed(size);
  // ---- Phase 1: write rows to xitdb in chunked txns ----
  // Chunk bodies are shared closures: the hashmap flavor wraps each chunk
  // in its own runContext; the history flavor runs all chunks inside one
  // appendContext (same ops, same order — only the txn grouping differs).
  mkdirSync(outDir, { recursive: true });
  const dbName = flavor === "history" ? "feed-clj.xitdb" : "feed.xitdb";
  const dbPath = join(outDir, dbName);
  rmSync(dbPath, { force: true });
  writeFileSync(dbPath, new Uint8Array(0));

  const hasher = flavor === "history"
    ? new Hasher("SHA-1")
    : new Hasher("SHA-1", Hasher.stringToId("sha1"));
  {
    using core = new CoreBufferedFile(dbPath);
    const db = new Database(core, hasher, 8n);

    const writeUsers = (root: WriteHashMap, start: number, end: number): void => {
      const users = new WriteHashMap(root.putCursor("users"));
      for (let i = start; i < end; i++) {
        const u = new WriteHashMap(users.putCursor(String(i + 1)));
        u.put("username", new Bytes(usernames[i]));
        u.put("created_at", new Bytes(userCreated[i]));
      }
    };

    const writePosts = (root: WriteHashMap, start: number, end: number): void => {
      const posts = new WriteHashMap(root.putCursor("posts"));
      const feed = new WriteSortedMap(root.putCursor("feed"));
      const likes = new WriteHashMap(root.putCursor("likes"));
      for (let i = start; i < end; i++) {
        const id = i + 1;
        const created = ts(postCreatedAt[i]);
        const p = new WriteHashMap(posts.putCursor(String(id)));
        p.put("id", new Uint(id));
        p.put("body", new Bytes(postBodyArr[i]));
        p.put("created_at", new Bytes(created));
        p.put("author", new Bytes(usernames[postUser[i] - 1]));
        p.put("like_count", new Uint(perPost[i]));
        feed.put(feedKey(created, id), new Bytes(String(id)));
        void new WriteHashSet(likes.putCursor(String(id)));
      }
    };

    // Likes fill from precomputed pairs (same sets the PRNG produced).
    const writeLikes = (root: WriteHashMap, start: number, end: number): void => {
      const likes = new WriteHashMap(root.putCursor("likes"));
      for (let i = start; i < end; i++) {
        const set = new WriteHashSet(likes.putCursor(String(i + 1)));
        for (let k = likeStart[i]; k < likeStart[i + 1]; k++) {
          set.put(String(likeUsers[k]));
        }
      }
    };

    const writeMeta = (root: WriteHashMap): void => {
      const meta = new WriteHashMap(root.putCursor("meta"));
      meta.put("next_post_id", new Uint(POSTS + 1));
      meta.put("seed_sha", new Bytes("native-ts-v1"));
      meta.put("users", new Uint(USERS));
      meta.put("posts", new Uint(POSTS));
      meta.put("likes", new Uint(likeTotal));
    };

    const logEvery = POSTS >= 100_000;
    const CHUNK = 10_000;
    if (flavor === "history") {
      const history = new WriteArrayList(db.rootCursor());
      history.appendContext(null, (cursor) => {
        const root = new WriteHashMap(cursor);
        for (let start = 0; start < USERS; start += CHUNK) {
          writeUsers(root, start, Math.min(USERS, start + CHUNK));
        }
        for (let start = 0; start < POSTS; start += CHUNK) {
          writePosts(root, start, Math.min(POSTS, start + CHUNK));
          if (logEvery && start % 100_000 === 0) console.log(`  posts ${start + CHUNK}/${POSTS}`);
        }
        for (let start = 0; start < POSTS; start += CHUNK) {
          writeLikes(root, start, Math.min(POSTS, start + CHUNK));
          if (logEvery && start % 100_000 === 0) console.log(`  likes ${start + CHUNK}/${POSTS}`);
        }
        writeMeta(root);
      });
    } else {
      for (let start = 0; start < USERS; start += CHUNK) {
        const end = Math.min(USERS, start + CHUNK);
        db.runContext((cursor) => writeUsers(new WriteHashMap(cursor), start, end));
      }
      for (let start = 0; start < POSTS; start += CHUNK) {
        const end = Math.min(POSTS, start + CHUNK);
        db.runContext((cursor) => writePosts(new WriteHashMap(cursor), start, end));
        if (logEvery && start % 100_000 === 0) console.log(`  posts ${end}/${POSTS}`);
      }
      for (let start = 0; start < POSTS; start += CHUNK) {
        const end = Math.min(POSTS, start + CHUNK);
        db.runContext((cursor) => writeLikes(new WriteHashMap(cursor), start, end));
        if (logEvery && start % 100_000 === 0) console.log(`  likes ${end}/${POSTS}`);
      }
      db.runContext((cursor) => writeMeta(new WriteHashMap(cursor)));
    }
    core.flush();
  }

  // ---- Phase 2: tokens.json (same as generate.mjs) ----
  writeTokens(outDir, usernames);
  console.log(`  ${dbName}: users=${USERS} posts=${POSTS} likes=${likeTotal} next_post_id=${POSTS + 1}`);
}

const args = process.argv.slice(2);
if (import.meta.path === Bun.main) {
  const size = args.includes("--small") ? "small" : "full";
  const flavorIdx = args.findIndex((a) => a === "--flavor" || a.startsWith("--flavor="));
  let flavor: Flavor = "hashmap";
  const consumed = new Set<number>();
  if (flavorIdx >= 0) {
    consumed.add(flavorIdx);
    const eq = args[flavorIdx].split("=", 2)[1];
    if (eq !== undefined) {
      if (eq.includes("history")) flavor = "history";
    } else if (args[flavorIdx + 1] !== undefined && !args[flavorIdx + 1].startsWith("--")) {
      consumed.add(flavorIdx + 1);
      if (args[flavorIdx + 1].includes("history")) flavor = "history";
    }
  }
  const outDir = args.find((a, i) => !a.startsWith("--") && !consumed.has(i)) ?? "./seed-out";
  await generate(outDir, size as "small" | "full", flavor);
}
