// xitdb-backed feed store. Reads descend with getCursor (no txn);
// every mutation is one runContext + core.sync() (the commit path syncs
// data but NOT the header write, so without sync() 201 is not durable).
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

// SQLite-backed feed store (twin). Same Store interface; canonical SQL.
import { Database } from "bun:sqlite";

const FEED_SQL = `SELECT p.id AS id,p.body AS body,p.created_at AS created_at,u.username AS username,(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id) AS like_count FROM posts p JOIN users u ON u.id=p.user_id ORDER BY p.created_at DESC,p.id DESC LIMIT 20`;

class SqliteStore implements Store {
  constructor(private db: Database) {}

  health(): boolean {
    try {
      this.db.query("SELECT COUNT(*) AS n FROM users").get() as { n: number };
      return true;
    } catch {
      return false;
    }
  }

  getPost(id: number): Post | null {
    const r = this.db.query("SELECT p.id AS id,p.body AS body,p.created_at AS created_at,u.username AS username,(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id) AS like_count FROM posts p JOIN users u ON u.id=p.user_id WHERE p.id=?").get(id) as any;
    if (r === null) return null;
    return { id: r.id, body: r.body, createdAt: r.created_at, author: r.username, likeCount: r.like_count };
  }

  getFeed(): Post[] {
    return (this.db.query(FEED_SQL).all() as any[]).map((r) => ({ id: r.id, body: r.body, createdAt: r.created_at, author: r.username, likeCount: r.like_count }));
  }

  createPost(username: string, body: string): Post {
    const u = this.db.query("SELECT id FROM users WHERE username=?").get(username) as any;
    if (u === null) throw new Error("unknown author");
    const createdAt = new Date().toISOString();
    const info = this.db.query("INSERT INTO posts(user_id,body,created_at) VALUES(?,?,?)").run(u.id, body, createdAt);
    return { id: Number(info.lastInsertRowid), body, createdAt, author: username, likeCount: 0 };
  }

  likePost(id: number, userId: number): { already: boolean } | null {
    const p = this.db.query("SELECT 1 FROM posts WHERE id=?").get(id);
    if (p === null) return null;
    const createdAt = new Date().toISOString();
    const info = this.db.query("INSERT OR IGNORE INTO likes(user_id,post_id,created_at) VALUES(?,?,?)").run(userId, id, createdAt);
    return { already: info.changes === 0 };
  }
}

export function openStore(path: string): Store {
  return new SqliteStore(new Database(path));
}
