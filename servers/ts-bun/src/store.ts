// xitdb-backed feed store. Reads descend with getCursor (no txn);
// every mutation is one runContext + core.sync() (the commit path syncs
// data but NOT the header write, so without sync() 201 is not durable).
import {
  Bytes,
  Database,
  ReadHashMap,
  ReadSortedMap,
  Uint,
  WriteHashMap,
  WriteHashSet,
  WriteSortedMap,
} from "xitdb";
import { feedKey } from "./validate.ts";

const MAX_READ: number | null = 8 * 1024;

export interface Post {
  id: number;
  body: string;
  createdAt: string;
  author: string;
  likeCount: number;
}

export function postToJson(p: Post): string {
  return (
    `{"id":${p.id},"body":${JSON.stringify(p.body)},` +
    `"created_at":${JSON.stringify(p.createdAt)},` +
    `"author":${JSON.stringify(p.author)},"like_count":${p.likeCount}}`
  );
}

export interface Store {
  health(): boolean;
  getFeed(): Post[];
  getPost(id: number): Post | null;
  createPost(username: string, body: string): Post;
  likePost(id: number, userId: number): { already: boolean } | null;
}

class XitStore implements Store {
  constructor(private db: Database) {}

  health(): boolean {
    try {
      this.db.committedSize();
      return true;
    } catch {
      return false;
    }
  }

  getPost(id: number): Post | null {
    const root = new WriteHashMap(this.db.rootCursor());
    const postsC = root.getCursor("posts");
    if (postsC === null) return null;
    return readPost(new ReadHashMap(postsC), String(id));
  }

  getFeed(): Post[] {
    const root = new WriteHashMap(this.db.rootCursor());
    const feedC = root.getCursor("feed");
    if (feedC === null) return [];
    const feed = new ReadSortedMap(feedC);
    const count = feed.count();
    const ids: string[] = [];
    for (let i = Math.max(0, count - 20); i < count; i++) {
      const kv = feed.getIndexKeyValuePair(i);
      if (kv === null) continue;
      ids.push(new TextDecoder().decode(kv.valueCursor.readBytes(MAX_READ)));
    }
    const postsC = root.getCursor("posts");
    if (postsC === null) return [];
    const posts = new ReadHashMap(postsC);
    const out: Post[] = [];
    for (const id of ids) {
      const p = readPost(posts, id);
      if (p !== null) out.push(p);
    }
    return out.reverse();
  }

  createPost(username: string, body: string): Post {
    let created!: Post;
    this.db.runContext((cursor) => {
      const root = new WriteHashMap(cursor);
      const meta = new WriteHashMap(root.putCursor("meta"));
      const nextC = meta.getCursor("next_post_id");
      const next = nextC === null ? 1 : nextC.readUint();
      const createdAt = new Date().toISOString();
      const posts = new WriteHashMap(root.putCursor("posts"));
      const idStr = String(next);
      const pm = new WriteHashMap(posts.putCursor(idStr));
      pm.put("id", new Uint(next));
      pm.put("body", new Bytes(body));
      pm.put("created_at", new Bytes(createdAt));
      pm.put("author", new Bytes(username));
      pm.put("like_count", new Uint(0));
      const feed = new WriteSortedMap(root.putCursor("feed"));
      feed.put(feedKey(createdAt, next), new Bytes(idStr));
      const likes = new WriteHashMap(root.putCursor("likes"));
      void new WriteHashSet(likes.putCursor(idStr));
      meta.put("next_post_id", new Uint(next + 1));
      created = { id: next, body, createdAt, author: username, likeCount: 0 };
    });
    this.db.core.sync();
    return created;
  }

  likePost(id: number, userId: number): { already: boolean } | null {
    const idStr = String(id);
    const userStr = String(userId);
    let outcome: { already: boolean } | null = null;
    this.db.runContext((cursor) => {
      const root = new WriteHashMap(cursor);
      const posts = new WriteHashMap(root.putCursor("posts"));
      if (readPost(posts, idStr) === null) return;
      const likes = new WriteHashMap(root.putCursor("likes"));
      const set = new WriteHashSet(likes.putCursor(idStr));
      if (set.getCursor(userStr) !== null) {
        outcome = { already: true };
        return;
      }
      set.put(userStr);
      const pm = new WriteHashMap(posts.putCursor(idStr));
      const lcC = pm.getCursor("like_count");
      if (lcC === null) throw new Error("corrupt post: missing like_count");
      pm.put("like_count", new Uint(lcC.readUint() + 1));
      outcome = { already: false };
    });
    this.db.core.sync();
    return outcome;
  }
}

function readPost(posts: ReadHashMap, id: string): Post | null {
  const pc = posts.getCursor(id);
  if (pc === null) return null;
  const pm = new ReadHashMap(pc);
  const text = (key: string): string => {
    const c = pm.getCursor(key);
    if (c === null) throw new Error(`corrupt post: missing ${key}`);
    return new TextDecoder().decode(c.readBytes(MAX_READ));
  };
  const num = (key: string): number => {
    const c = pm.getCursor(key);
    if (c === null) throw new Error(`corrupt post: missing ${key}`);
    return c.readUint();
  };
  return { id: num("id"), body: text("body"), createdAt: text("created_at"), author: text("author"), likeCount: num("like_count") };
}

export function openStore(db: Database): Store {
  return new XitStore(db);
}
