const std = @import("std");

// Direct FFI: Zig 0.17 has no @cImport, so declare what we use.
// (sqlite3.c is compiled into the binary by build.zig.)
const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};
const sqlite3_destructor_type = ?*const fn (?*anyopaque) callconv(.c) void;
extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern fn sqlite3_close(db: ?*sqlite3) c_int;
extern fn sqlite3_prepare_v2(db: ?*sqlite3, zSql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*[*:0]const u8) c_int;
extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, val: i64) c_int;
extern fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, val: [*]const u8, n: c_int, destr: sqlite3_destructor_type) c_int;
extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, iCol: c_int) i64;
extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_last_insert_rowid(db: ?*sqlite3) i64;
extern fn sqlite3_changes(db: ?*sqlite3) c_int;
extern fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) c_int;
const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;

// SQLITE_STATIC (null destructor): SQLite must not copy or free the bytes.
// Sound here because every bound slice outlives its synchronous step()
// call (request-scoped buffers and literals only). Avoids the -1 sentinel,
// which Zig cannot spell (fn-pointer alignment is fiction to the compiler).
const SQLITE_STATIC: sqlite3_destructor_type = null;

pub const Post = struct {
    id: u64,
    body: []const u8,
    created_at: []const u8,
    author: []const u8,
    like_count: u64,
};

pub fn freeConst(alloc: std.mem.Allocator, s: []const u8) void {
    alloc.free(@constCast(s));
}

const FEED_SQL =
    "SELECT p.id,p.body,p.created_at,u.username,(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id)" ++
    " FROM posts p JOIN users u ON u.id=p.user_id ORDER BY p.created_at DESC,p.id DESC LIMIT 20";
const POST_SQL =
    "SELECT p.id,p.body,p.created_at,u.username,(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id)" ++
    " FROM posts p JOIN users u ON u.id=p.user_id WHERE p.id=?1";

pub const Store = struct {
    alloc: std.mem.Allocator,
    db: *sqlite3,
    secret: []const u8,
    boot_ms: i64,

    pub fn deinit(self: *Store) void {
        _ = sqlite3_close(self.db);
    }

    pub fn health(self: *Store) bool {
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, "SELECT COUNT(*) FROM users", -1, &stmt, null) != SQLITE_OK) return false;
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return false;
        return true;
    }

    fn readRow(alloc: std.mem.Allocator, stmt: ?*sqlite3_stmt) !Post {
        const id: u64 = @intCast(sqlite3_column_int64(stmt, 0));
        const lc: u64 = @intCast(sqlite3_column_int64(stmt, 4));
        return Post{
            .id = id,
            .body = try alloc.dupe(u8, std.mem.span(sqlite3_column_text(stmt, 1) orelse return error.Corrupt)),
            .created_at = try alloc.dupe(u8, std.mem.span(sqlite3_column_text(stmt, 2) orelse return error.Corrupt)),
            .author = try alloc.dupe(u8, std.mem.span(sqlite3_column_text(stmt, 3) orelse return error.Corrupt)),
            .like_count = lc,
        };
    }

    fn prepare(self: *Store, sql: [*:0]const u8) !?*sqlite3_stmt {
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != SQLITE_OK) return error.Corrupt;
        return stmt;
    }

    pub fn getPost(self: *Store, id: u64) !?Post {
        const stmt = try self.prepare(POST_SQL);
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, @intCast(id));
        if (sqlite3_step(stmt) != SQLITE_ROW) return null;
        return try readRow(self.alloc, stmt);
    }

    pub fn getFeed(self: *Store) ![]Post {
        const stmt = try self.prepare(FEED_SQL);
        defer _ = sqlite3_finalize(stmt);
        var out: std.ArrayList(Post) = .empty;
        errdefer {
            for (out.items) |p| freePost(self.alloc, p);
            out.deinit(self.alloc);
        }
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            try out.append(self.alloc, try readRow(self.alloc, stmt));
        }
        if (out.items.len == 0) {
            out.deinit(self.alloc);
            return try self.alloc.dupe(Post, &.{});
        }
        return out.toOwnedSlice(self.alloc);
    }

    pub fn createPost(self: *Store, username: []const u8, body: []const u8) !Post {
        const ustmt = try self.prepare("SELECT id FROM users WHERE username=?1");
        defer _ = sqlite3_finalize(ustmt);
        _ = sqlite3_bind_text(ustmt, 1, username.ptr, @intCast(username.len), SQLITE_STATIC);
        if (sqlite3_step(ustmt) != SQLITE_ROW) return error.Corrupt;
        const user_id = sqlite3_column_int64(ustmt, 0);
        const created_at = try nowMsZ(self.alloc);
        errdefer self.alloc.free(created_at);
        const istmt = try self.prepare("INSERT INTO posts(user_id,body,created_at) VALUES(?1,?2,?3)");
        defer _ = sqlite3_finalize(istmt);
        _ = sqlite3_bind_int64(istmt, 1, user_id);
        _ = sqlite3_bind_text(istmt, 2, body.ptr, @intCast(body.len), SQLITE_STATIC);
        _ = sqlite3_bind_text(istmt, 3, created_at.ptr, @intCast(created_at.len), SQLITE_STATIC);
        if (sqlite3_step(istmt) != SQLITE_DONE) return error.Corrupt;
        const id: u64 = @intCast(sqlite3_last_insert_rowid(self.db));
        return Post{
            .id = id,
            .body = try self.alloc.dupe(u8, body),
            .created_at = created_at,
            .author = try self.alloc.dupe(u8, username),
            .like_count = 0,
        };
    }

    pub const LikeOutcome = struct { already: bool };

    pub fn likePost(self: *Store, id: u64, user_id: u64) !?LikeOutcome {
        const estmt = try self.prepare("SELECT 1 FROM posts WHERE id=?1");
        defer _ = sqlite3_finalize(estmt);
        _ = sqlite3_bind_int64(estmt, 1, @intCast(id));
        if (sqlite3_step(estmt) != SQLITE_ROW) return null;
        const istmt = try self.prepare("INSERT OR IGNORE INTO likes(user_id,post_id,created_at) VALUES(?1,?2,?3)");
        defer _ = sqlite3_finalize(istmt);
        const created_at = try nowMsZ(self.alloc);
        defer self.alloc.free(created_at);
        _ = sqlite3_bind_int64(istmt, 1, @intCast(user_id));
        _ = sqlite3_bind_int64(istmt, 2, @intCast(id));
        _ = sqlite3_bind_text(istmt, 3, created_at.ptr, @intCast(created_at.len), SQLITE_STATIC);
        if (sqlite3_step(istmt) != SQLITE_DONE) return error.Corrupt;
        return .{ .already = sqlite3_changes(self.db) == 0 };
    }
};

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1000000);
}

fn nowMsZ(alloc: std.mem.Allocator) ![]u8 {
    // Millisecond wire format, same shape as the xitdb twin's clock.
    const ms: u64 = @intCast(nowMs());
    const secs = ms / 1000;
    const millis: u64 = ms % 1000;
    const days = @divFloor(secs, 86400);
    // civil-from-days (Howard Hinnant).
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y: u64 = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: u64 = @divFloor(5 * doy + 2, 153);
    const d: u64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: u64 = if (mp < 10) mp + 3 else mp - 9;
    y += if (m <= 2) 1 else 0;
    const sod = @mod(secs, 86400);
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        y,
        m,
        d,
        @divFloor(sod, 3600),
        @divFloor(@mod(sod, 3600), 60),
        @mod(sod, 60),
        millis,
    });
}

pub fn openStore(alloc: std.mem.Allocator, path: []const u8, secret: []const u8) !Store {
    const zbuf = try alloc.alloc(u8, path.len + 1);
    defer alloc.free(zbuf);
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const zpath: [*:0]const u8 = zbuf[0..path.len :0];
    var db: ?*sqlite3 = null;
    if (sqlite3_open(zpath, &db) != SQLITE_OK) return error.Corrupt;
    errdefer _ = sqlite3_close(db);
    _ = sqlite3_busy_timeout(db, 5000);
    return Store{
        .alloc = alloc,
        .db = db.?,
        .secret = secret,
        .boot_ms = nowMs(),
    };
}

pub fn postJson(alloc: std.mem.Allocator, p: Post) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{{\"id\":{d},\"body\":", .{p.id});
    try std.json.Stringify.value(p.body, .{}, w);
    try w.print(",\"created_at\":", .{});
    try std.json.Stringify.value(p.created_at, .{}, w);
    try w.print(",\"author\":", .{});
    try std.json.Stringify.value(p.author, .{}, w);
    try w.print(",\"like_count\":{d}}}", .{p.like_count});
    return out.toOwnedSlice();
}

pub fn freePost(alloc: std.mem.Allocator, p: Post) void {
    freeConst(alloc, p.body);
    freeConst(alloc, p.created_at);
    freeConst(alloc, p.author);
}

pub fn freePosts(alloc: std.mem.Allocator, feed: []Post) void {
    for (feed) |p| freePost(alloc, p);
    alloc.free(feed);
}

fn openTestStore() !Store {
    var st = try openStore(std.testing.allocator, ":memory:", "test-secret");
    errdefer st.deinit();
    const schema = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../../seed/schema.sql", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(schema);
    var stmt: ?*sqlite3_stmt = null;
    // Apply schema statement-by-statement (sqlite3_exec unavailable without extra wiring; prepare/step covers it).
    var it = std.mem.splitScalar(u8, schema, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        const zbuf = try std.testing.allocator.alloc(u8, trimmed.len + 1);
        defer std.testing.allocator.free(zbuf);
        @memcpy(zbuf[0..trimmed.len], trimmed);
        zbuf[trimmed.len] = 0;
        const z: [*:0]const u8 = zbuf[0..trimmed.len :0];
        if (sqlite3_prepare_v2(st.db, z, -1, &stmt, null) != SQLITE_OK) return error.Corrupt;
        const rc = sqlite3_step(stmt);
        _ = sqlite3_finalize(stmt);
        stmt = null;
        if (rc != SQLITE_DONE and rc != SQLITE_ROW) return error.Corrupt;
    }
    const useed = try st.prepare("INSERT INTO users(id,username,created_at) VALUES(7,'alice','2025-01-01T00:00:00.000Z')");
    defer _ = sqlite3_finalize(useed);
    if (sqlite3_step(useed) != SQLITE_DONE) return error.Corrupt;
    return st;
}

test "store round trip" {
    var st = try openTestStore();
    defer st.deinit();
    const p = try st.createPost("alice", "hi");
    defer freePost(std.testing.allocator, p);
    try std.testing.expectEqual(@as(u64, 1), p.id);
    try std.testing.expectEqualStrings("hi", p.body);
    try std.testing.expectEqualStrings("alice", p.author);
    try std.testing.expectEqual(@as(u64, 0), p.like_count);
    try std.testing.expectEqual(@as(usize, 24), p.created_at.len);
    try std.testing.expect(p.created_at[23] == 'Z');
    const got = (try st.getPost(1)) orelse return error.TestExpectedEqual;
    defer freePost(std.testing.allocator, got);
    try std.testing.expectEqual(p.id, got.id);
    try std.testing.expectEqualStrings(p.body, got.body);
    try std.testing.expectEqualStrings(p.created_at, got.created_at);
    try std.testing.expect((try st.getPost(999)) == null);
    {
        const c2 = try st.createPost("alice", "second");
        defer freePost(std.testing.allocator, c2);
    }
    const feed = try st.getFeed();
    defer freePosts(std.testing.allocator, feed);
    try std.testing.expectEqual(@as(usize, 2), feed.len);
    try std.testing.expectEqual(@as(u64, 2), feed[0].id);
    try std.testing.expectEqual(@as(u64, 1), feed[1].id);
}

test "store like idempotent" {
    var st = try openTestStore();
    defer st.deinit();
    {
        const cx = try st.createPost("alice", "x");
        defer freePost(std.testing.allocator, cx);
    }
    {
        const r = (try st.likePost(1, 7)) orelse return error.TestExpectedEqual;
        try std.testing.expect(!r.already);
    }
    {
        const r = (try st.likePost(1, 7)) orelse return error.TestExpectedEqual;
        try std.testing.expect(r.already);
    }
    const got = (try st.getPost(1)) orelse return error.TestExpectedEqual;
    defer freePost(std.testing.allocator, got);
    try std.testing.expectEqual(@as(u64, 1), got.like_count);
    try std.testing.expect((try st.likePost(999, 7)) == null);
}

test "store missing keys" {
    var st = try openTestStore();
    defer st.deinit();
    try std.testing.expect((try st.getPost(12345)) == null);
    try std.testing.expect((try st.likePost(12345, 9)) == null);
    const feed = try st.getFeed();
    defer freePosts(std.testing.allocator, feed);
    try std.testing.expectEqual(@as(usize, 0), feed.len);
    try std.testing.expect(st.health());
}

test "like primary key" {
    // PRIMARY KEY (user_id, post_id) is what makes repeat likes a no-op
    // at the engine level; pin it so schema drift fails loudly.
    var st = try openTestStore();
    defer st.deinit();
    {
        const cx = try st.createPost("alice", "x");
        defer freePost(std.testing.allocator, cx);
    }
    const stmt = try st.prepare("INSERT INTO likes(user_id,post_id,created_at) VALUES(7,1,'2025-01-01T00:00:00.000Z')");
    defer _ = sqlite3_finalize(stmt);
    try std.testing.expectEqual(SQLITE_DONE, sqlite3_step(stmt));
    const stmt2 = try st.prepare("INSERT INTO likes(user_id,post_id,created_at) VALUES(7,1,'2025-01-01T00:00:00.000Z')");
    defer _ = sqlite3_finalize(stmt2);
    try std.testing.expect(sqlite3_step(stmt2) != SQLITE_DONE);
}
