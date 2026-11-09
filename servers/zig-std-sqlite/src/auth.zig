const std = @import("std");

fn nowSec() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

pub const AuthResult = union(enum) {
    ok: struct {
        user_id: u64,
        username: []const u8,
    },
    err: []const u8,
};

fn b64decode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const D = std.base64.url_safe_no_pad.Decoder;
    const n = try D.calcSizeForSlice(s);
    const out = try alloc.alloc(u8, n);
    errdefer alloc.free(out);
    try D.decode(out, s);
    return out;
}

const token_err: []const u8 = "invalid or expired token";
const payload_err: []const u8 = "invalid token payload";

/// The returned username is owned by the caller (dupe'd into alloc);
/// the server passes its per-request arena, tests free it.
pub fn verifyJWT(alloc: std.mem.Allocator, token: []const u8, secret: []const u8, now_s: i64) !AuthResult {
    var parts = std.mem.splitScalar(u8, token, '.');
    const header_b64 = parts.next() orelse return .{ .err = token_err };
    const payload_b64 = parts.next() orelse return .{ .err = token_err };
    const sig_b64 = parts.next() orelse return .{ .err = token_err };
    if (parts.next() != null) return .{ .err = token_err };
    const header_raw = b64decode(alloc, header_b64) catch return .{ .err = token_err };
    defer alloc.free(header_raw);
    const Header = struct {
        alg: []const u8,
        typ: []const u8 = "",
    };
    const header = std.json.parseFromSlice(Header, alloc, header_raw, .{ .ignore_unknown_fields = true }) catch return .{ .err = token_err };
    defer header.deinit();
    if (!std.mem.eql(u8, header.value.alg, "HS256")) return .{ .err = token_err };
    const sig = b64decode(alloc, sig_b64) catch return .{ .err = token_err };
    defer alloc.free(sig);
    if (sig.len != 32) return .{ .err = token_err };
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, token[0 .. header_b64.len + 1 + payload_b64.len], secret);
    if (!std.crypto.timing_safe.eql([32]u8, mac, sig[0..32].*)) return .{ .err = token_err };
    const payload_raw = b64decode(alloc, payload_b64) catch return .{ .err = token_err };
    defer alloc.free(payload_raw);
    const Payload = struct {
        sub: std.json.Value = .null,
        username: std.json.Value = .null,
        exp: std.json.Value = .null,
    };
    const payload = std.json.parseFromSlice(Payload, alloc, payload_raw, .{ .ignore_unknown_fields = true }) catch return .{ .err = token_err };
    defer payload.deinit();
    const sub = switch (payload.value.sub) {
        .string => |s| s,
        else => return .{ .err = payload_err },
    };
    if (sub.len == 0) return .{ .err = payload_err };
    for (sub) |b| {
        if (b < '0' or b > '9') return .{ .err = payload_err };
    }
    const user_id = std.fmt.parseUnsigned(u64, sub, 10) catch return .{ .err = payload_err };
    if (user_id < 1) return .{ .err = payload_err };
    const username = switch (payload.value.username) {
        .string => |s| s,
        else => return .{ .err = payload_err },
    };
    const exp = switch (payload.value.exp) {
        .integer => |n| n,
        else => return .{ .err = token_err },
    };
    if (exp + 60 < now_s) return .{ .err = token_err };
    const owned = try alloc.dupe(u8, username);
    return .{ .ok = .{ .user_id = user_id, .username = owned } };
}

fn signForTest(alloc: std.mem.Allocator, header_b64: []const u8, payload: []const u8, secret: []const u8) ![]u8 {
    var msg: std.Io.Writer.Allocating = .init(alloc);
    defer msg.deinit();
    try msg.writer.writeAll(header_b64);
    try msg.writer.writeByte('.');
    try msg.writer.writeAll(payload);
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, msg.written(), secret);
    const Encoder = std.base64.url_safe_no_pad.Encoder;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(msg.written());
    try out.writer.writeByte('.');
    var enc_buf: [64]u8 = undefined;
    const enc = Encoder.encode(&enc_buf, &mac);
    try out.writer.writeAll(enc);
    return out.toOwnedSlice();
}

fn hsHeader() []const u8 {
    return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"; // {"alg":"HS256","typ":"JWT"}
}

fn b64url(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const Encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try alloc.alloc(u8, Encoder.calcSize(raw.len));
    _ = Encoder.encode(out, raw);
    return out;
}

test "jwt good token" {
    const alloc = std.testing.allocator;
    const secret = "twelve-dollar-challenge";
    const now = nowSec();
    const payload = try std.fmt.allocPrint(alloc, "{{\"sub\":\"1\",\"username\":\"alice\",\"iat\":{d},\"exp\":{d}}}", .{ now, now + 3600 });
    defer alloc.free(payload);
    const payload_b64 = try b64url(alloc, payload);
    defer alloc.free(payload_b64);
    const tok = try signForTest(alloc, hsHeader(), payload_b64, secret);
    defer alloc.free(tok);
    const r = try verifyJWT(alloc, tok, secret, now);
    try std.testing.expect(r == .ok);
    defer alloc.free(r.ok.username);
    try std.testing.expectEqual(@as(u64, 1), r.ok.user_id);
    try std.testing.expectEqualStrings("alice", r.ok.username);
}

test "jwt rejects bad signatures" {
    const alloc = std.testing.allocator;
    const secret = "twelve-dollar-challenge";
    const now = nowSec();
    const payload = try std.fmt.allocPrint(alloc, "{{\"sub\":\"1\",\"username\":\"alice\",\"iat\":{d},\"exp\":{d}}}", .{ now, now + 3600 });
    defer alloc.free(payload);
    const payload_b64 = try b64url(alloc, payload);
    defer alloc.free(payload_b64);
    // bad signature
    {
        const tok = try signForTest(alloc, hsHeader(), payload_b64, "wrong-secret");
        defer alloc.free(tok);
        const r = try verifyJWT(alloc, tok, secret, now);
        try std.testing.expect(r == .err);
        try std.testing.expectEqualStrings("invalid or expired token", r.err);
    }
    // expired 1h ago
    {
        const old = try std.fmt.allocPrint(alloc, "{{\"sub\":\"1\",\"username\":\"alice\",\"iat\":{d},\"exp\":{d}}}", .{ now - 7200, now - 3600 });
        defer alloc.free(old);
        const old_b64 = try b64url(alloc, old);
        defer alloc.free(old_b64);
        const tok = try signForTest(alloc, hsHeader(), old_b64, secret);
        defer alloc.free(tok);
        const r = try verifyJWT(alloc, tok, secret, now);
        try std.testing.expect(r == .err);
        try std.testing.expectEqualStrings("invalid or expired token", r.err);
    }
    // garbage
    {
        const r = try verifyJWT(alloc, "abc", secret, now);
        try std.testing.expect(r == .err);
        try std.testing.expectEqualStrings("invalid or expired token", r.err);
    }
    // alg=none (unsigned)
    {
        const none_h = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0";
        var tok_buf: std.Io.Writer.Allocating = .init(alloc);
        defer tok_buf.deinit();
        try tok_buf.writer.print("{s}.{s}.", .{ none_h, payload_b64 });
        const r = try verifyJWT(alloc, tok_buf.written(), secret, now);
        try std.testing.expect(r == .err);
        try std.testing.expectEqualStrings("invalid or expired token", r.err);
    }
}

test "jwt rejects bad payloads" {
    const alloc = std.testing.allocator;
    const secret = "twelve-dollar-challenge";
    const now = nowSec();
    // full payloads with exp (far-future so only the sub/username shape is judged)
    const full = [_][]const u8{
        "{\"sub\":\"abc\",\"username\":\"alice\",\"iat\":0,\"exp\":9999999999}",
        "{\"sub\":9,\"username\":\"alice\",\"iat\":0,\"exp\":9999999999}",
        "{\"sub\":\"1\",\"iat\":0,\"exp\":9999999999}",
        "{\"sub\":\"1\",\"username\":123,\"iat\":0,\"exp\":9999999999}",
    };
    for (full) |payload| {
        const payload_b64 = try b64url(alloc, payload);
        defer alloc.free(payload_b64);
        const tok = try signForTest(alloc, hsHeader(), payload_b64, secret);
        defer alloc.free(tok);
        const r = try verifyJWT(alloc, tok, secret, now);
        try std.testing.expect(r == .err);
        try std.testing.expectEqualStrings("invalid token payload", r.err);
    }
}

test "jwt leeway parity" {
    const alloc = std.testing.allocator;
    const secret = "twelve-dollar-challenge";
    const now = nowSec();
    const payload = try std.fmt.allocPrint(alloc, "{{\"sub\":\"1\",\"username\":\"alice\",\"iat\":{d},\"exp\":{d}}}", .{ now - 3600, now - 30 });
    defer alloc.free(payload);
    const payload_b64 = try b64url(alloc, payload);
    defer alloc.free(payload_b64);
    const tok = try signForTest(alloc, hsHeader(), payload_b64, secret);
    defer alloc.free(tok);
    const r = try verifyJWT(alloc, tok, secret, now);
    try std.testing.expect(r == .ok);
    defer alloc.free(r.ok.username);
}
