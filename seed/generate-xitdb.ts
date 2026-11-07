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

import { createHmac } from "node:crypto";
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

export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function feedKey(createdAt: string, id: number): string {
  return `${createdAt}\x00${String(id).padStart(10, "0")}`;
}

const SEED = 42;
const JWT_SECRET = process.env.JWT_SECRET ?? "twelve-dollar-challenge";
const TOKEN_COUNT = 20_000;
const END = Date.parse("2026-01-01T00:00:00Z");
const DAY = 86_400_000;

const ADJECTIVES = ["quiet", "brave", "clever", "sunny", "rusty", "swift", "lazy", "mellow", "sharp", "wild", "cosmic", "tiny", "golden", "silver", "happy", "grumpy", "curious", "lucky", "salty", "zesty"];
const NOUNS = ["otter", "falcon", "badger", "comet", "river", "maple", "pixel", "walrus", "ember", "glacier", "lantern", "meadow", "nebula", "orchid", "pebble", "quartz", "raven", "sparrow", "thistle", "willow"];
const WORDS = (
  "the a an and but or so because while after before just really very kind of sort of maybe probably definitely " +
  "server database request latency cache index query benchmark droplet cpu memory disk network throughput users " +
  "coffee morning weekend project deploy release bug feature test rewrite refactor commit branch merge review " +
  "thinking building shipping learning reading writing debugging measuring watching waiting running walking " +
  "fast slow small big cheap simple boring clever weird surprising honest careful lucky tired ready done broken " +
  "today tonight tomorrow yesterday again finally never always sometimes usually rarely once twice " +
  "this that these those here there everywhere nowhere something nothing everything anything someone " +
  "nginx node postgres typescript express linux ubuntu systemd load steal swap kernel socket keepalive pool"
).split(/\s+/);
const OPENERS = ["Hot take:", "TIL", "Unpopular opinion:", "Note to self:", "PSA:", "Okay so", "Update:", "Honestly,", "Reminder:", "Question:"];

const ts = (ms: number): string => new Date(ms).toISOString();

interface SeedSize {
  users: number;
  posts: number;
  likesTarget: number;
}
const SIZES: Record<string, SeedSize> = {
  small: { users: 1_000, posts: 10_000, likesTarget: 20_000 },
  full: { users: 50_000, posts: 500_000, likesTarget: 2_000_000 },
};

export type Flavor = "hashmap" | "history";

export async function generate(outDir: string, size: "small" | "full", flavor: Flavor = "hashmap"): Promise<void> {
  const { users: USERS, posts: POSTS, likesTarget: LIKES } = SIZES[size];
  const rand = mulberry32(SEED);
  const randInt = (lo: number, hi: number): number => lo + Math.floor(rand() * (hi - lo + 1));
  const pick = <T>(arr: T[]): T => arr[Math.floor(rand() * arr.length)];
  const expo = (mean: number): number => -mean * Math.log(1 - rand());

  function sentence(): string {
    const n = randInt(4, 14);
    const words: string[] = [];
    for (let i = 0; i < n; i++) words.push(pick(WORDS));
    const s = words.join(" ");
    return s.charAt(0).toUpperCase() + s.slice(1) + pick([".", ".", ".", "!", "?", "..."]);
  }
  function postBody(): string {
    const parts: string[] = [];
    if (rand() < 0.25) parts.push(pick(OPENERS));
    const sentences = randInt(1, 3);
    for (let i = 0; i < sentences; i++) parts.push(sentence());
    let body = parts.join(" ");
    if (body.length > 500) body = body.slice(0, 497) + "...";
    return body;
  }

  // ---- Phase 0: generate rows in PRNG order (identical to generate.mjs) ----
  const usernames: string[] = [];
  const userCreated: string[] = [];
  for (let i = 0; i < USERS; i++) {
    const username = `${pick(ADJECTIVES)}_${pick(NOUNS)}_${i + 1}`;
    usernames.push(username);
    userCreated.push(ts(END - 730 * DAY + rand() * 365 * DAY));
  }

  const postStart = END - 365 * DAY;
  const step = (365 * DAY) / POSTS;
  const postUser = new Uint32Array(POSTS);
  const postCreatedAt = new Float64Array(POSTS);
  const postBodyArr: string[] = new Array(POSTS);
  for (let i = 0; i < POSTS; i++) {
    postUser[i] = 1 + Math.floor(USERS * rand() * rand());
    postCreatedAt[i] = postStart + i * step + rand() * step * 0.9;
    postBodyArr[i] = postBody();
  }

  const meanPerPost = LIKES / POSTS;
  const popularMean = meanPerPost * 20;
  const normalMean = Math.max(0.05, (meanPerPost - 0.01 * popularMean + 0.5) / 0.99);
  const cap = Math.min(USERS, Math.max(50, Math.round(popularMean * 10)));
  const perPost = new Uint32Array(POSTS);
  let likeTotal = 0;
  for (let i = 0; i < POSTS; i++) {
    const n = Math.min(cap, Math.floor(expo(rand() < 0.01 ? popularMean : normalMean)));
    perPost[i] = n;
    likeTotal += n;
  }

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

    // Likes fill, chunked by post range. PRNG order matches generate.mjs
    // (distinct users per post via rejection); timestamps omitted.
    const seen = new Set<number>();
    const writeLikes = (root: WriteHashMap, start: number, end: number): void => {
      const likes = new WriteHashMap(root.putCursor("likes"));
      for (let i = start; i < end; i++) {
        const need = perPost[i];
        if (need === 0) continue;
        seen.clear();
        const set = new WriteHashSet(likes.putCursor(String(i + 1)));
        let added = 0;
        while (added < need) {
          const userId = randInt(1, USERS);
          if (seen.has(userId)) continue;
          seen.add(userId);
          set.put(String(userId));
          added++;
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
  const b64url = (s: string): string => Buffer.from(s).toString("base64url");
  const header = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const iat = Math.floor(Date.now() / 1000);
  const tokens = usernames.slice(0, TOKEN_COUNT).map((username, i) => {
    const payload = b64url(JSON.stringify({ sub: String(i + 1), username, iat, exp: iat + 3650 * 86400 }));
    const sig = createHmac("sha256", JWT_SECRET).update(`${header}.${payload}`).digest("base64url");
    return { id: i + 1, username, token: `${header}.${payload}.${sig}` };
  });
  writeFileSync(join(outDir, "tokens.json"), JSON.stringify(tokens));
  console.log(`  ${dbName}: users=${USERS} posts=${POSTS} likes=${likeTotal} next_post_id=${POSTS + 1}`);
  console.log(`  tokens.json: ${tokens.length} tokens`);
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
