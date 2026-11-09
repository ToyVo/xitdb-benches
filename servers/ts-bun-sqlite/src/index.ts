import { verifyJWT } from "./auth.ts";
import { openStore, postToJson, type Post, type Store } from "./store.ts";
import { trimBody, validPostId } from "./validate.ts";

const DB_PATH = process.env.XITDB_PATH ?? "feed.xitdb";
const SECRET = process.env.JWT_SECRET ?? "twelve-dollar-challenge";
const HOST = process.env.HOST ?? "127.0.0.1";
const PORT = Number(process.env.PORT ?? "3000");
const BOOT = Date.now();

const store: Store = openStore(DB_PATH);

function json(status: number, body: string): Response {
  return new Response(body, { status, headers: { "content-type": "application/json" } });
}

function err(status: number, msg: string): Response {
  return json(status, `{"error":"${msg}"}`);
}

function bearer(req: Request): string | null {
  const v = req.headers.get("authorization");
  if (v === null || !v.startsWith("Bearer ")) return null;
  return v.slice("Bearer ".length);
}

function postJson(p: Post): string {
  return `{"post":${postToJson(p)}}`;
}

const server = Bun.serve({
  hostname: HOST,
  port: PORT,
  idleTimeout: 70,
  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;
    if (req.method === "GET" && path === "/health") {
      if (!store.health()) {
        return json(503, `{"status":"degraded","db":"unreachable","error":"read failed"}`);
      }
      const uptime = Math.floor((Date.now() - BOOT) / 1000);
      return json(200, `{"status":"ok","db":"ok","uptime_s":${uptime}}`);
    }
    if (req.method === "GET" && path === "/feed") {
      try {
        const posts = store.getFeed();
        return json(200, `{"posts":[${posts.map(postToJson).join(",")}]}`);
      } catch {
        return err(500, "internal server error");
      }
    }
    let m: RegExpMatchArray | null;
    if (req.method === "GET" && (m = path.match(/^\/posts\/([^/]+)$/)) !== null) {
      const id = validPostId(m[1]);
      if (id === null) return err(400, "invalid post id");
      try {
        const p = store.getPost(id);
        if (p === null) return err(404, "post not found");
        return json(200, postJson(p));
      } catch {
        return err(500, "internal server error");
      }
    }
    if (req.method === "POST" && path === "/posts") {
      const token = bearer(req);
      if (token === null) return err(401, "missing bearer token");
      const auth = await verifyJWT(token, SECRET);
      if ("error" in auth) return err(401, auth.error);
      let raw: unknown;
      try {
        raw = await req.json();
      } catch {
        return err(400, "malformed JSON body");
      }
      const body = raw !== null && typeof raw === "object" ? (raw as Record<string, unknown>).body : undefined;
      const checked = trimBody(body);
      if (!checked.ok) return err(400, checked.error);
      try {
        const p = store.createPost(auth.username, checked.value);
        return json(201, postJson(p));
      } catch {
        return err(500, "internal server error");
      }
    }
    if (req.method === "POST" && (m = path.match(/^\/posts\/([^/]+)\/like$/)) !== null) {
      // Auth first, then id (spec order).
      const token = bearer(req);
      if (token === null) return err(401, "missing bearer token");
      const auth = await verifyJWT(token, SECRET);
      if ("error" in auth) return err(401, auth.error);
      const id = validPostId(m[1]);
      if (id === null) return err(400, "invalid post id");
      try {
        const outcome = store.likePost(id, auth.userId);
        if (outcome === null) return err(404, "post not found");
        const status = outcome.already ? 200 : 201;
        return json(status, `{"liked":true,"already_liked":${outcome.already},"post_id":${id}}`);
      } catch {
        return err(500, "internal server error");
      }
    }
    return err(404, "not found");
  },
});

console.log(`serving ${DB_PATH} on http://${server.hostname}:${server.port}`);
