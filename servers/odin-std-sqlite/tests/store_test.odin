package server_tests

import srv "../src"
import "core:os"
import "core:fmt"
import "core:testing"

delete_test_db :: proc(path: string) {
	os.remove(path)
}

seed_alice :: proc(s: ^srv.Store) {
	// Tests create posts as "alice" and like as user 7: alice must be id 7
	// for the JOIN to see the rows (same FK shape as production seeds).
	stmt: ^srv.sqlite3_stmt = nil
	csql := fmt.ctprintf("INSERT INTO users(id,username,created_at) VALUES(7,'alice','2025-01-01T00:00:00.000Z')")
	if srv.sqlite3_prepare_v2(s.db, csql, -1, &stmt, nil) != srv.SQLITE_OK {
		panic("seed prepare failed")
	}
	if srv.sqlite3_step(stmt) != srv.SQLITE_DONE {
		panic("seed insert failed")
	}
	srv.sqlite3_finalize(stmt)
}

open_test_store :: proc(name: string) -> (s: ^srv.Store, path: string) {
	path = fmt.tprintf("./xb-odin-test-%s-tmp.db", name)
	s, _ = srv.open_store(context.allocator, path, "test-secret")
	seed_alice(s)
	return s, path
}

@(test)
test_store_round_trip :: proc(t: ^testing.T) {
	s, path := open_test_store("roundtrip")
	defer srv.store_deinit(s)
	defer delete_test_db(path)
	p, ok := srv.store_create_post(s, "alice", "hi")
	testing.expect(t, ok)
	testing.expect_value(t, p.id, u64(1))
	testing.expect_value(t, p.body, "hi")
	testing.expect_value(t, p.author, "alice")
	testing.expect_value(t, p.like_count, u64(0))
	testing.expect(t, len(p.created_at) == 24)
	testing.expect(t, p.created_at[23] == 'Z')
	got, found := srv.store_get_post(s, 1)
	testing.expect(t, found)
	testing.expect_value(t, got.id, p.id)
	testing.expect_value(t, got.body, p.body)
	_, found = srv.store_get_post(s, 999)
	testing.expect(t, !found)
	{
		c2, _ := srv.store_create_post(s, "alice", "second")
		defer srv.free_post(context.allocator, c2)
	}
	feed, _ := srv.store_get_feed(s)
	testing.expect_value(t, len(feed), 2)
	testing.expect_value(t, feed[0].id, u64(2))
	testing.expect_value(t, feed[1].id, u64(1))
}

@(test)
test_store_like :: proc(t: ^testing.T) {
	s, path := open_test_store("like")
	defer srv.store_deinit(s)
	defer delete_test_db(path)
	srv.store_create_post(s, "alice", "x")
	found, already := srv.store_like_post(s, 1, 7)
	testing.expect(t, found && !already)
	found, already = srv.store_like_post(s, 1, 7)
	testing.expect(t, found && already)
	got, _ := srv.store_get_post(s, 1)
	testing.expect_value(t, got.like_count, u64(1))
	found, _ = srv.store_like_post(s, 999, 7)
	testing.expect(t, !found)
}

@(test)
test_store_missing :: proc(t: ^testing.T) {
	s, path := open_test_store("missing")
	defer srv.store_deinit(s)
	defer delete_test_db(path)
	_, found := srv.store_get_post(s, 12345)
	testing.expect(t, !found)
	found, _ = srv.store_like_post(s, 12345, 9)
	testing.expect(t, !found)
	feed, _ := srv.store_get_feed(s)
	testing.expect_value(t, len(feed), 0)
	testing.expect(t, srv.store_health(s))
}

@(test)
test_like_primary_key :: proc(t: ^testing.T) {
	// PRIMARY KEY (user_id, post_id) is what makes repeat likes a no-op
	// at the engine level; pin it so schema drift fails loudly.
	s, path := open_test_store("pk")
	defer srv.store_deinit(s)
	defer delete_test_db(path)
	srv.store_create_post(s, "alice", "x")
	stmt: ^srv.sqlite3_stmt = nil
	csql := fmt.ctprintf("INSERT INTO likes(user_id,post_id,created_at) VALUES(7,1,'2025-01-01T00:00:00.000Z')")
	if srv.sqlite3_prepare_v2(s.db, csql, -1, &stmt, nil) != srv.SQLITE_OK {
		panic("pk prepare failed")
	}
	testing.expect(t, srv.sqlite3_step(stmt) == srv.SQLITE_DONE)
	testing.expect(t, srv.sqlite3_step(stmt) != srv.SQLITE_DONE)
	srv.sqlite3_finalize(stmt)
	_ = t
}

@(test)
test_schema_tables :: proc(t: ^testing.T) {
	s, path := open_test_store("schema")
	defer srv.store_deinit(s)
	defer delete_test_db(path)
	stmt: ^srv.sqlite3_stmt = nil
	csql := fmt.ctprintf("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
	if srv.sqlite3_prepare_v2(s.db, csql, -1, &stmt, nil) != srv.SQLITE_OK {
		panic("schema prepare failed")
	}
	names := ""
	for srv.sqlite3_step(stmt) == srv.SQLITE_ROW {
		p := srv.sqlite3_column_text(stmt, 0)
		n := srv.sqlite3_column_bytes(stmt, 0)
		names = fmt.tprintf("%s%s,", names, string(p[:n]))
	}
	srv.sqlite3_finalize(stmt)
	testing.expect_value(t, names, "likes,posts,users,")
	_ = t
}
