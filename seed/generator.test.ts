import { test } from "node:test";
import assert from "node:assert/strict";
import { mulberry32, feedKey } from "./generate-xitdb.ts";

test("mulberry32(42) deterministic prefix", () => {
  const r = mulberry32(42);
  assert.strictEqual(r(), 0.6011037519201636);
  assert.strictEqual(r(), 0.44829055899754167);
  assert.strictEqual(r(), 0.8524657934904099);
});

test("feedKey format + ordering", () => {
  assert.strictEqual(
    feedKey("2025-01-01T00:00:00.000Z", 7),
    "2025-01-01T00:00:00.000Z\x000000000007",
  );
  assert.ok(
    feedKey("2025-01-01T00:00:00.000Z", 7) <
      feedKey("2025-01-01T00:00:00.000Z", 8),
  );
  assert.ok(
    feedKey("2025-01-01T00:00:00.000Z", 9) <
      feedKey("2025-01-02T00:00:00.000Z", 1),
  );
});
