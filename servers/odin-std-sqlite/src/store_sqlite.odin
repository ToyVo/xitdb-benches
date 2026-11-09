package main

import "core:mem"
import "core:strings"
import "core:time"

foreign import libsqlite3 "system:sqlite3"

sqlite3 :: struct{}
sqlite3_stmt :: struct{}
sqlite3_destructor_type :: proc "c" (ptr: rawptr)

@(default_calling_convention = "c")
foreign libsqlite3 {
	sqlite3_open :: proc(filename: cstring, ppDb: ^^sqlite3) -> i32 ---;
	sqlite3_close :: proc(db: ^sqlite3) -> i32 ---;
	sqlite3_prepare_v2 :: proc(db: ^sqlite3, sql: cstring, nByte: i32, ppStmt: ^^sqlite3_stmt, pzTail: ^cstring) -> i32 ---;
	sqlite3_bind_int64 :: proc(stmt: ^sqlite3_stmt, idx: i32, v: i64) -> i32 ---;
	sqlite3_bind_text :: proc(stmt: ^sqlite3_stmt, idx: i32, v: cstring, n: i32, destr: sqlite3_destructor_type) -> i32 ---;
	sqlite3_step :: proc(stmt: ^sqlite3_stmt) -> i32 ---;
	sqlite3_reset :: proc(stmt: ^sqlite3_stmt) -> i32 ---;
	sqlite3_column_int64 :: proc(stmt: ^sqlite3_stmt, i: i32) -> i64 ---;
	sqlite3_column_text :: proc(stmt: ^sqlite3_stmt, i: i32) -> [^]u8 ---;
	sqlite3_column_bytes :: proc(stmt: ^sqlite3_stmt, i: i32) -> i32 ---;
	sqlite3_finalize :: proc(stmt: ^sqlite3_stmt) -> i32 ---;
	sqlite3_last_insert_rowid :: proc(db: ^sqlite3) -> i64 ---;
	sqlite3_changes :: proc(db: ^sqlite3) -> i32 ---;
	sqlite3_busy_timeout :: proc(db: ^sqlite3, ms: i32) -> i32 ---;
}

SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101

// Destructor param takes rawptr (nil-able, same ABI as the C function
// pointer): we always pass nil (nil) — SQLite must not copy or
// free. Sound because every bound slice outlives its synchronous step().

// Statements are prepared once at open and reused under the single
// global mutex (same serialization as the xitdb twin). Every method
// resets its statement before binding and after stepping.
FEED_SQL :: "SELECT p.id,p.body,p.created_at,u.username,(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id) FROM posts p JOIN users u ON u.id=p.user_id ORDER BY p.created_at DESC,p.id DESC LIMIT 20";
POST_SQL :: "SELECT p.id,p.body,p.created_at,u.username,(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id) FROM posts p JOIN users u ON u.id=p.user_id WHERE p.id=?1";
USER_SQL :: "SELECT id FROM users WHERE username=?1";
INSERT_POST_SQL :: "INSERT INTO posts(user_id,body,created_at) VALUES(?1,?2,?3)";
EXISTS_SQL :: "SELECT 1 FROM posts WHERE id=?1";
INSERT_LIKE_SQL :: "INSERT OR IGNORE INTO likes(user_id,post_id,created_at) VALUES(?1,?2,?3)";

// Single source: upstream schema, loaded at compile time (a move or edit
// breaks the build loudly instead of drifting at runtime).
SCHEMA_SQL :: #load("../../../seed/schema.sql", string)

Post :: struct {
	id:         u64,
	body:       string,
	created_at: string,
	author:     string,
	like_count: u64,
}

Store :: struct {
	alloc:     mem.Allocator,
	db:        ^sqlite3,
	secret:    string,
	boot_s:    i64,
	st_feed:   ^sqlite3_stmt,
	st_post:   ^sqlite3_stmt,
	st_user:   ^sqlite3_stmt,
	st_create: ^sqlite3_stmt,
	st_exists: ^sqlite3_stmt,
	st_like:   ^sqlite3_stmt,
}

now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1000000
}

// The Store is heap-allocated so the handle stays put after init.
open_store :: proc(alloc: mem.Allocator, path: string, secret: string) -> (^Store, bool) {
	s := new(Store, alloc)
	s.alloc = alloc
	s.secret = secret
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	db: ^sqlite3 = nil
	if sqlite3_open(cpath, &db) != SQLITE_OK {
		free(s, alloc)
		return nil, false
	}
	s.db = db
	sqlite3_busy_timeout(db, 5000)
	ok := apply_schema(db) && prepare_all(s)
	if !ok {
		store_deinit(s)
		return nil, false
	}
	s.boot_s = now_ms()
	return s, true
}

// Applies the schema only when the users table is absent (existing files
// keep their data; :memory: always counts as fresh).
apply_schema :: proc(db: ^sqlite3) -> bool {
	probe: ^sqlite3_stmt = nil
	cprobe := strings.clone_to_cstring("SELECT name FROM sqlite_master WHERE type='table' AND name='users'", context.temp_allocator)
	if sqlite3_prepare_v2(db, cprobe, -1, &probe, nil) != SQLITE_OK {
		return false
	}
	has := sqlite3_step(probe) == SQLITE_ROW
	sqlite3_finalize(probe)
	if has {
		return true
	}
	schema := SCHEMA_SQL
	for stmt in strings.split_iterator(&schema, ";") {
		t := strings.trim_space(stmt)
		if len(t) == 0 {
			continue
		}
		if !exec_one(db, t) {
			return false
		}
	}
	return true
}

exec_one :: proc(db: ^sqlite3, sql: string) -> bool {
	csql := strings.clone_to_cstring(sql, context.temp_allocator)
	st: ^sqlite3_stmt = nil
	if sqlite3_prepare_v2(db, csql, -1, &st, nil) != SQLITE_OK {
		return false
	}
	rc := sqlite3_step(st)
	sqlite3_finalize(st)
	return rc == SQLITE_DONE || rc == SQLITE_ROW
}

prepare_all :: proc(s: ^Store) -> bool {
	prep :: proc(db: ^sqlite3, sql: string) -> (^sqlite3_stmt, bool) {
		csql := strings.clone_to_cstring(sql, context.temp_allocator)
		st: ^sqlite3_stmt = nil
		if sqlite3_prepare_v2(db, csql, -1, &st, nil) != SQLITE_OK {
			return nil, false
		}
		return st, true
	}
	ok := false
	s.st_feed, ok = prep(s.db, FEED_SQL)
	if !ok {
		return false
	}
	s.st_post, ok = prep(s.db, POST_SQL)
	if !ok {
		return false
	}
	s.st_user, ok = prep(s.db, USER_SQL)
	if !ok {
		return false
	}
	s.st_create, ok = prep(s.db, INSERT_POST_SQL)
	if !ok {
		return false
	}
	s.st_exists, ok = prep(s.db, EXISTS_SQL)
	if !ok {
		return false
	}
	s.st_like, ok = prep(s.db, INSERT_LIKE_SQL)
	if !ok {
		return false
	}
	return true
}

store_deinit :: proc(s: ^Store) {
	alloc := s.alloc
	if s.st_feed != nil {
		sqlite3_finalize(s.st_feed)
	}
	if s.st_post != nil {
		sqlite3_finalize(s.st_post)
	}
	if s.st_user != nil {
		sqlite3_finalize(s.st_user)
	}
	if s.st_create != nil {
		sqlite3_finalize(s.st_create)
	}
	if s.st_exists != nil {
		sqlite3_finalize(s.st_exists)
	}
	if s.st_like != nil {
		sqlite3_finalize(s.st_like)
	}
	if s.db != nil {
		sqlite3_close(s.db)
	}
	free(s, alloc)
}

store_health :: proc(s: ^Store) -> bool {
	st: ^sqlite3_stmt = nil
	csql := strings.clone_to_cstring("SELECT COUNT(*) FROM users", context.temp_allocator)
	if sqlite3_prepare_v2(s.db, csql, -1, &st, nil) != SQLITE_OK {
		return false
	}
	defer sqlite3_finalize(st)
	return sqlite3_step(st) == SQLITE_ROW
}

bind_int :: proc(stmt: ^sqlite3_stmt, idx: i32, v: u64) -> bool {
	sqlite3_reset(stmt)
	return sqlite3_bind_int64(stmt, idx, i64(v)) == SQLITE_OK
}

bind_text :: proc(stmt: ^sqlite3_stmt, idx: i32, v: string) -> bool {
	if len(v) == 0 {
		// "" coerces to a NUL cstring; n=0 reads zero bytes.
		return sqlite3_bind_text(stmt, idx, "", 0, nil) == SQLITE_OK
	}
	return sqlite3_bind_text(stmt, idx, cast(cstring)raw_data(v), i32(len(v)), nil) == SQLITE_OK
}

column_text :: proc(stmt: ^sqlite3_stmt, i: i32, allocator: mem.Allocator) -> (string, bool) {
	p := sqlite3_column_text(stmt, i)
	if p == nil {
		return "", false
	}
	n := int(sqlite3_column_bytes(stmt, i))
	out, err := make([]u8, n, allocator)
	if err != nil {
		return "", false
	}
	copy(out, p[:n])
	return string(out), true
}

read_post_row :: proc(stmt: ^sqlite3_stmt, allocator: mem.Allocator) -> (Post, bool) {
	id := u64(sqlite3_column_int64(stmt, 0))
	body, ok1 := column_text(stmt, 1, allocator)
	if !ok1 {
		return {}, false
	}
	created, ok2 := column_text(stmt, 2, allocator)
	if !ok2 {
		delete(body, allocator)
		return {}, false
	}
	author, ok3 := column_text(stmt, 3, allocator)
	if !ok3 {
		delete(body, allocator)
		delete(created, allocator)
		return {}, false
	}
	return Post{id = id, body = body, created_at = created, author = author, like_count = u64(sqlite3_column_int64(stmt, 4))}, true
}

store_get_post :: proc(s: ^Store, id: u64, allocator := context.allocator) -> (Post, bool) {
	sqlite3_reset(s.st_post)
	if sqlite3_bind_int64(s.st_post, 1, i64(id)) != SQLITE_OK {
		return {}, false
	}
	if sqlite3_step(s.st_post) != SQLITE_ROW {
		sqlite3_reset(s.st_post)
		return {}, false
	}
	p, ok := read_post_row(s.st_post, allocator)
	sqlite3_reset(s.st_post)
	if !ok {
		return {}, false
	}
	return p, true
}

store_get_feed :: proc(s: ^Store, allocator := context.allocator) -> ([]Post, bool) {
	sqlite3_reset(s.st_feed)
	out := make([dynamic]Post, allocator)
	for sqlite3_step(s.st_feed) == SQLITE_ROW {
		p, ok := read_post_row(s.st_feed, allocator)
		if !ok {
			continue
		}
		append(&out, p)
	}
	sqlite3_reset(s.st_feed)
	return out[:], true
}

store_create_post :: proc(s: ^Store, username: string, body: string, allocator := context.allocator) -> (Post, bool) {
	sqlite3_reset(s.st_user)
	if !bind_text(s.st_user, 1, username) {
		sqlite3_reset(s.st_user)
		return {}, false
	}
	if sqlite3_step(s.st_user) != SQLITE_ROW {
		sqlite3_reset(s.st_user)
		return {}, false
	}
	uid := u64(sqlite3_column_int64(s.st_user, 0))
	sqlite3_reset(s.st_user)
	ts_buf: [32]u8
	created_at := strings.clone(format_millis(now_ms(), ts_buf[:]), allocator)
	sqlite3_reset(s.st_create)
	if sqlite3_bind_int64(s.st_create, 1, i64(uid)) != SQLITE_OK {
		delete(created_at, allocator)
		sqlite3_reset(s.st_create)
		return {}, false
	}
	if !bind_text(s.st_create, 2, body) {
		delete(created_at, allocator)
		sqlite3_reset(s.st_create)
		return {}, false
	}
	if !bind_text(s.st_create, 3, created_at) {
		delete(created_at, allocator)
		sqlite3_reset(s.st_create)
		return {}, false
	}
	if sqlite3_step(s.st_create) != SQLITE_DONE {
		delete(created_at, allocator)
		sqlite3_reset(s.st_create)
		return {}, false
	}
	sqlite3_reset(s.st_create)
	id := u64(sqlite3_last_insert_rowid(s.db))
	owned_body := strings.clone(body, allocator)
	owned_author := strings.clone(username, allocator)
	return Post{id = id, body = owned_body, created_at = created_at, author = owned_author, like_count = 0}, true
}

store_like_post :: proc(s: ^Store, id: u64, user_id: u64, allocator := context.allocator) -> (found: bool, already: bool) {
	_ = allocator
	sqlite3_reset(s.st_exists)
	if sqlite3_bind_int64(s.st_exists, 1, i64(id)) != SQLITE_OK {
		sqlite3_reset(s.st_exists)
		return false, false
	}
	has := sqlite3_step(s.st_exists) == SQLITE_ROW
	sqlite3_reset(s.st_exists)
	if !has {
		return false, false
	}
	ts_buf: [32]u8
	created_at := format_millis(now_ms(), ts_buf[:])
	sqlite3_reset(s.st_like)
	if sqlite3_bind_int64(s.st_like, 1, i64(user_id)) != SQLITE_OK {
		sqlite3_reset(s.st_like)
		return true, false
	}
	if sqlite3_bind_int64(s.st_like, 2, i64(id)) != SQLITE_OK {
		sqlite3_reset(s.st_like)
		return true, false
	}
	if !bind_text(s.st_like, 3, created_at) {
		sqlite3_reset(s.st_like)
		return true, false
	}
	if sqlite3_step(s.st_like) != SQLITE_DONE {
		sqlite3_reset(s.st_like)
		return true, false
	}
	sqlite3_reset(s.st_like)
	is_dup := sqlite3_changes(s.db) == 0
	return true, is_dup
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
