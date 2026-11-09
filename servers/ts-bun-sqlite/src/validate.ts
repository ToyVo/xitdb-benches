export function feedKey(createdAt: string, id: number): string {
  return `${createdAt}\x00${String(id).padStart(10, "0")}`;
}

export function validPostId(s: string): number | null {
  if (!/^\d+$/.test(s)) return null;
  const id = BigInt(s);
  if (id < 1n || id > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return Number(id);
}

export function trimBody(body: unknown): { ok: true; value: string } | { ok: false; error: string } {
  if (typeof body !== "string") return { ok: false, error: "body is required" };
  const trimmed = body.trim();
  if (trimmed === "") return { ok: false, error: "body is required" };
  if (trimmed.length > 500) return { ok: false, error: "body must be at most 500 characters" };
  return { ok: true, value: trimmed };
}
