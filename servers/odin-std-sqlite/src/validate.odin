package main

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

feed_key :: proc(created_at: string, id: u64, allocator := context.allocator) -> string {
	sb: strings.Builder
	strings.builder_init(&sb, allocator)
	strings.write_string(&sb, created_at)
	strings.write_byte(&sb, 0)
	tmp: [20]u8
	digits := fmt.bprintf(tmp[:], "%d", id)
	for _ in len(digits)..<10 {
		strings.write_byte(&sb, '0')
	}
	strings.write_string(&sb, digits)
	return strings.to_string(sb)
}

valid_post_id :: proc(s: string) -> (u64, bool) {
	if len(s) == 0 {
		return 0, false
	}
	for b in transmute([]u8)s {
		if b < '0' || b > '9' {
			return 0, false
		}
	}
	n, ok := parse_u64_digits(s)
	if !ok || n < 1 {
		return 0, false
	}
	return n, true
}

// Manual u64 parse (digits pre-validated); rejects overflow past 2^64-1.
parse_u64_digits :: proc(s: string) -> (u64, bool) {
	n: u64 = 0
	for b in transmute([]u8)s {
		d := u64(b - '0')
		if n > (max(u64) - d) / 10 {
			return 0, false
		}
		n = n * 10 + d
	}
	return n, true
}

trim_body :: proc(s: string) -> (string, string) {
	t := strings.trim_space(s)
	if len(t) == 0 {
		return "", "body is required"
	}
	if utf8.rune_count(t) > 500 {
		return "", "body must be at most 500 characters"
	}
	return t, ""
}

format_millis :: proc(ms: i64, buf: []u8) -> string {
	days := ms / 86400000
	rem_ms := ms % 86400000
	z := days + 719468
	era := z / 146097
	dow := z - era * 146097 // UInt64 in disguise; values are non-negative here
	doe := u64(dow)
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y := i64(yoe) + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d := doy - (153 * mp + 2) / 5 + 1
	month := mp + 3 if mp < 10 else mp - 9
	if month <= 2 {
		y += 1
	}
	urem: u64 = auto_cast rem_ms
	hour := urem / 3600000
	min := (urem % 3600000) / 60000
	sec := (urem % 60000) / 1000
	milli := urem % 1000
	return fmt.bprintf(
		buf,
		"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
		u64(y), month, d, hour, min, sec, milli,
	)
}
