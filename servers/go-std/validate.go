package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/golang-jwt/jwt/v5"
)

func feedKey(createdAt string, id uint64) string {
	return fmt.Sprintf("%s\x00%010d", createdAt, id)
}

func validPostID(s string) (uint64, bool) {
	if s == "" {
		return 0, false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseUint(s, 10, 64)
	if err != nil || n < 1 {
		return 0, false
	}
	return n, true
}

func trimBody(body string) (string, string) {
	trimmed := strings.TrimSpace(body)
	if trimmed == "" {
		return "", "body is required"
	}
	if utf8.RuneCountInString(trimmed) > 500 {
		return "", "body must be at most 500 characters"
	}
	return trimmed, ""
}

type feedClaims struct {
	Sub      string  `json:"sub"`
	Username *string `json:"username"`
	jwt.RegisteredClaims
}

func verifyJWT(token, secret string) (uint64, string, string) {
	var claims feedClaims
	parsed, err := jwt.ParseWithClaims(token, &claims,
		func(*jwt.Token) (any, error) { return []byte(secret), nil },
		jwt.WithValidMethods([]string{"HS256"}),
		jwt.WithLeeway(60*time.Second))
	if err != nil || !parsed.Valid {
		return 0, "", "invalid or expired token"
	}
	if claims.Sub == "" {
		return 0, "", "invalid token payload"
	}
	for i := 0; i < len(claims.Sub); i++ {
		if claims.Sub[i] < '0' || claims.Sub[i] > '9' {
			return 0, "", "invalid token payload"
		}
	}
	id, err := strconv.ParseUint(claims.Sub, 10, 64)
	if err != nil || id < 1 {
		return 0, "", "invalid token payload"
	}
	if claims.Username == nil {
		return 0, "", "invalid token payload"
	}
	return id, *claims.Username, ""
}
