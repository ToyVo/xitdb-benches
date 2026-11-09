import { test } from "node:test";
import assert from "node:assert/strict";
import { SignJWT } from "jose";
import { verifyJWT } from "./auth.ts";

const SECRET = "twelve-dollar-challenge";

async function sign(payload: Record<string, unknown>, secret = SECRET): Promise<string> {
  return await new SignJWT(payload)
    .setProtectedHeader({ alg: "HS256" })
    .sign(new TextEncoder().encode(secret));
}

test("verifyJWT good token", async () => {
  const now = Math.floor(Date.now() / 1000);
  const tok = await sign({ sub: "1", username: "alice", iat: now, exp: now + 3600 });
  assert.deepStrictEqual(await verifyJWT(tok, SECRET), { userId: 1, username: "alice" });
});

test("verifyJWT rejects bad signatures", async () => {
  const now = Math.floor(Date.now() / 1000);
  const cases: Record<string, string> = {
    "bad-sig": await sign({ sub: "1", username: "alice", iat: now, exp: now + 3600 }, "wrong-secret"),
    expired: await sign({ sub: "1", username: "alice", iat: now - 7200, exp: now - 3600 }),
    garbage: "abc",
    "alg-none": "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiIxIiwidXNlcm5hbWUiOiJhbGljZSIsImlhdCI6MTc2MjgzNjkwMCwiZXhwIjoxNzYyODQwNTAwfQ.",
  };
  for (const [name, tok] of Object.entries(cases)) {
    assert.deepStrictEqual(await verifyJWT(tok, SECRET), { error: "invalid or expired token" }, name);
  }
});

test("verifyJWT rejects bad payloads", async () => {
  const now = Math.floor(Date.now() / 1000);
  const cases: Record<string, Record<string, unknown>> = {
    "string-sub": { sub: "abc", username: "alice", iat: now, exp: now + 3600 },
    "numeric-sub": { sub: 9, username: "alice", iat: now, exp: now + 3600 },
    "missing-username": { sub: "1", iat: now, exp: now + 3600 },
    "numeric-username": { sub: "1", username: 123, iat: now, exp: now + 3600 },
  };
  for (const [name, payload] of Object.entries(cases)) {
    const tok = await sign(payload);
    assert.deepStrictEqual(await verifyJWT(tok, SECRET), { error: "invalid token payload" }, name);
  }
});

test("verifyJWT leeway parity", async () => {
  const now = Math.floor(Date.now() / 1000);
  const justExpired = await sign({ sub: "1", username: "alice", iat: now - 3600, exp: now - 30 });
  assert.deepStrictEqual(await verifyJWT(justExpired, SECRET), { userId: 1, username: "alice" });
});
