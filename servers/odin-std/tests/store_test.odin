package server_tests

import srv "../src"
import xitdb "../vendor/xitdb"
import "core:os"
import "core:fmt"
import "core:testing"

delete_test_db :: proc(path: string) {
	os.remove(path)
}

open_test_store :: proc(name: string) -> (s: ^srv.Store, path: string) {
	path = fmt.tprintf("./xb-odin-test-%s-tmp.db", name)
	s, _ = srv.open_store(context.allocator, path, "test-secret")
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
	srv.store_create_post(s, "alice", "second")
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
test_txn_rule :: proc(t: ^testing.T) {
	// putCursor-descend outside run_context: record behavior (Rust throws /
	// Go+Zig allow); whichever → ledgered ruling, planned shape kept.
	path := "./xb-odin-txnrule-tmp.db"
	defer delete_test_db(path)
	core, _ := xitdb.core_buffered_file_open(path, 1024 * 1024)
	defer xitdb.core_destroy(&core, close_file = true)
	db, _ := xitdb.database_init(&core, xitdb.sha1_hasher())
	root, _ := xitdb.write_hash_map_init(xitdb.database_root_cursor(&db))
	// Observed: allowed (Go/Zig-like, not Rust-like). Pin it so a future
	// behavior change fails loudly; the planned shape (reads getCursor,
	// writes runContext) stands either way.
	_, err := xitdb.hash_map_put_cursor(&root, "txn-probe")
	testing.expect(t, err == nil)
	_ = t
}
