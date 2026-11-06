package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

var store *Store

func writeJSON(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, body)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, `{"error":"`+msg+`"}`)
}

func bearer(r *http.Request) (string, bool) {
	v := r.Header.Get("Authorization")
	tok, ok := strings.CutPrefix(v, "Bearer ")
	if !ok {
		return "", false
	}
	return tok, true
}

func authed(r *http.Request) (uint64, string, string) {
	tok, ok := bearer(r)
	if !ok {
		return 0, "", "missing bearer token"
	}
	id, name, msg := verifyJWT(tok, store.secret)
	if msg != "" {
		return 0, "", msg
	}
	return id, name, ""
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	if !store.health() {
		writeJSON(w, http.StatusServiceUnavailable,
			`{"status":"degraded","db":"unreachable","error":"read failed"}`)
		return
	}
	uptime := int(time.Since(store.boot).Seconds())
	writeJSON(w, http.StatusOK,
		fmt.Sprintf(`{"status":"ok","db":"ok","uptime_s":%d}`, uptime))
}

func feedHandler(w http.ResponseWriter, _ *http.Request) {
	posts, err := store.getFeed()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal server error")
		return
	}
	var sb strings.Builder
	sb.WriteString(`{"posts":[`)
	for i, p := range posts {
		if i > 0 {
			sb.WriteByte(',')
		}
		sb.WriteString(p.json())
	}
	sb.WriteString(`]}`)
	writeJSON(w, http.StatusOK, sb.String())
}

func getPostHandler(w http.ResponseWriter, r *http.Request) {
	id, ok := validPostID(r.PathValue("id"))
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid post id")
		return
	}
	p, found, err := store.getPost(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if !found {
		writeErr(w, http.StatusNotFound, "post not found")
		return
	}
	writeJSON(w, http.StatusOK, `{"post":`+p.json()+`}`)
}

func createPostHandler(w http.ResponseWriter, r *http.Request) {
	userID, username, authErr := authed(r)
	if authErr != "" {
		writeErr(w, http.StatusUnauthorized, authErr)
		return
	}
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "malformed JSON body")
		return
	}
	var value map[string]any
	if err := json.Unmarshal(raw, &value); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed JSON body")
		return
	}
	bodyRaw, present := value["body"]
	bodyStr, isStr := bodyRaw.(string)
	if !present || !isStr {
		writeErr(w, http.StatusBadRequest, "body is required")
		return
	}
	trimmed, msg := trimBody(bodyStr)
	if msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	p, err := store.createPost(userID, username, trimmed)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal server error")
		return
	}
	writeJSON(w, http.StatusCreated, `{"post":`+p.json()+`}`)
}

func likePostHandler(w http.ResponseWriter, r *http.Request) {
	// Auth first, then id (spec order).
	userID, _, authErr := authed(r)
	if authErr != "" {
		writeErr(w, http.StatusUnauthorized, authErr)
		return
	}
	id, ok := validPostID(r.PathValue("id"))
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid post id")
		return
	}
	already, found, err := store.likePost(id, userID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if !found {
		writeErr(w, http.StatusNotFound, "post not found")
		return
	}
	status := http.StatusCreated
	if already {
		status = http.StatusOK
	}
	writeJSON(w, status, fmt.Sprintf(`{"liked":true,"already_liked":%t,"post_id":%d}`,
		already, id))
}

func notFoundHandler(w http.ResponseWriter, _ *http.Request) {
	writeErr(w, http.StatusNotFound, "not found")
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	path := getenv("XITDB_PATH", "")
	if path == "" && len(os.Args) > 1 {
		path = os.Args[1]
	}
	if path == "" {
		path = "feed.xitdb"
	}
	secret := getenv("JWT_SECRET", "twelve-dollar-challenge")
	host := getenv("HOST", "127.0.0.1")
	port := getenv("PORT", "3000")
	if _, err := strconv.Atoi(port); err != nil {
		fmt.Fprintln(os.Stderr, "bad PORT")
		os.Exit(1)
	}
	st, err := openStore(path, secret)
	if err != nil {
		fmt.Fprintln(os.Stderr, "open:", err)
		os.Exit(1)
	}
	defer st.close()
	store = st

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", healthHandler)
	mux.HandleFunc("GET /feed", feedHandler)
	mux.HandleFunc("GET /posts/{id}", getPostHandler)
	mux.HandleFunc("POST /posts", createPostHandler)
	mux.HandleFunc("POST /posts/{id}/like", likePostHandler)
	mux.HandleFunc("/", notFoundHandler)

	addr := host + ":" + port
	fmt.Printf("serving %s on http://%s\n", path, addr)
	srv := &http.Server{Addr: addr, Handler: mux, IdleTimeout: 70 * time.Second}
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		fmt.Fprintln(os.Stderr, "serve:", err)
		os.Exit(1)
	}
}
