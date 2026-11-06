package main

import (
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func TestFeedKey(t *testing.T) {
	if got := feedKey("2025-01-01T00:00:00.000Z", 7); got != "2025-01-01T00:00:00.000Z\x000000000007" {
		t.Fatalf("bad feedKey %q", got)
	}
	if !(feedKey("2025-01-01T00:00:00.000Z", 7) < feedKey("2025-01-01T00:00:00.000Z", 8)) {
		t.Fatal("feedKey ordering broken")
	}
}

func TestValidPostID(t *testing.T) {
	cases := []struct {
		in   string
		want uint64
		ok   bool
	}{
		{"1", 1, true},
		{"999999999", 999999999, true},
		{"0", 0, false},
		{"-1", 0, false},
		{"abc", 0, false},
		{"1.5", 0, false},
		{"", 0, false},
		{"18446744073709551616", 0, false}, // 2^64, overflow_rejected
	}
	for _, c := range cases {
		got, ok := validPostID(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("validPostID(%q) = (%d,%v), want (%d,%v)", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestTrimBody(t *testing.T) {
	if got, msg := trimBody("  hi "); got != "hi" || msg != "" {
		t.Errorf("trimBody padded = (%q,%q)", got, msg)
	}
	if _, msg := trimBody("   "); msg != "body is required" {
		t.Errorf("whitespace msg = %q", msg)
	}
	if _, msg := trimBody(strings.Repeat("a", 501)); msg != "body must be at most 500 characters" {
		t.Errorf("501 msg = %q", msg)
	}
	if got, msg := trimBody(strings.Repeat("b", 500)); got != strings.Repeat("b", 500) || msg != "" {
		t.Errorf("500 ok = (%d,%q)", len(got), msg)
	}
	if got, msg := trimBody(strings.Repeat("é", 500)); msg != "" || len([]rune(got)) != 500 {
		t.Errorf("multibyte_counts_runes failed: (%d runes,%q)", len([]rune(got)), msg)
	}
}

func signForTest(secret string, claims jwt.MapClaims) string {
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	s, err := tok.SignedString([]byte(secret))
	if err != nil {
		panic("test sign failed: " + err.Error())
	}
	return s
}

func TestVerifyJWT(t *testing.T) {
	secret := "twelve-dollar-challenge"
	now := time.Now().Unix()
	good := signForTest(secret, jwt.MapClaims{"sub": "1", "username": "alice", "iat": now, "exp": now + 3600})
	if id, name, msg := verifyJWT(good, secret); id != 1 || name != "alice" || msg != "" {
		t.Errorf("good = (%d,%q,%q)", id, name, msg)
	}
	for name, tok := range map[string]string{
		"bad-sig":  signForTest("wrong-secret", jwt.MapClaims{"sub": "1", "username": "alice", "iat": now, "exp": now + 3600}),
		"expired":  signForTest(secret, jwt.MapClaims{"sub": "1", "username": "alice", "iat": now - 7200, "exp": now - 3600}),
		"garbage":  "abc",
		"alg-none": "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiIxIiwidXNlcm5hbWUiOiJhbGljZSIsImlhdCI6MTc2MjgzNjkwMCwiZXhwIjoxNzYyODQwNTAwfQ.",
	} {
		if _, _, msg := verifyJWT(tok, secret); msg != "invalid or expired token" {
			t.Errorf("%s msg = %q", name, msg)
		}
	}
	badSub := signForTest(secret, jwt.MapClaims{"sub": "abc", "username": "alice", "iat": now, "exp": now + 3600})
	if _, _, msg := verifyJWT(badSub, secret); msg != "invalid token payload" {
		t.Errorf("bad-sub msg = %q", msg)
	}
	noName := signForTest(secret, jwt.MapClaims{"sub": "1", "iat": now, "exp": now + 3600})
	if _, _, msg := verifyJWT(noName, secret); msg != "invalid token payload" {
		t.Errorf("no-name msg = %q", msg)
	}
	// leeway_parity with the Rust reference (jsonwebtoken default 60s)
	justExpired := signForTest(secret, jwt.MapClaims{"sub": "1", "username": "alice", "iat": now - 3600, "exp": now - 30})
	if id, name, msg := verifyJWT(justExpired, secret); id != 1 || name != "alice" || msg != "" {
		t.Errorf("leeway = (%d,%q,%q)", id, name, msg)
	}
}
