// Shared seed-row computation (PRNG order identical to upstream generate.mjs).
// Both the xitdb writer (generate-xitdb.ts) and the SQLite writer
// (generate-sqlite.ts) consume these rows, so the two engines hold the
// same users, posts, bodies, timestamps, and like pairs.
import { createHmac } from "node:crypto";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

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

export const SEED = 42;
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

export const ts = (ms: number): string => new Date(ms).toISOString();

export interface SeedSize {
  users: number;
  posts: number;
  likesTarget: number;
}
export const SIZES: Record<string, SeedSize> = {
  small: { users: 1_000, posts: 10_000, likesTarget: 20_000 },
  full: { users: 50_000, posts: 500_000, likesTarget: 2_000_000 },
};

export interface SeedRows {
  USERS: number;
  POSTS: number;
  usernames: string[];
  userCreated: string[];
  postUser: Uint32Array;
  postCreatedAt: Float64Array;
  postBodyArr: string[];
  perPost: Uint32Array;
  likeTotal: number;
  /** Flat like user-ids; likeStart[i]..likeStart[i+1] belong to post i+1. */
  likeUsers: Uint32Array;
  likeStart: Uint32Array;
}

export function computeSeed(size: "small" | "full"): SeedRows {
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

  // Like pairs in PRNG order (rejection loop identical to generate.mjs).
  const likeStart = new Uint32Array(POSTS + 1);
  for (let i = 0; i < POSTS; i++) likeStart[i + 1] = likeStart[i] + perPost[i];
  const likeUsers = new Uint32Array(likeTotal);
  const seen = new Set<number>();
  for (let i = 0; i < POSTS; i++) {
    const need = perPost[i];
    if (need === 0) continue;
    seen.clear();
    let added = 0;
    while (added < need) {
      const userId = randInt(1, USERS);
      if (seen.has(userId)) continue;
      seen.add(userId);
      likeUsers[likeStart[i] + added] = userId;
      added++;
    }
  }

  return { USERS, POSTS, usernames, userCreated, postUser, postCreatedAt, postBodyArr, perPost, likeTotal, likeUsers, likeStart };
}

export function writeTokens(outDir: string, usernames: string[]): void {
  const b64url = (s: string): string => Buffer.from(s).toString("base64url");
  const header = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const iat = Math.floor(Date.now() / 1000);
  const tokens = usernames.slice(0, TOKEN_COUNT).map((username, i) => {
    const payload = b64url(JSON.stringify({ sub: String(i + 1), username, iat, exp: iat + 3650 * 86400 }));
    const sig = createHmac("sha256", JWT_SECRET).update(`${header}.${payload}`).digest("base64url");
    return { id: i + 1, username, token: `${header}.${payload}.${sig}` };
  });
  writeFileSync(join(outDir, "tokens.json"), JSON.stringify(tokens));
  console.log(`  tokens.json: ${tokens.length} tokens`);
}
