package server_tests

import srv "../src"
import "core:fmt"
import "core:testing"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"

SECRET :: "twelve-dollar-challenge"

sign_for_test :: proc(payload: string, secret: string = SECRET) -> string {
	header_b64 :: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
	payload_b64 := base64.encode(transmute([]u8)payload, base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding})
	msg := fmt.tprintf("%s.%s", header_b64, payload_b64)
	mac: [32]u8
	hmac.sum(.SHA256, mac[:], transmute([]u8)msg, transmute([]u8)secret)
	sig := base64.encode(mac[:], base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding})
	return fmt.tprintf("%s.%s", msg, sig)
}

payload_for_test :: proc(sub: string, username: string, iat, exp: i64) -> string {
	return fmt.tprintf(
		"{{\"sub\":\"%s\",\"username\":\"%s\",\"iat\":%d,\"exp\":%d}}",
		sub, username, iat, exp,
	)
}

@(test)
test_jwt_good :: proc(t: ^testing.T) {
	now := srv.now_sec()
	tok := sign_for_test(payload_for_test("1", "alice", now, now + 3600))
	user_id, username, errmsg := srv.verify_jwt(tok, SECRET, now)
	testing.expect_value(t, errmsg, "")
	testing.expect_value(t, user_id, u64(1))
	testing.expect_value(t, username, "alice")
}

@(test)
test_jwt_bad_signatures :: proc(t: ^testing.T) {
	now := srv.now_sec()
	bad_sig := sign_for_test(payload_for_test("1", "alice", now, now + 3600), "wrong-secret")
	old := payload_for_test("1", "alice", now - 7200, now - 3600)
	expired := sign_for_test(old)
	raw_b64 := base64.encode(
		transmute([]u8)payload_for_test("1", "alice", now, now + 3600),
		base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding})
	none_tok := fmt.tprintf(
		"eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.%s.", raw_b64)
	toks := []string{bad_sig, expired, "abc", none_tok}
	for tok in toks {
		_, _, errmsg := srv.verify_jwt(tok, SECRET, now)
		testing.expect_value(t, errmsg, "invalid or expired token")
	}
}

@(test)
test_jwt_bad_payloads :: proc(t: ^testing.T) {
	now := srv.now_sec()
	far := now + 100000
	full_cases := [2]string{
		fmt.tprintf("{{\"sub\":\"abc\",\"username\":\"alice\",\"iat\":%d,\"exp\":%d}}", now, far),
		fmt.tprintf("{{\"sub\":9,\"username\":\"alice\",\"iat\":%d,\"exp\":%d}}", now, far),
	}
	for full in full_cases {
		tok := sign_for_test(full)
		_, _, errmsg := srv.verify_jwt(tok, SECRET, now)
		testing.expect_value(t, errmsg, "invalid token payload")
	}
	no_name := fmt.tprintf("{{\"sub\":\"1\",\"iat\":%d,\"exp\":%d}}", now, far)
	tok := sign_for_test(no_name)
	_, _, errmsg := srv.verify_jwt(tok, SECRET, now)
	testing.expect_value(t, errmsg, "invalid token payload")
	num_name := fmt.tprintf("{{\"sub\":\"1\",\"username\":123,\"iat\":%d,\"exp\":%d}}", now, far)
	tok2 := sign_for_test(num_name)
	_, _, errmsg2 := srv.verify_jwt(tok2, SECRET, now)
	testing.expect_value(t, errmsg2, "invalid token payload")
}

@(test)
test_jwt_leeway :: proc(t: ^testing.T) {
	now := srv.now_sec()
	tok := sign_for_test(payload_for_test("1", "alice", now - 3600, now - 30))
	user_id, _, errmsg := srv.verify_jwt(tok, SECRET, now)
	testing.expect_value(t, errmsg, "")
	testing.expect_value(t, user_id, u64(1))
}
