import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { CoreMemory, CoreBufferedFile, Database, Hasher } from "xitdb";
import { openStore, type Store } from "./store.ts";

function openMemoryStore(): Store {
  const core = new CoreMemory();
  const hasher = new Hasher("SHA-1", Hasher.stringToId("sha1"));
  const db = new Database(core, hasher);
  return openStore(db);
}

test("store › round trip", () => {
  const st = openMemoryStore();
  const p = st.createPost("alice", "hi");
  assert.strictEqual(p.id, 1);
  assert.strictEqual(p.body, "hi");
  assert.strictEqual(p.author, "alice");
  assert.strictEqual(p.likeCount, 0);
  assert.match(p.createdAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  assert.deepStrictEqual(st.getPost(1), p);
  assert.strictEqual(st.getPost(999), null);
  st.createPost("alice", "second");
  const feed = st.getFeed();
  assert.deepStrictEqual(feed.map((x) => x.id), [2, 1]);
});

test("store › like idempotent", () => {
  const st = openMemoryStore();
  st.createPost("alice", "x");
  assert.deepStrictEqual(st.likePost(1, 7), { already: false });
  assert.deepStrictEqual(st.likePost(1, 7), { already: true });
  assert.strictEqual(st.getPost(1)!.likeCount, 1);
  assert.strictEqual(st.likePost(999, 7), null);
});

test("store › missing keys", () => {
  const st = openMemoryStore();
  assert.strictEqual(st.getPost(12345), null);
  assert.strictEqual(st.likePost(12345, 9), null);
  assert.deepStrictEqual(st.getFeed(), []);
  assert.strictEqual(st.health(), true);
});

test("store › second handle sees committed write", () => {
  const dir = mkdtempSync(join(tmpdir(), "xb-ts-"));
  try {
    const path = join(dir, "f.xitdb");
    {
      const core = new CoreBufferedFile(path);
      const hasher = new Hasher("SHA-1", Hasher.stringToId("sha1"));
      const db = new Database(core, hasher, 8n);
      const st = openStore(db);
      st.createPost("alice", "durable?");
      core[Symbol.dispose]();
    }
    const core2 = new CoreBufferedFile(path);
    const db2 = new Database(core2, new Hasher("SHA-1", Hasher.stringToId("sha1")));
    const st2 = openStore(db2);
    const p = st2.getPost(1);
    assert.ok(p, "second handle must see the committed post");
    assert.strictEqual(p.body, "durable?");
    core2[Symbol.dispose]();
  } finally {
    rmSync(dir, { recursive: true });
  }
});
