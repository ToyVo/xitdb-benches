package main

import xitdb "../vendor/xitdb"
import "core:mem"
import "core:strings"
import "core:time"

Post :: struct {
	id:         u64,
	body:       string,
	created_at: string,
	author:     string,
	like_count: u64,
}

Store :: struct {
	alloc:  mem.Allocator,
	core:   xitdb.Core,
	db:     xitdb.Database,
	secret: string,
	boot_s: i64,
}

// The Store is heap-allocated: Database keeps a ^Core pointer, so the
// Core must never move after init.
open_store :: proc(alloc: mem.Allocator, path: string, secret: string) -> (^Store, bool) {
	s := new(Store, alloc)
	s.alloc = alloc
	s.secret = secret
	core, err := xitdb.core_buffered_file_open(path, 2 * 1024 * 1024)
	if err != nil {
		free(s, alloc)
		return nil, false
	}
	s.core = core
	db, derr := xitdb.database_init(&s.core, xitdb.sha1_hasher())
	if derr != nil {
		xitdb.core_destroy(&s.core, close_file = true)
		free(s, alloc)
		return nil, false
	}
	s.db = db
	s.boot_s = now_ms()
	return s, true
}

store_deinit :: proc(s: ^Store) {
	alloc := s.alloc
	xitdb.core_destroy(&s.core, close_file = true)
	free(s, alloc)
}

store_health :: proc(s: ^Store) -> bool {
	_, err := xitdb.database_committed_size(&s.db)
	return err == nil
}

get_text :: proc(m: xitdb.Read_Hash_Map, key: string, allocator := context.allocator) -> (string, bool) {
	c, err := xitdb.hash_map_get_cursor(m, key)
	if err != nil || c == nil {
		return "", false
	}
	raw, rerr := xitdb.cursor_read_bytes(c.?, 8 * 1024 * 1024, allocator)
	if rerr != nil {
		return "", false
	}
	return string(raw), true
}

read_post :: proc(m: xitdb.Read_Hash_Map, id: string, allocator := context.allocator) -> (Post, bool) {
	pc, err := xitdb.hash_map_get_cursor(m, id)
	if err != nil || pc == nil {
		return {}, false
	}
	pm, perr := xitdb.read_hash_map_init(pc.?)
	if perr != nil {
		return {}, false
	}
	idc, _ := xitdb.hash_map_get_cursor(pm, "id")
	if idc == nil {
		return {}, false
	}
	num, nerr := xitdb.cursor_read_uint(idc.?)
	if nerr != nil {
		return {}, false
	}
	body, ok1 := get_text(pm, "body", allocator)
	if !ok1 {
		return {}, false
	}
	created, ok2 := get_text(pm, "created_at", allocator)
	if !ok2 {
		delete(body, allocator)
		return {}, false
	}
	author, ok3 := get_text(pm, "author", allocator)
	if !ok3 {
		delete(body, allocator)
		delete(created, allocator)
		return {}, false
	}
	lcc, _ := xitdb.hash_map_get_cursor(pm, "like_count")
	if lcc == nil {
		delete(body, allocator)
		delete(created, allocator)
		delete(author, allocator)
		return {}, false
	}
	lc, lerr := xitdb.cursor_read_uint(lcc.?)
	if lerr != nil {
		delete(body, allocator)
		delete(created, allocator)
		delete(author, allocator)
		return {}, false
	}
	return Post{id = num, body = body, created_at = created, author = author, like_count = lc}, true
}

// allocator backs the returned Post strings (request-scoped: the caller
// serializes before it is freed). Defaults to the ambient context so
// handle_one's arena flows through untouched.
store_get_post :: proc(s: ^Store, id: u64, allocator := context.allocator) -> (Post, bool) {
	id_str, idok := sprint_u64(s.alloc, id)
	if !idok {
		return {}, false
	}
	defer delete(id_str, s.alloc)
	root, err := xitdb.read_hash_map_init(xitdb.database_root_cursor(&s.db))
	if err != nil {
		return {}, false
	}
	pc, perr := xitdb.hash_map_get_cursor(root, "posts")
	if perr != nil || pc == nil {
		return {}, false
	}
	posts, qerr := xitdb.read_hash_map_init(pc.?)
	if qerr != nil {
		return {}, false
	}
	return read_post(posts, id_str, allocator)
}

store_get_feed :: proc(s: ^Store, allocator := context.allocator) -> ([]Post, bool) {
	root, err := xitdb.read_hash_map_init(xitdb.database_root_cursor(&s.db))
	if err != nil {
		return nil, false
	}
	fc, ferr := xitdb.hash_map_get_cursor(root, "feed")
	if ferr != nil || fc == nil {
		empty := make([]Post, 0, allocator)
		return empty, true
	}
	feed, _ := xitdb.read_sorted_map_init(fc.?)
	count, cerr := xitdb.sorted_map_count(feed)
	if cerr != nil {
		return nil, false
	}
	start: i64 = 0
	if count > 20 {
		start = count - 20
	}
	pc, _ := xitdb.hash_map_get_cursor(root, "posts")
	if pc == nil {
		empty := make([]Post, 0, allocator)
		return empty, true
	}
	posts, _ := xitdb.read_hash_map_init(pc.?)
	out := make([dynamic]Post, allocator)
	i := start
	for i < count {
		kv, kerr := xitdb.sorted_map_get_index_kv_pair(feed, i)
		if kerr != nil || kv == nil {
			i += 1
			continue
		}
		raw, rerr := xitdb.cursor_read_bytes(kv.?.value_cursor, 8 * 1024 * 1024, allocator)
		if rerr != nil {
			i += 1
			continue
		}
		defer delete(raw, allocator)
		if p, ok := read_post(posts, string(raw), allocator); ok {
			append(&out, p)
		}
		i += 1
	}
	// newest first
	n := len(out)
	for k in 0 ..< n / 2 {
		out[k], out[n - 1 - k] = out[n - 1 - k], out[k]
	}
	return out[:], true
}

Create_Ctx :: struct {
	alloc:    mem.Allocator,
	username: string,
	body:     string,
	out:      ^Post,
	have_out: ^bool,
}

create_ctx_run :: proc(cursor: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := cast(^Create_Ctx)user_data
	root := xitdb.write_hash_map_init(cursor^) or_return
	meta_cur := xitdb.hash_map_put_cursor(&root, "meta") or_return
	meta := xitdb.write_hash_map_init(meta_cur) or_return
	next: u64 = 1
	{
		nc, ncerr := xitdb.hash_map_get_cursor(meta, "next_post_id")
		if ncerr != nil {
			return ncerr
		}
		if nc != nil {
			next = xitdb.cursor_read_uint(nc.?) or_return
		}
	}
	ts_buf: [32]u8
	created_at, aerr0 := strings.clone(format_millis(now_ms(), ts_buf[:]), ctx.alloc)
	if aerr0 != nil {
		return .Write_Failed
	}
	posts_cur := xitdb.hash_map_put_cursor(&root, "posts") or_return
	posts := xitdb.write_hash_map_init(posts_cur) or_return
	id_str, idok := sprint_u64(ctx.alloc, next)
	if !idok {
		return .Write_Failed
	}
	defer delete(id_str, ctx.alloc)
	pm_cur := xitdb.hash_map_put_cursor(&posts, id_str) or_return
	pm := xitdb.write_hash_map_init(pm_cur) or_return
	xitdb.hash_map_put(&pm, "id", next) or_return
	xitdb.hash_map_put(&pm, "body", ctx.body) or_return
	xitdb.hash_map_put(&pm, "created_at", created_at) or_return
	xitdb.hash_map_put(&pm, "author", ctx.username) or_return
	xitdb.hash_map_put(&pm, "like_count", u64(0)) or_return
	feed_cur := xitdb.hash_map_put_cursor(&root, "feed") or_return
	feed := xitdb.write_sorted_map_init(feed_cur) or_return
	fk := feed_key(created_at, next, ctx.alloc)
	xitdb.sorted_map_put(&feed, fk, id_str) or_return
	likes_cur := xitdb.hash_map_put_cursor(&root, "likes") or_return
	likes := xitdb.write_hash_map_init(likes_cur) or_return
	set_cur := xitdb.hash_map_put_cursor(&likes, id_str) or_return
	_ = xitdb.write_hash_set_init(set_cur) or_return
	xitdb.hash_map_put(&meta, "next_post_id", next + 1) or_return
	owned_body, berr := strings.clone(ctx.body, ctx.alloc)
	if berr != nil {
		return .Write_Failed
	}
	owned_author, aerr1 := strings.clone(ctx.username, ctx.alloc)
	if aerr1 != nil {
		return .Write_Failed
	}
	ctx.out^ = Post{
		id         = next,
		body       = owned_body,
		created_at = created_at,
		author     = owned_author,
		like_count = 0,
	}
	ctx.have_out^ = true
	return nil
}

store_create_post :: proc(s: ^Store, username: string, body: string, allocator := context.allocator) -> (Post, bool) {
	created: Post
	have_out := false
	ctx := Create_Ctx{alloc = allocator, username = username, body = body, out = &created, have_out = &have_out}
	if xitdb.database_run_context(&s.db, create_ctx_run, &ctx) != nil {
		return {}, false
	}
	if !have_out {
		return {}, false
	}
	return created, true
}

Like_Ctx :: struct {
	alloc:    mem.Allocator,
	id_str:   string,
	user_str: string,
	found:    ^bool,
	already:  ^bool,
}

like_ctx_run :: proc(cursor: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := cast(^Like_Ctx)user_data
	root := xitdb.write_hash_map_init(cursor^) or_return
	posts := xitdb.write_hash_map_init(xitdb.hash_map_put_cursor(&root, "posts") or_return) or_return
	exists, exerr := xitdb.hash_map_get_cursor(posts, ctx.id_str)
	if exerr != nil {
		return exerr
	}
	if exists == nil {
		return nil
	}
	ctx.found^ = true
	likes := xitdb.write_hash_map_init(xitdb.hash_map_put_cursor(&root, "likes") or_return) or_return
	set := xitdb.write_hash_set_init(xitdb.hash_map_put_cursor(&likes, ctx.id_str) or_return) or_return
	member, merr := xitdb.hash_set_get_cursor(set, ctx.user_str)
	if merr != nil {
		return merr
	}
	if member != nil {
		ctx.already^ = true
		return nil
	}
	xitdb.hash_set_put(&set, ctx.user_str) or_return
	pm := xitdb.write_hash_map_init(xitdb.hash_map_put_cursor(&posts, ctx.id_str) or_return) or_return
	lc_cur := xitdb.hash_map_get_cursor(pm, "like_count") or_return
	if lc_cur == nil {
		return .Invalid_Database
	}
	cur := xitdb.cursor_read_uint(lc_cur.?) or_return
	xitdb.hash_map_put(&pm, "like_count", cur + 1) or_return
	return nil
}

store_like_post :: proc(s: ^Store, id: u64, user_id: u64, allocator := context.allocator) -> (found: bool, already: bool) {
	id_str, idok := sprint_u64(s.alloc, id)
	if !idok {
		return false, false
	}
	defer delete(id_str, s.alloc)
	user_str, uok := sprint_u64(s.alloc, user_id)
	if !uok {
		return false, false
	}
	defer delete(user_str, s.alloc)
	ctx := Like_Ctx{alloc = allocator, id_str = id_str, user_str = user_str, found = &found, already = &already}
	if xitdb.database_run_context(&s.db, like_ctx_run, &ctx) != nil {
		return false, false
	}
	return found, already
}

sprint_u64 :: proc(alloc: mem.Allocator, n: u64) -> (string, bool) {
	buf: [32]u8
	s := sprint_u64_buf(buf[:], n)
	out, err := strings.clone(s, alloc)
	if err != nil {
		return "", false
	}
	return out, true
}

sprint_u64_buf :: proc(buf: []u8, n: u64) -> string {
	i := len(buf)
	v := n
	if v == 0 {
		i -= 1
		buf[i] = '0'
		return string(buf[i:])
	}
	for v > 0 {
		i -= 1
		buf[i] = u8(v % 10) + '0'
		v /= 10
	}
	return string(buf[i:])
}

now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1000000
}

write_escaped_string :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for b in transmute([]u8)s {
		switch b {
		case '"':
			strings.write_string(sb, "\\\"")
		case '\\':
			strings.write_string(sb, "\\\\")
		case '\n':
			strings.write_string(sb, "\\n")
		case '\r':
			strings.write_string(sb, "\\r")
		case '\t':
			strings.write_string(sb, "\\t")
		case:
			if b < 0x20 {
				hex := "0123456789abcdef"
				strings.write_string(sb, "\\u00")
				strings.write_byte(sb, hex[b >> 4])
				strings.write_byte(sb, hex[b & 0xF])
			} else {
				strings.write_byte(sb, b)
			}
		}
	}
	strings.write_byte(sb, '"')
}

write_u64 :: proc(sb: ^strings.Builder, n: u64) {
	buf: [20]u8
	s := sprint_u64_buf(buf[:], n)
	strings.write_string(sb, s)
}

post_json :: proc(p: Post, allocator := context.allocator) -> string {
	sb: strings.Builder
	strings.builder_init(&sb, allocator)
	strings.write_string(&sb, "{\"id\":")
	write_u64(&sb, p.id)
	strings.write_string(&sb, ",\"body\":")
	write_escaped_string(&sb, p.body)
	strings.write_string(&sb, ",\"created_at\":")
	write_escaped_string(&sb, p.created_at)
	strings.write_string(&sb, ",\"author\":")
	write_escaped_string(&sb, p.author)
	strings.write_string(&sb, ",\"like_count\":")
	write_u64(&sb, p.like_count)
	strings.write_byte(&sb, '}')
	return strings.to_string(sb)
}



free_post :: proc(alloc: mem.Allocator, p: Post) {
	delete(p.body, alloc)
	delete(p.created_at, alloc)
	delete(p.author, alloc)
}

free_posts :: proc(alloc: mem.Allocator, feed: []Post) {
	for p in feed {
		free_post(alloc, p)
	}
	delete(feed, alloc)
}
