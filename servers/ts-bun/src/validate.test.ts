import { test } from "node:test";
import assert from "node:assert/strict";
import { feedKey, validPostId, trimBody } from "./validate.ts";

test("feedKey format + ordering", () => {
  assert.strictEqual(feedKey("2025-01-01T00:00:00.000Z", 7), "2025-01-01T00:00:00.000Z\x000000000007");
  assert.ok(feedKey("2025-01-01T00:00:00.000Z", 7) < feedKey("2025-01-01T00:00:00.000Z", 8));
});

test("validPostId table", () => {
  assert.strictEqual(validPostId("1"), 1);
  assert.strictEqual(validPostId("999999999"), 999999999);
  for (const bad of ["0", "-1", "abc", "1.5", ""]) {
    assert.strictEqual(validPostId(bad), null, bad);
  }
});

test("validPostId overflow rejected", () => {
  assert.strictEqual(validPostId("9".repeat(30)), null);
});

test("trimBody table", () => {
  assert.deepStrictEqual(trimBody("  hi "), { ok: true, value: "hi" });
  assert.deepStrictEqual(trimBody("   "), { ok: false, error: "body is required" });
  assert.deepStrictEqual(trimBody(123), { ok: false, error: "body is required" });
  assert.deepStrictEqual(trimBody({}), { ok: false, error: "body is required" });
  assert.deepStrictEqual(trimBody("a".repeat(501)), { ok: false, error: "body must be at most 500 characters" });
  assert.deepStrictEqual(trimBody("b".repeat(500)), { ok: true, value: "b".repeat(500) });
});
