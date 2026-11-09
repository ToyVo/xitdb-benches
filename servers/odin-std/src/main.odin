package main

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:unicode/utf8"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

g_store: ^Store
g_mutex: sync.Mutex
g_secret: string
g_boot_ms: i64

Conn_Args :: struct {
	client: net.TCP_Socket,
}

send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(sock, data[sent:])
		if err != nil || n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

// Reads until the header terminator is seen (growing buf); returns the
// header length or -1 on error/oversize. Any bytes after the terminator
// belong to the body and are reported via body_start.
read_head :: proc(sock: net.TCP_Socket, buf: ^[dynamic]u8) -> (head_len: int, ok: bool) {
	tmp: [8192]u8
	for {
		if len(buf) > 65536 {
			return 0, false
		}
		n, err := net.recv_tcp(sock, tmp[:])
		if err != nil || n <= 0 {
			return 0, false
		}
		append(buf, ..tmp[:n])
		if idx := strings.index(string(buf[:]), "\r\n\r\n"); idx >= 0 {
			return idx + 4, true
		}
	}
}

read_exactly :: proc(sock: net.TCP_Socket, buf: []u8) -> bool {
	got := 0
	for got < len(buf) {
		tmp: [8192]u8
		want := min(len(buf) - got, len(tmp))
		n, err := net.recv_tcp(sock, tmp[:want])
		if err != nil || n <= 0 {
			return false
		}
		copy(buf[got:], tmp[:n])
		got += n
	}
	return true
}

get_header :: proc(head: string, name: string) -> (string, bool) {
	lines := strings.split_lines(head)
	defer delete(lines)
	if len(lines) == 0 {
		return "", false
	}
	for line in lines[1:] {
		if len(line) == 0 {
			break
		}
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		if strings.equal_fold(line[:colon], name) {
			return strings.trim_space(line[colon + 1 :]), true
		}
	}
	return "", false
}

respond :: proc(sock: net.TCP_Socket, keep_open: bool, status: int, reason, body: string) -> bool {
	conn := "keep-alive" if keep_open else "close"
	head := fmt.tprintf(
		"HTTP/1.1 %d %s\r\ncontent-type: application/json\r\ncontent-length: %d\r\nconnection: %s\r\n\r\n",
		status, reason, len(body), conn,
	)
	defer delete(head)
	if !send_all(sock, transmute([]u8)head) {
		return false
	}
	if len(body) > 0 && !send_all(sock, transmute([]u8)body) {
		return false
	}
	return keep_open
}

err_json :: proc(sock: net.TCP_Socket, keep_open: bool, status: int, reason, msg: string, alloc: mem.Allocator) -> bool {
	body := strings.concatenate([]string{"{\"error\":\"", msg, "\"}"})
	defer delete(body, alloc)
	return respond(sock, keep_open, status, reason, body)
}

bearer_token :: proc(head: string) -> (string, bool) {
	v, ok := get_header(head, "authorization")
	if !ok || !strings.has_prefix(v, "Bearer ") {
		return "", false
	}
	return v[len("Bearer "):], true
}

// Returns (user_id, username, errmsg): errmsg == "" on success.
check_auth :: proc(head: string, alloc: mem.Allocator) -> (u64, string, string) {
	tok, ok := bearer_token(head)
	if !ok {
		return 0, "", "missing bearer token"
	}
	uid, name, errmsg := verify_jwt(tok, g_secret, now_sec(), alloc)
	if errmsg != "" {
		return 0, "", errmsg
	}
	return uid, name, ""
}

handle_one :: proc(sock: net.TCP_Socket, head: string, body: string, alloc: mem.Allocator) -> bool {
	context.allocator = alloc
	// Request line.
	eol := strings.index_byte(head, '\r')
	if eol < 0 {
		return respond(sock, false, 400, "Bad Request", "{\"error\":\"not found\"}")
	}
	parts := strings.split(head[:eol], " ", alloc)
	defer delete(parts, alloc)
	if len(parts) != 3 {
		return respond(sock, false, 400, "Bad Request", "{\"error\":\"not found\"}")
	}
	method, target_raw := parts[0], parts[1]
	target := target_raw
	if q := strings.index_byte(target, '?'); q >= 0 {
		target = target[:q]
	}
	// Frameless body-methods cannot reuse the connection (no way to skip
	// an unframed body): answer normally but close.
	framing_ok := false
	if method != "POST" {
		framing_ok = true
	} else {
		if cl, ok := get_header(head, "content-length"); ok && len(cl) > 0 {
			framing_ok = true
		} else if te, ok := get_header(head, "transfer-encoding"); ok && len(te) > 0 {
			framing_ok = true
		}
	}
	keep_open := framing_ok
	want_close := false
	if conn, ok := get_header(head, "connection"); ok && strings.equal_fold(conn, "close") {
		want_close = true
	}

	if method == "GET" && target == "/health" {
		sync.mutex_lock(&g_mutex)
		ok := store_health(g_store)
		uptime := now_ms() / 1000 - g_store.boot_s / 1000
		sync.mutex_unlock(&g_mutex)
		if !ok {
			return respond(sock, keep_open, 503, "Service Unavailable", "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"read failed\"}")
		}
		hb: strings.Builder
		strings.builder_init(&hb, alloc)
		defer strings.builder_destroy(&hb)
		strings.write_string(&hb, "{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":")
		write_u64(&hb, u64(uptime))
		strings.write_byte(&hb, '}')
		out := strings.to_string(hb)
		defer delete(out, alloc)
		return respond(sock, keep_open && !want_close, 200, "OK", out)
	}
	if method == "GET" && target == "/feed" {
		sync.mutex_lock(&g_mutex)
		feed, ok := store_get_feed(g_store)
		sync.mutex_unlock(&g_mutex)
		if !ok {
			return err_json(sock, keep_open, 500, "Internal Server Error", "internal server error", alloc)
		}
		defer free_posts(alloc, feed)
		sb: strings.Builder
		strings.builder_init(&sb, alloc)
		defer strings.builder_destroy(&sb)
		strings.write_string(&sb, "{\"posts\":[")
		for p, i in feed {
			if i > 0 {
				strings.write_byte(&sb, ',')
			}
			js := post_json(p, alloc)
			defer delete(js, alloc)
			strings.write_string(&sb, js)
		}
		strings.write_string(&sb, "]}")
		return respond(sock, keep_open && !want_close, 200, "OK", strings.to_string(sb))
	}
	if method == "GET" && strings.has_prefix(target, "/posts/") {
		id_raw := target[len("/posts/"):]
		if strings.index_byte(id_raw, '/') >= 0 {
			return err_json(sock, keep_open, 404, "Not Found", "not found", alloc)
		}
		id, id_ok := valid_post_id(id_raw)
		if !id_ok {
			return err_json(sock, keep_open, 400, "Bad Request", "invalid post id", alloc)
		}
		sync.mutex_lock(&g_mutex)
		p, found := store_get_post(g_store, id)
		sync.mutex_unlock(&g_mutex)
		if !found {
			return err_json(sock, keep_open, 404, "Not Found", "post not found", alloc)
		}
		defer free_post(alloc, p)
		js := post_json(p, alloc)
		defer delete(js, alloc)
		out := strings.concatenate([]string{"{\"post\":", js, "}"})
		defer delete(out, alloc)
		return respond(sock, keep_open && !want_close, 200, "OK", out)
	}
	if method == "POST" && target == "/posts" {
		uid, username, autherr := check_auth(head, alloc)
		if autherr != "" {
			return err_json(sock, keep_open, 401, "Unauthorized", autherr, alloc)
		}
		_ = uid
		body_val, body_ok := parse_body_field(body, alloc)
		if !body_ok {
			// Distinguish malformed JSON from a present-but-bad body.
			if !is_json_object(body) {
				return err_json(sock, keep_open, 400, "Bad Request", "malformed JSON body", alloc)
			}
			return err_json(sock, keep_open, 400, "Bad Request", "body is required", alloc)
		}
			trimmed, msg := trim_body(body_val)
			if msg != "" {
			return err_json(sock, keep_open, 400, "Bad Request", msg, alloc)
		}
		sync.mutex_lock(&g_mutex)
		created, ok := store_create_post(g_store, username, trimmed)
		sync.mutex_unlock(&g_mutex)
		if !ok {
			return err_json(sock, keep_open, 500, "Internal Server Error", "internal server error", alloc)
		}
		defer free_post(alloc, created)
		js := post_json(created, alloc)
		defer delete(js, alloc)
		out := strings.concatenate([]string{"{\"post\":", js, "}"})
		defer delete(out, alloc)
		return respond(sock, keep_open && !want_close, 201, "Created", out)
	}
	if method == "POST" && strings.has_prefix(target, "/posts/") && strings.has_suffix(target, "/like") {
		uid, _, autherr := check_auth(head, alloc)
		if autherr != "" {
			return err_json(sock, keep_open, 401, "Unauthorized", autherr, alloc)
		}
		id_raw := target[len("/posts/") : len(target) - len("/like")]
		if strings.index_byte(id_raw, '/') >= 0 {
			return err_json(sock, keep_open, 404, "Not Found", "not found", alloc)
		}
		id, id_ok := valid_post_id(id_raw)
		if !id_ok {
			return err_json(sock, keep_open, 400, "Bad Request", "invalid post id", alloc)
		}
		sync.mutex_lock(&g_mutex)
		found, already := store_like_post(g_store, id, uid)
		sync.mutex_unlock(&g_mutex)
		_ = found
		if !found {
			return err_json(sock, keep_open, 404, "Not Found", "post not found", alloc)
		}
		status := 201
		reason := "Created"
		if already {
			status = 200
			reason = "OK"
		}
		lb: strings.Builder
		strings.builder_init(&lb, alloc)
		defer strings.builder_destroy(&lb)
		strings.write_string(&lb, "{\"liked\":true,\"already_liked\":")
		strings.write_string(&lb, "true" if already else "false")
		strings.write_string(&lb, ",\"post_id\":")
		write_u64(&lb, id)
		strings.write_byte(&lb, '}')
		out := strings.to_string(lb)
		defer delete(out, alloc)
		return respond(sock, keep_open && !want_close, status, reason, out)
	}
	return err_json(sock, keep_open, 404, "Not Found", "not found", alloc)
}

// Minimal JSON body handling for POST /posts: returns the raw "body" field
// value (unescaped) when present and a string, else nil. Malformed JSON is
// detected separately by is_json_object.
parse_body_field :: proc(body: string, allocator := context.allocator) -> (string, bool) {
	key := "\"body\""
	i := strings.index(body, key)
	if i < 0 {
		return "", false
	}
	j := i + len(key)
	for j < len(body) && (body[j] == ' ' || body[j] == '\t' || body[j] == '\r' || body[j] == '\n') {
		j += 1
	}
	if j >= len(body) || body[j] != ':' {
		return "", false
	}
	j += 1
	for j < len(body) && (body[j] == ' ' || body[j] == '\t' || body[j] == '\r' || body[j] == '\n') {
		j += 1
	}
	if j >= len(body) || body[j] != '"' {
		return "", false
	}
	// Unescape a JSON string (subset: \" \\ \n \r \t \uXXXX + literals).
	sb: strings.Builder
	strings.builder_init(&sb, allocator)
	k := j + 1
	for k < len(body) {
		c := body[k]
		if c == '"' {
			return strings.to_string(sb), true
		}
		if c == '\\' {
			k += 1
			if k >= len(body) {
				return "", false
			}
			e := body[k]
			switch e {
			case '"':
				strings.write_byte(&sb, '"')
			case '\\':
				strings.write_byte(&sb, '\\')
			case '/':
				strings.write_byte(&sb, '/')
			case 'n':
				strings.write_byte(&sb, '\n')
			case 'r':
				strings.write_byte(&sb, '\r')
			case 't':
				strings.write_byte(&sb, '\t')
			case 'u':
				if k + 4 >= len(body) {
					return "", false
				}
				n, ok := strconv.parse_u64_of_base(body[k + 1 : k + 5], 16)
				if !ok {
					return "", false
				}
				enc, enclen := utf8.encode_rune(rune(n))
			strings.write_string(&sb, string(enc[:enclen]))
				k += 4
			case:
				return "", false
			}
		} else {
			strings.write_byte(&sb, c)
		}
		k += 1
	}
	return "", false
}

is_json_object :: proc(body: string) -> bool {
	t := strings.trim_space(body)
	return len(t) >= 2 && t[0] == '{' && t[len(t) - 1] == '}'
}

serve_conn :: proc(sock: net.TCP_Socket) {
	// Per-connection scratch is bounded: the arena holds at most one
	// request's worth (head + response, <64KB typical) and is reset every
	// iteration. buf and request bodies live on the heap so the reset
	// cannot invalidate them.
	backing, berr := make([]u8, 256 * mem.Kilobyte)
	if berr != nil {
		return
	}
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	alloc := mem.arena_allocator(&arena)
	buf := make([dynamic]u8, context.allocator)
	defer delete(buf)
	for {
		n, ok := read_head(sock, &buf)
		if !ok {
			break
		}
		head := string(buf[:n])
		// Body for POST /posts only, gated on content-length (unknown-length
		// reads would block forever; other routes ignore the body).
		body := ""
		b: []u8 = nil
		{
			method_end := strings.index_byte(head, ' ')
			target_end := -1
			if method_end >= 0 {
				if sp := strings.index_byte(head[method_end + 1 :], ' '); sp >= 0 {
					target_end = method_end + 1 + sp
				}
			}
			target := ""
			if method_end >= 0 && target_end > method_end {
				target = head[method_end + 1 : target_end]
				if q := strings.index_byte(target, '?'); q >= 0 {
					target = target[:q]
				}
			}
			want_body := len(head) >= 4 && head[:4] == "POST" && target == "/posts"
			if cl, has_cl := get_header(head, "content-length"); want_body && has_cl {
				if mblen, conv_ok := strconv.parse_int(cl); conv_ok && mblen > 0 {
					if mblen > 1 << 20 {
						break // absurd body: close rather than blow the arena
					}
					b = make([]u8, mblen, context.allocator)
					// read_head may already hold body bytes past the header.
					buffered := buf[n:]
					n0 := min(len(buffered), mblen)
					copy(b, buffered[:n0])
					if !read_exactly(sock, b[n0:]) {
						delete(b)
						b = nil
						break
					}
					body = string(b)
				}
			}
		}
		keep := handle_one(sock, head, body, alloc)
		if b != nil {
			delete(b)
			b = nil
		}
		mem.arena_free_all(&arena)
		// Reset buffer but keep any pipelined bytes (none expected).
		clear(&buf)
		if !keep {
			break
		}
	}
	net.close(sock)
}

handle_conn :: proc(data: rawptr) {
	box := cast(^net.TCP_Socket)data
	sock := box^
	free(box)
	serve_conn(sock)
}

main :: proc() {
	path := os.get_env("XITDB_PATH", context.allocator)
	if len(path) == 0 {
		path = "feed.xitdb"
	}
	g_secret = os.get_env("JWT_SECRET", context.allocator)
	if len(g_secret) == 0 {
		g_secret = "twelve-dollar-challenge"
	}
	host := os.get_env("HOST", context.allocator)
	if len(host) == 0 {
		host = "127.0.0.1"
	}
	port := 3000
	if ps := os.get_env("PORT", context.allocator); len(ps) > 0 {
		if p, ok := strconv.parse_int(ps); ok {
			port = p
		}
	}
	st, ok := open_store(context.allocator, path, g_secret)
	if !ok {
		fmt.println("open failed:", path)
		os.exit(1)
	}
	g_store = st
	ep, epok := net.parse_endpoint(fmt.tprintf("%s:%d", host, port))
	if !epok {
		fmt.println("bad endpoint")
		os.exit(1)
	}
	sock, lerr := net.listen_tcp(ep)
	if lerr != nil {
		fmt.println("listen failed:", lerr)
		os.exit(1)
	}
	fmt.printf("serving %s on http://%s:%d\n", path, host, port)
	for {
		client, _, aerr := net.accept_tcp(sock)
		if aerr != nil {
			continue
		}
		box := new(net.TCP_Socket)
		box^ = client
		t := thread.create_and_start_with_data(box, handle_conn, self_cleanup = true)
		_ = t
	}
}
