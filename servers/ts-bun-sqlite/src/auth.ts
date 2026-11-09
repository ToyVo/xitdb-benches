import { jwtVerify } from "jose";

export type AuthResult =
  | { userId: number; username: string }
  | { error: string };

export async function verifyJWT(token: string, secret: string): Promise<AuthResult> {
  let payload: unknown;
  try {
    const verified = await jwtVerify(token, new TextEncoder().encode(secret), {
      algorithms: ["HS256"],
      clockTolerance: 60,
    });
    payload = verified.payload;
  } catch {
    return { error: "invalid or expired token" };
  }
  if (typeof payload !== "object" || payload === null) {
    return { error: "invalid token payload" };
  }
  const { sub, username } = payload as Record<string, unknown>;
  if (typeof sub !== "string" || !/^\d+$/.test(sub)) {
    return { error: "invalid token payload" };
  }
  const id = BigInt(sub);
  if (id < 1n || id > BigInt(Number.MAX_SAFE_INTEGER)) {
    return { error: "invalid token payload" };
  }
  if (typeof username !== "string") {
    return { error: "invalid token payload" };
  }
  return { userId: Number(id), username };
}
