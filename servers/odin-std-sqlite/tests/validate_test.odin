package server_tests

import srv "../src"
import "core:testing"

@(test)
test_feed_key :: proc(t: ^testing.T) {
	testing.expect_value(t, srv.feed_key("2025-01-01T00:00:00.000Z", 7), "2025-01-01T00:00:00.000Z\x000000000007")
	testing.expect(t, srv.feed_key("2025-01-01T00:00:00.000Z", 7) < srv.feed_key("2025-01-01T00:00:00.000Z", 8))
}

@(test)
test_post_ids :: proc(t: ^testing.T) {
	id, ok := srv.valid_post_id("1")
	testing.expect(t, ok && id == 1)
	id, ok = srv.valid_post_id("999999999")
	testing.expect(t, ok && id == 999999999)
	id, ok = srv.valid_post_id("18446744073709551615")
	testing.expect(t, ok && id == max(u64))
	bads := []string{"0", "-1", "abc", "1.5", ""}
	for bad in bads {
		_, ok := srv.valid_post_id(bad)
		testing.expect(t, !ok, bad)
	}
}

@(test)
test_trim_body :: proc(t: ^testing.T) {
	v, m := srv.trim_body("  hi ")
	testing.expect(t, m == "" && v == "hi")
	_, m = srv.trim_body("   ")
	testing.expect_value(t, m, "body is required")
	a501 := make([]u8, 501)
	defer delete(a501)
	for i in 0..<501 { a501[i] = 'a' }
	_, m = srv.trim_body(string(a501))
	testing.expect_value(t, m, "body must be at most 500 characters")
	b500 := make([]u8, 500)
	defer delete(b500)
	for i in 0..<500 { b500[i] = 'b' }
	v, m = srv.trim_body(string(b500))
	testing.expect(t, m == "" && len(v) == 500)
	// 'é' is 2 bytes / 1 codepoint: 500 codepoints must pass (rune semantics)
	ebuf := make([]u8, 1000)
	defer delete(ebuf)
	for i in 0..<500 { ebuf[2*i] = 0xc3; ebuf[2*i+1] = 0xa9 }
	v, m = srv.trim_body(string(ebuf))
	testing.expect(t, m == "")
}

@(test)
test_format_millis :: proc(t: ^testing.T) {
	buf: [32]u8
	check :: proc(t: ^testing.T, buf: []u8, ms: i64, want: string) {
		got := srv.format_millis(ms, buf)
		testing.expect_value(t, got, want)
	}
	check(t, buf[:], 0, "1970-01-01T00:00:00.000Z")
	check(t, buf[:], 1704067200000, "2024-01-01T00:00:00.000Z")
	check(t, buf[:], 1709251200000, "2024-03-01T00:00:00.000Z")
	check(t, buf[:], 1735689634152, "2025-01-01T00:00:34.152Z")
}
