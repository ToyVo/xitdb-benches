const std = @import("std");
const lib = @import("xitdb");
const validate = @import("validate.zig");

const DB = lib.Database(.file, u160);

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

pub const Store = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    db: DB,
    secret: []const u8,
    boot_ms: i64,

    pub fn deinit(self: *Store) void {
        self.file.close(self.io);
    }

    pub fn health(self: *Store) bool {
        _ = self.db.committedSize() catch return false;
        return true;
    }

    pub fn getPost(self: *Store, id: u64) !?Post {
        var id_buf: [32]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
        const root = try DB.HashMap(.read_write).init(self.db.rootCursor());
        const pc = try root.getCursor(validate.hashKey("posts")) orelse return null;
        const posts = try DB.HashMap(.read_only).init(pc);
        return readPost(self.alloc, posts, id_str);
    }

    pub fn getFeed(self: *Store) ![]Post {
        const root = try DB.HashMap(.read_write).init(self.db.rootCursor());
        const fc = try root.getCursor(validate.hashKey("feed")) orelse return try self.alloc.dupe(Post, &.{});
        const feed = try DB.SortedMap(.read_only).init(fc);
        const count = try feed.count();
        const start: u64 = if (count > 20) count - 20 else 0;
        const pc = try root.getCursor(validate.hashKey("posts")) orelse return try self.alloc.dupe(Post, &.{});
        const posts = try DB.HashMap(.read_only).init(pc);
        var out: std.ArrayList(Post) = .empty;
        var i: u64 = start;
        while (i < count) : (i += 1) {
            const kv = try feed.getIndexKeyValuePair(@as(i65, @intCast(i))) orelse continue;
            const raw = try kv.value_cursor.readBytesAlloc(self.alloc, null);
            defer freeConst(self.alloc, raw);
            if (try readPost(self.alloc, posts, raw)) |p| {
                try out.append(self.alloc, p);
            }
        }
        std.mem.reverse(Post, out.items);
        if (out.items.len == 0) return try self.alloc.dupe(Post, &.{});
        return out.toOwnedSlice(self.alloc);
    }

    pub fn createPost(self: *Store, username: []const u8, body: []const u8) !Post {
        var created: ?Post = null;
        try self.db.runContext(CreateCtx{
            .alloc = self.alloc,
            .username = username,
            .body = body,
            .out = &created,
        });
        return created orelse error.Corrupt;
    }

    pub const LikeOutcome = struct { already: bool };

pub fn likePost(self: *Store, id: u64, user_id: u64) !?LikeOutcome {
        var id_buf: [32]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
        var user_buf: [32]u8 = undefined;
        const user_str = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var outcome: ?LikeOutcome = null;
        const Ctx = struct {
            alloc: std.mem.Allocator,
            id_str: []const u8,
            user_str: []const u8,
            out: *?LikeOutcome,
            pub fn run(ctx: @This(), cursor: *DB.Cursor(.read_write)) !void {
                const root = try DB.HashMap(.read_write).init(cursor.*);
                const posts = try DB.HashMap(.read_write).init(try root.putCursor(validate.hashKey("posts")));
                if (try posts.getCursor(validate.hashKey(ctx.id_str)) == null) return;
                const likes = try DB.HashMap(.read_write).init(try root.putCursor(validate.hashKey("likes")));
                const set = try DB.HashSet(.read_write).init(try likes.putCursor(validate.hashKey(ctx.id_str)));
                if (try set.getCursor(validate.hashKey(ctx.user_str)) != null) {
                    ctx.out.* = .{ .already = true };
                    return;
                }
                try set.put(validate.hashKey(ctx.user_str), .{ .bytes = ctx.user_str });
                const pm = try DB.HashMap(.read_write).init(try posts.putCursor(validate.hashKey(ctx.id_str)));
                const lc_c = try pm.getCursor(validate.hashKey("like_count")) orelse return error.Corrupt;
                const cur = try lc_c.readUint();
                try pm.put(validate.hashKey("like_count"), .{ .uint = cur + 1 });
                ctx.out.* = .{ .already = false };
            }
        };
        try self.db.runContext(Ctx{
            .alloc = self.alloc,
            .id_str = id_str,
            .user_str = user_str,
            .out = &outcome,
        });
        return outcome orelse null;
    }
};

const CreateCtx = struct {
    alloc: std.mem.Allocator,
    username: []const u8,
    body: []const u8,
    out: *?Post,
    pub fn run(self: @This(), cursor: *DB.Cursor(.read_write)) !void {
        const root = try DB.HashMap(.read_write).init(cursor.*);
        const meta = try DB.HashMap(.read_write).init(try root.putCursor(validate.hashKey("meta")));
        var next: u64 = 1;
        if (try meta.getCursor(validate.hashKey("next_post_id"))) |c| {
            next = try c.readUint();
        }
        const created_at = try validate.formatMillis(self.alloc, nowMs());
        errdefer freeConst(self.alloc, created_at);
        const posts = try DB.HashMap(.read_write).init(try root.putCursor(validate.hashKey("posts")));
        var id_buf: [32]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{next});
        const pm = try DB.HashMap(.read_write).init(try posts.putCursor(validate.hashKey(id_str)));
        try pm.put(validate.hashKey("id"), .{ .uint = next });
        try pm.put(validate.hashKey("body"), .{ .bytes = self.body });
        try pm.put(validate.hashKey("created_at"), .{ .bytes = created_at });
        try pm.put(validate.hashKey("author"), .{ .bytes = self.username });
        try pm.put(validate.hashKey("like_count"), .{ .uint = 0 });
        const feed = try DB.SortedMap(.read_write).init(try root.putCursor(validate.hashKey("feed")));
        const fk = try validate.feedKey(self.alloc, created_at, next);
        defer freeConst(self.alloc, fk);
        try feed.put(fk, .{ .bytes = id_str });
        const likes = try DB.HashMap(.read_write).init(try root.putCursor(validate.hashKey("likes")));
        _ = try DB.HashSet(.read_write).init(try likes.putCursor(validate.hashKey(id_str)));
        try meta.put(validate.hashKey("next_post_id"), .{ .uint = next + 1 });
        self.out.* = Post{
            .id = next,
            .body = try self.alloc.dupe(u8, self.body),
            .created_at = created_at,
            .author = try self.alloc.dupe(u8, self.username),
            .like_count = 0,
        };
    }
};

fn readPost(alloc: std.mem.Allocator, posts: anytype, id_str: []const u8) !?Post {
    const pc = try posts.getCursor(validate.hashKey(id_str)) orelse return null;
    const pm = try DB.HashMap(.read_only).init(pc);
    const id_c = try pm.getCursor(validate.hashKey("id")) orelse return error.Corrupt;
    const num = try id_c.readUint();
    const body = try readText(alloc, pm, "body");
    errdefer freeConst(alloc, body);
    const created_at = try readText(alloc, pm, "created_at");
    errdefer freeConst(alloc, created_at);
    const author = try readText(alloc, pm, "author");
    errdefer freeConst(alloc, author);
    const lc_c = try pm.getCursor(validate.hashKey("like_count")) orelse return error.Corrupt;
    const lc = try lc_c.readUint();
    return Post{ .id = num, .body = body, .created_at = created_at, .author = author, .like_count = lc };
}

fn readText(alloc: std.mem.Allocator, pm: DB.HashMap(.read_only), key: []const u8) ![]const u8 {
    const c = try pm.getCursor(validate.hashKey(key)) orelse return error.Corrupt;
    return c.readBytesAlloc(alloc, null);
}

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1000000);
}

pub fn openStore(alloc: std.mem.Allocator, io: std.Io, file: std.Io.File, secret: []const u8) !Store {
    const db = try DB.init(io, .{
        .file = file,
        .hash_id = lib.HashId.fromBytes("sha1"),
        .fsync = true,
    });
    return Store{
        .alloc = alloc,
        .io = io,
        .file = file,
        .db = db,
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

fn openTestStore() !struct { store: Store, tmp: std.testing.TmpDir } {
    var tmp = std.testing.tmpDir(.{});
    const file = try tmp.dir.createFile(std.testing.io, "t.db", .{ .read = true });
    const store = try openStore(std.testing.allocator, std.testing.io, file, "test-secret");
    return .{ .store = store, .tmp = tmp };
}

test "store round trip" {
    var t = try openTestStore();
    defer t.tmp.cleanup();
    var st = t.store;
    defer st.deinit();
    const p = try st.createPost("alice", "hi");
    try std.testing.expectEqual(@as(u64, 1), p.id);
    try std.testing.expectEqualStrings("hi", p.body);
    try std.testing.expectEqualStrings("alice", p.author);
    try std.testing.expectEqual(@as(u64, 0), p.like_count);
    defer freePost(std.testing.allocator, p);
    try std.testing.expectEqual(@as(usize, 24), p.created_at.len);
    try std.testing.expect(p.created_at[23] == 'Z');
    const got = (try st.getPost(1)) orelse return error.TestExpectedEqual;
    defer freePost(std.testing.allocator, got);
    try std.testing.expectEqual(p.id, got.id);
    try std.testing.expectEqualStrings(p.body, got.body);
    try std.testing.expectEqualStrings(p.created_at, got.created_at);
    try std.testing.expect(st.getPost(999) catch null == null);
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
    var t = try openTestStore();
    defer t.tmp.cleanup();
    var st = t.store;
    defer st.deinit();
    {
        const c = try st.createPost("alice", "x");
        defer freePost(std.testing.allocator, c);
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
    try std.testing.expect(try st.likePost(999, 7) == null);
}

test "store missing keys" {
    var t = try openTestStore();
    defer t.tmp.cleanup();
    var st = t.store;
    defer st.deinit();
    try std.testing.expect(try st.getPost(12345) == null);
    try std.testing.expect(try st.likePost(12345, 9) == null);
    const feed = try st.getFeed();
    try std.testing.expectEqual(@as(usize, 0), feed.len);
    try std.testing.expect(st.health());
}

test "txn rule" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "r.db", .{ .read = true });
    var db = try DB.init(std.testing.io, .{ .file = file });
    const root = try DB.HashMap(.read_write).init(db.rootCursor());
    // Record the behavior: Rust throws ExpectedTxStart here, Go allows.
    // Either way the planned shape (reads getCursor, writes runContext) stands.
    if (root.putCursor(validate.hashKey("txn-probe"))) |_| {
        std.log.warn("putCursor outside runContext allowed (Go-like)", .{});
    } else |e| {
        std.log.warn("putCursor outside runContext -> {s} (Rust-like)", .{@errorName(e)});
    }
    _ = try root.getCursor(validate.hashKey("posts"));
}
