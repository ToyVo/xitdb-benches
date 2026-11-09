// SQLite twin of the canonical seed: same rows as generate-xitdb.ts
// (via rows.ts) sunk into upstream schema.sql instead of xitdb.
//
// Usage:
//   bun ./seed/generate-sqlite.ts --small /tmp/xb-sql-small
//   bun ./seed/generate-sqlite.ts --full /tmp/xb-sql-full
//
// Notes:
// - likes.created_at is never API-visible; it reuses the liked post's
//   created_at (deterministic, plausible).
// - tokens.json is byte-shaped identically (same users, same secret;
//   iat differs per run exactly like the xitdb seed's).
import { Database } from "bun:sqlite";
import { mkdirSync, readFileSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { computeSeed, writeTokens, ts } from "./rows.ts";

export async function generateSqlite(outDir: string, size: "small" | "full"): Promise<void> {
  const { USERS, POSTS, usernames, userCreated, postUser, postCreatedAt,
    postBodyArr, likeTotal, likeUsers, likeStart } = computeSeed(size);
  void USERS;
  void POSTS;
  mkdirSync(outDir, { recursive: true });
  const dbPath = join(outDir, "feed.db");
  rmSync(dbPath, { force: true });

  const schema = readFileSync(join(dirname(import.meta.path), "schema.sql"), "utf8");
  const db = new Database(dbPath);
  try {
    db.exec(schema);
    const insUser = db.prepare("INSERT INTO users(id, username, created_at) VALUES(?, ?, ?)");
    const insPost = db.prepare("INSERT INTO posts(id, user_id, body, created_at) VALUES(?, ?, ?, ?)");
    const insLike = db.prepare("INSERT INTO likes(user_id, post_id, created_at) VALUES(?, ?, ?)");
    const writeAll = db.transaction(() => {
      for (let i = 0; i < usernames.length; i++) {
        insUser.run(i + 1, usernames[i], userCreated[i]);
      }
      for (let i = 0; i < postBodyArr.length; i++) {
        const created = ts(postCreatedAt[i]);
        insPost.run(i + 1, postUser[i], postBodyArr[i], created);
      }
      for (let i = 0; i < postBodyArr.length; i++) {
        const created = ts(postCreatedAt[i]);
        for (let k = likeStart[i]; k < likeStart[i + 1]; k++) {
          insLike.run(likeUsers[k], i + 1, created);
        }
      }
    });
    writeAll();
  } finally {
    db.close();
  }

  writeTokens(outDir, usernames);
  console.log(`  feed.db: users=${usernames.length} posts=${postBodyArr.length} likes=${likeTotal} next_post_id=${postBodyArr.length + 1}`);
}

const args = process.argv.slice(2);
if (import.meta.path === Bun.main) {
  const size = args.includes("--small") ? "small" : "full";
  const outDir = args.find((a) => !a.startsWith("--")) ?? "./seed-sql-out";
  await generateSqlite(outDir, size);
}
