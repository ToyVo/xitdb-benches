// Verifies a generated feed.xitdb: meta counts + spot reads.
// Usage: bun ./seed/verify.ts /path/to/feed.xitdb [--small|--full]
import {
  CoreBufferedFile,
  Database,
  Hasher,
  ReadHashMap,
  ReadSortedMap,
  type ReadCursor,
} from "xitdb";

const [dbPath, wantFlag] = [process.argv[2], process.argv[3] ?? ""];
if (!dbPath) {
  console.error("usage: bun ./seed/verify.ts <feed.xitdb> [--small|--full]");
  process.exit(1);
}
const want = wantFlag === "--small"
  ? { users: 1_000, posts: 10_000, likesMean: 2 }
  : wantFlag === "--full"
    ? { users: 50_000, posts: 500_000, likesMean: 4 }
    : null;

const hasher = new Hasher("SHA-1", Hasher.stringToId("sha1"));
{
  using core = new CoreBufferedFile(dbPath);
  const db = new Database(core, hasher);
  const root = new ReadHashMap(db.rootCursor() as unknown as ReadCursor);

  const metaC = root.getCursor("meta");
  if (!metaC) throw new Error("missing meta");
  const meta = new ReadHashMap(metaC);
  const num = (k: string): number => meta.getCursor(k)!.readUint();
  const users = num("users");
  const posts = num("posts");
  const likes = num("likes");
  const nextId = num("next_post_id");
  console.log(`meta: users=${users} posts=${posts} likes=${likes} next_post_id=${nextId}`);
  if (nextId !== posts + 1) throw new Error(`next_post_id ${nextId} != posts+1`);

  const feedC = root.getCursor("feed");
  if (!feedC) throw new Error("missing feed");
  const feedCount = new ReadSortedMap(feedC).count();
  console.log(`feed index count=${feedCount}`);
  if (feedCount !== posts) throw new Error("feed count != posts");

  const postsC = root.getCursor("posts");
  if (!postsC) throw new Error("missing posts");
  const postsMap = new ReadHashMap(postsC);
  for (const id of [1, Math.min(2, posts), posts]) {
    const pc = postsMap.getCursor(String(id));
    if (!pc) throw new Error(`missing post ${id}`);
    const p = new ReadHashMap(pc);
    const body = new TextDecoder().decode(p.getCursor("body")!.readBytes(null));
    const author = new TextDecoder().decode(p.getCursor("author")!.readBytes(null));
    const lc = p.getCursor("like_count")!.readUint();
    if (!body || !author) throw new Error(`post ${id} empty fields`);
    if (id === 1) console.log(`post 1: author=${author} like_count=${lc} body_len=${body.length}`);
  }

  if (want) {
    if (users !== want.users) throw new Error(`users ${users} != ${want.users}`);
    if (posts !== want.posts) throw new Error(`posts ${posts} != ${want.posts}`);
    const mean = likes / posts;
    if (Math.abs(mean - want.likesMean) > 1.5) throw new Error(`likes mean ${mean} far from ${want.likesMean}`);
  }
  console.log("verify: OK");
}
