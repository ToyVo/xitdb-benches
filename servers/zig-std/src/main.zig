const std = @import("std");
const lib = @import("xitdb");
const validate = @import("validate.zig");
const auth = @import("auth.zig");
const store = @import("store.zig");

var g_store: store.Store = undefined;
var g_mutex: std.Io.Mutex = .init;
var g_alloc: std.mem.Allocator = undefined;

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1000000);
}

fn getHeader(head_buffer: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head_buffer, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        if (line.len == 0) return null;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
            return std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
        }
    }
    return null;
}

fn respond(req: *std.http.Server.Request, keep_open: bool, status: std.http.Status, body: []const u8) void {
    req.respond(body, .{
        .status = status,
        .keep_alive = keep_open,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    }) catch {};
}

fn errJson(req: *std.http.Server.Request, keep_open: bool, status: std.http.Status, msg: []const u8, arena: std.mem.Allocator) void {
    const body = std.fmt.allocPrint(arena, "{{\"error\":\"{s}\"}}", .{msg}) catch return;
    respond(req, keep_open, status, body);
}

fn handleOne(req: *std.http.Server.Request, arena: std.mem.Allocator) bool {
    const method = req.head.method;
    var target = req.head.target;
    if (std.mem.indexOfScalar(u8, target, '?')) |i| target = target[0..i];
    const auth_header = if (getHeader(req.head_buffer, "authorization")) |h|
        arena.dupe(u8, h) catch null
    else
        null;
    const target_copy = arena.dupe(u8, target) catch return false;
    // Frameless body-methods (POST with neither content-length nor chunked
    // framing) cannot be keep-alive: std's discardBody asserts on them. Answer
    // normally but close the connection.
    const framing_ok = req.head.transfer_encoding != .none or req.head.content_length != null;
    const keep_open = !(method.requestHasBody() and !framing_ok);

    // Only POST /posts consumes the body; every other route lets respond()
    // discard it. Reading without a known length would block forever, so
    // the read is gated on content_length (chunked posts are out of scope).
    var body: []const u8 = "";
    const want_body = method == .POST and std.mem.eql(u8, target_copy, "/posts");
    if (req.head.expect != null) {
        errJson(req, keep_open, .expectation_failed, "expectation failed", arena);
        return keep_open;
    } else if (want_body and (req.head.content_length orelse 0) > 0) {
        const reader = req.readerExpectNone(arena.alloc(u8, 65536) catch return keep_open);
        var acc: std.Io.Writer.Allocating = .init(arena);
        defer acc.deinit();
        var chunk: [8192]u8 = undefined;
        while (true) {
            const n = reader.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            acc.writer.writeAll(chunk[0..n]) catch break;
        }
        body = acc.toOwnedSlice() catch "";
    }

    if (method == .GET and std.mem.eql(u8, target_copy, "/health")) {
        const ok = g_store.health();
        const uptime: i64 = @divTrunc(nowMs() - g_store.boot_ms, 1000);
        if (!ok) {
            respond(req, keep_open, .service_unavailable, "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"read failed\"}");
            return keep_open;
        }
        const out = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":{d}}}", .{uptime}) catch return keep_open;
        respond(req, keep_open, .ok, out);
        return keep_open;
    }
    if (method == .GET and std.mem.eql(u8, target_copy, "/feed")) {
        const feed = g_store.getFeed() catch {
            errJson(req, keep_open, .internal_server_error, "internal server error", arena);
            return keep_open;
        };
        defer store.freePosts(g_alloc, feed);
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        out.writer.writeAll("{\"posts\":[") catch return keep_open;
        for (feed, 0..) |p, i| {
            if (i > 0) out.writer.writeByte(',') catch return keep_open;
            const js = store.postJson(arena, p) catch return keep_open;
            out.writer.writeAll(js) catch return keep_open;
        }
        out.writer.writeAll("]}") catch return keep_open;
        respond(req, keep_open, .ok, out.written());
        return keep_open;
    }
    if (method == .GET and std.mem.startsWith(u8, target_copy, "/posts/")) {
        const id_raw = target_copy["/posts/".len..];
        if (std.mem.indexOfScalar(u8, id_raw, '/') != null) {
            errJson(req, keep_open, .not_found, "not found", arena);
            return keep_open;
        }
        const id = validate.validPostId(id_raw) orelse {
            errJson(req, keep_open, .bad_request, "invalid post id", arena);
            return keep_open;
        };
        const found = g_store.getPost(id) catch {
            errJson(req, keep_open, .internal_server_error, "internal server error", arena);
            return keep_open;
        };
        if (found) |p| {
            defer store.freePost(g_alloc, p);
            const js = store.postJson(arena, p) catch return keep_open;
            const out = std.fmt.allocPrint(arena, "{{\"post\":{s}}}", .{js}) catch return keep_open;
            respond(req, keep_open, .ok, out);
        } else {
            errJson(req, keep_open, .not_found, "post not found", arena);
        }
        return keep_open;
    }
    if (method == .POST and std.mem.eql(u8, target_copy, "/posts")) {
        const authed = checkAuth(auth_header, arena) orelse {
            errJson(req, keep_open, .unauthorized, authFailReason(auth_header, arena), arena);
            return keep_open;
        };
        const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch {
            errJson(req, keep_open, .bad_request, "malformed JSON body", arena);
            return keep_open;
        };
        defer parsed.deinit();
        const body_val: []const u8 = switch (parsed.value) {
            .object => |o| blk: {
                const v = o.get("body") orelse {
                    errJson(req, keep_open, .bad_request, "body is required", arena);
                    return keep_open;
                };
                break :blk switch (v) {
                    .string => |s| s,
                    else => {
                        errJson(req, keep_open, .bad_request, "body is required", arena);
                        return keep_open;
                    },
                };
            },
            else => {
                errJson(req, keep_open, .bad_request, "body is required", arena);
                return keep_open;
            },
        };
        const trimmed = switch (validate.trimBody(body_val)) {
            .ok => |s| s,
            .err => |m| {
                errJson(req, keep_open, .bad_request, m, arena);
                return keep_open;
            },
        };
        const created = g_store.createPost(authed.username, trimmed) catch {
            errJson(req, keep_open, .internal_server_error, "internal server error", arena);
            return keep_open;
        };
        defer store.freePost(g_alloc, created);
        const js = store.postJson(arena, created) catch return keep_open;
        const out = std.fmt.allocPrint(arena, "{{\"post\":{s}}}", .{js}) catch return keep_open;
        respond(req, keep_open, .created, out);
        return keep_open;
    }
    if (method == .POST and std.mem.endsWith(u8, target_copy, "/like") and std.mem.startsWith(u8, target_copy, "/posts/")) {
        const authed = checkAuth(auth_header, arena) orelse {
            errJson(req, keep_open, .unauthorized, authFailReason(auth_header, arena), arena);
            return keep_open;
        };
        const id_raw = target_copy["/posts/".len .. target_copy.len - "/like".len];
        if (std.mem.indexOfScalar(u8, id_raw, '/') != null) {
            errJson(req, keep_open, .not_found, "not found", arena);
            return keep_open;
        }
        const id = validate.validPostId(id_raw) orelse {
            errJson(req, keep_open, .bad_request, "invalid post id", arena);
            return keep_open;
        };
        const outcome = g_store.likePost(id, authed.user_id) catch {
            errJson(req, keep_open, .internal_server_error, "internal server error", arena);
            return keep_open;
        };
        if (outcome) |o| {
            const status: std.http.Status = if (o.already) .ok else .created;
            const out = std.fmt.allocPrint(arena, "{{\"liked\":true,\"already_liked\":{},\"post_id\":{d}}}", .{ o.already, id }) catch return keep_open;
            respond(req, keep_open, status, out);
        } else {
            errJson(req, keep_open, .not_found, "post not found", arena);
        }
        return keep_open;
    }
    errJson(req, keep_open, .not_found, "not found", arena);
    return keep_open;
}

const Authed = struct { user_id: u64, username: []const u8 };

fn checkAuth(auth_header: ?[]const u8, arena: std.mem.Allocator) ?Authed {
    const token = bearerToken(auth_header) orelse return null;
    const r = auth.verifyJWT(arena, token, secretOf(), nowSec()) catch return null;
    if (r != .ok) return null;
    return .{ .user_id = r.ok.user_id, .username = r.ok.username };
}

fn bearerToken(auth_header: ?[]const u8) ?[]const u8 {
    const h = auth_header orelse return null;
    if (!std.mem.startsWith(u8, h, "Bearer ")) return null;
    return h["Bearer ".len..];
}

fn authFailReason(auth_header: ?[]const u8, arena: std.mem.Allocator) []const u8 {
    const token = bearerToken(auth_header) orelse return "missing bearer token";
    const r = auth.verifyJWT(arena, token, secretOf(), nowSec()) catch return "invalid or expired token";
    return switch (r) {
        .ok => "missing bearer token", // unreachable: checkAuth already failed
        .err => |m| m,
    };
}

var g_secret: []const u8 = "";

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}
fn secretOf() []const u8 {
    return g_secret;
}

fn nowSec() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

fn handleConn(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);
    var arena_state = std.heap.ArenaAllocator.init(g_alloc);
    defer arena_state.deinit();
    const conn_alloc = arena_state.allocator();
    const in_buf = conn_alloc.alloc(u8, 65536) catch return;
    const out_buf = conn_alloc.alloc(u8, 65536) catch return;
    var sreader = stream.reader(io, in_buf);
    var swriter = stream.writer(io, out_buf);
    var srv = std.http.Server.init(&sreader.interface, &swriter.interface);
    while (true) {
        var req = srv.receiveHead() catch break;
        const ka = req.head.keep_alive;
        var req_arena_state = std.heap.ArenaAllocator.init(g_alloc);
        g_mutex.lock(io) catch break;
        const keep = handleOne(&req, req_arena_state.allocator());
        g_mutex.unlock(io);
        req_arena_state.deinit();
        if (!ka or !keep) break;
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    g_alloc = gpa.allocator();
    var threaded = std.Io.Threaded.init(g_alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = getenv("XITDB_PATH") orelse "feed.xitdb";
    g_secret = getenv("JWT_SECRET") orelse "twelve-dollar-challenge";
    const host = getenv("HOST") orelse "127.0.0.1";
    const port = std.fmt.parseUnsigned(u16, getenv("PORT") orelse "3000", 10) catch 3000;

    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    g_store = try store.openStore(g_alloc, io, file, g_secret);

    var addr = try std.Io.net.IpAddress.parse(host, port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    std.log.info("serving {s} on http://{s}:{d}", .{ path, host, port });
    while (true) {
        const stream = try listener.accept(io);
        const t = try std.Thread.spawn(.{}, handleConn, .{ stream, io });
        t.detach();
    }
}
