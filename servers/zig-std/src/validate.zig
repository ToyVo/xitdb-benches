const std = @import("std");

pub fn hashKey(s: []const u8) u160 {
    var hash: [@bitSizeOf(u160) / 8]u8 = undefined;
    std.crypto.hash.Sha1.hash(s, &hash, .{});
    return std.mem.readInt(u160, &hash, .big);
}

pub fn feedKey(alloc: std.mem.Allocator, createdAt: []const u8, id: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\x00{d:0>10}", .{ createdAt, id });
}

pub fn validPostId(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    for (s) |b| {
        if (b < '0' or b > '9') return null;
    }
    const n = std.fmt.parseUnsigned(u64, s, 10) catch return null;
    if (n < 1) return null;
    return n;
}

pub const TrimResult = union(enum) {
    ok: []const u8,
    err: [:0]const u8,
};

pub fn trimBody(s: []const u8) TrimResult {
    const trimmed = std.mem.trim(u8, s, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .err = "body is required" };
    const n = std.unicode.utf8CountCodepoints(trimmed) catch trimmed.len;
    if (n > 500) return .{ .err = "body must be at most 500 characters" };
    return .{ .ok = trimmed };
}

pub fn formatMillis(alloc: std.mem.Allocator, ms: i64) ![]u8 {
    const days = @divFloor(ms, 86400000);
    const rem_ms: u64 = @intCast(@mod(ms, 86400000));
    const z: i64 = days + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    var y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u64 = doy - (153 * mp + 2) / 5 + 1;
    const month: u64 = if (mp < 10) mp + 3 else mp - 9;
    if (month <= 2) y += 1;
    const hour = rem_ms / 3600000;
    const min = (rem_ms % 3600000) / 60000;
    const sec = (rem_ms % 60000) / 1000;
    const milli = rem_ms % 1000;
    // Domain is ms >= 0 (seed + wall-clock); cast is exact there.
    const yu: u64 = @intCast(y);
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ yu, month, d, hour, min, sec, milli });
}

test "feedKey" {
    const alloc = std.testing.allocator;
    const k = try feedKey(alloc, "2025-01-01T00:00:00.000Z", 7);
    defer alloc.free(k);
    try std.testing.expectEqualStrings("2025-01-01T00:00:00.000Z\x000000000007", k);
    const k2 = try feedKey(alloc, "2025-01-01T00:00:00.000Z", 8);
    defer alloc.free(k2);
    try std.testing.expect(std.mem.order(u8, k, k2) == .lt);
}

test "post ids" {
    try std.testing.expectEqual(@as(?u64, 1), validPostId("1"));
    try std.testing.expectEqual(@as(?u64, 999999999), validPostId("999999999"));
    try std.testing.expectEqual(@as(?u64, 18446744073709551615), validPostId("18446744073709551615"));
    for ([_][]const u8{ "0", "-1", "abc", "1.5", "" }) |bad| {
        try std.testing.expectEqual(@as(?u64, null), validPostId(bad));
    }
}

test "trimBody" {
    const alloc = std.testing.allocator;
    {
        const r = trimBody("  hi ");
        try std.testing.expect(r == .ok);
        try std.testing.expectEqualStrings("hi", r.ok);
    }
    {
        const r = trimBody("   ");
        try std.testing.expect(r == .err);
        try std.testing.expectEqualStrings("body is required", r.err);
    }
    {
        const a501 = try alloc.alloc(u8, 501);
        defer alloc.free(a501);
        @memset(a501, 'a');
        const r = trimBody(a501);
        try std.testing.expect(r == .err);
        try std.testing.expectEqualStrings("body must be at most 500 characters", r.err);
    }
    {
        const b500 = try alloc.alloc(u8, 500);
        defer alloc.free(b500);
        @memset(b500, 'b');
        const r = trimBody(b500);
        try std.testing.expect(r == .ok);
    }
    {
        // 'é' is 2 bytes / 1 codepoint: 500 codepoints must pass (rune semantics)
        var buf: [1000]u8 = undefined;
        for (0..500) |i| {
            buf[2 * i] = 0xc3;
            buf[2 * i + 1] = 0xa9;
        }
        const r = trimBody(&buf);
        try std.testing.expect(r == .ok);
    }
}

test "formatMillis" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { ms: i64, want: []const u8 }{
        .{ .ms = 0, .want = "1970-01-01T00:00:00.000Z" },
        .{ .ms = 1704067200000, .want = "2024-01-01T00:00:00.000Z" },
        .{ .ms = 1709251200000, .want = "2024-03-01T00:00:00.000Z" },
        .{ .ms = 1735689634152, .want = "2025-01-01T00:00:34.152Z" },
    };
    for (cases) |c| {
        const got = try formatMillis(alloc, c.ms);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "hashKey matches sha1 test vector" {
    // echo -n "abc" | sha1sum = a9993e364706816aba3e25717850c26c9cd0d89d
    try std.testing.expectEqual(@as(u160, 0xa9993e364706816aba3e25717850c26c9cd0d89d), hashKey("abc"));
}
