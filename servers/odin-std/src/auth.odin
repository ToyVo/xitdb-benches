package main

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:encoding/json"
import "core:strings"
import "core:time"

TOKEN_ERR :: "invalid or expired token"
PAYLOAD_ERR :: "invalid token payload"

now_sec :: proc() -> i64 {
	return time.to_unix_seconds(time.now())
}

b64url_decode :: proc(s: string, allocator := context.allocator) -> ([]u8, bool) {
	decoded, err := base64.decode(s, base64.DEC_URL_TABLE, nil, allocator, {.No_Padding})
	if err != nil {
		return nil, false
	}
	return decoded, true
}

// Returns (user_id, username, errmsg); errmsg == "" on success.
// username is allocated with allocator (caller frees; server uses its arena).
verify_jwt :: proc(
	token, secret: string,
	now_s: i64,
	allocator := context.allocator,
) -> (
	user_id: u64,
	username: string,
	errmsg: string,
) {
	dot1 := strings.index_byte(token, '.')
	dot2 := strings.index_byte(token[dot1 + 1:], '.')
	if dot1 < 0 || dot2 < 0 {
		return 0, "", TOKEN_ERR
	}
	dot2 += dot1 + 1
	if strings.index_byte(token[dot2 + 1 :], '.') >= 0 {
		return 0, "", TOKEN_ERR
	}
	header_b64 := token[:dot1]
	payload_b64 := token[dot1 + 1 : dot2]
	sig_b64 := token[dot2 + 1 :]
	header_raw, ok1 := b64url_decode(header_b64, allocator)
	if !ok1 {
		return 0, "", TOKEN_ERR
	}
	Header :: struct {
		alg: string,
		typ: string,
	}
	header: Header
	if json.unmarshal(header_raw, &header, allocator = allocator) != nil {
		return 0, "", TOKEN_ERR
	}
	if header.alg != "HS256" {
		return 0, "", TOKEN_ERR
	}
	sig, ok2 := b64url_decode(sig_b64, allocator)
	if !ok2 || len(sig) != 32 {
		return 0, "", TOKEN_ERR
	}
	msg := token[: dot1 + 1 + len(payload_b64)]
	mac: [32]u8
	hmac.sum(.SHA256, mac[:], transmute([]u8)msg, transmute([]u8)secret)
	if crypto.compare_constant_time(mac[:], sig) != 1 {
		return 0, "", TOKEN_ERR
	}
	payload_raw, ok3 := b64url_decode(payload_b64, allocator)
	if !ok3 {
		return 0, "", TOKEN_ERR
	}
	Payload :: struct {
		sub:      json.Value,
		username: json.Value,
		exp:      json.Value,
	}
	payload: Payload
	if json.unmarshal(payload_raw, &payload, allocator = allocator) != nil {
		return 0, "", TOKEN_ERR
	}
	sub, sub_ok := payload.sub.(json.String)
	if !sub_ok || len(sub) == 0 {
		return 0, "", PAYLOAD_ERR
	}
	for b in transmute([]u8)string(sub) {
		if b < '0' || b > '9' {
			return 0, "", PAYLOAD_ERR
		}
	}
	uid, uid_ok := parse_u64_digits(string(sub))
	if !uid_ok || uid < 1 {
		return 0, "", PAYLOAD_ERR
	}
	name, name_ok := payload.username.(json.String)
	if !name_ok {
		return 0, "", PAYLOAD_ERR
	}
	exp, exp_ok := payload.exp.(json.Integer)
	if !exp_ok {
		return 0, "", TOKEN_ERR
	}
	if exp + 60 < now_s {
		return 0, "", TOKEN_ERR
	}
	return uid, string(name), ""
}
