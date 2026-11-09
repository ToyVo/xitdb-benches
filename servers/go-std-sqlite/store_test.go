package main

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func openTestStore(t *testing.T) *Store {
	t.Helper()
	path := filepath.Join(t.TempDir(), "t.db")
	schema, err := os.ReadFile("../../seed/schema.sql")
	if err != nil {
		t.Fatalf("read schema: %v", err)
	}
	st, err := openStore(path, "test-secret")
	if err != nil {
		t.Fatalf("openStore: %v", err)
	}
	t.Cleanup(func() { st.close() })
	if _, err := st.db.Exec(string(schema)); err != nil {
		t.Fatalf("schema: %v", err)
	}
	if _, err := st.db.Exec("INSERT INTO users(id,username,created_at) VALUES(7,'alice','2025-01-01T00:00:00.000Z')"); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	return st
}

func TestStoreRoundTrip(t *testing.T) {
	st := openTestStore(t)
	p, err := st.createPost(7, "alice", "hi")
	if err != nil {
		t.Fatalf("createPost: %v", err)
	}
	if p.ID != 1 || p.Body != "hi" || p.Author != "alice" || p.LikeCount != 0 {
		t.Fatalf("bad created post %+v", p)
	}
	if ok, _ := regexp.MatchString(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$`, p.CreatedAt); !ok {
		t.Fatalf("bad created_at %q", p.CreatedAt)
	}
	got, found, err := st.getPost(1)
	if err != nil || !found {
		t.Fatalf("getPost(1) = %+v,%v,%v", got, found, err)
	}
	if *got != p {
		t.Fatalf("round trip mismatch %+v vs %+v", *got, p)
	}
	if _, found, _ := st.getPost(999); found {
		t.Fatal("getPost(999) found")
	}
	if _, err := st.createPost(7, "alice", "second"); err != nil {
		t.Fatalf("create 2: %v", err)
	}
	feed, err := st.getFeed()
	if err != nil {
		t.Fatalf("getFeed: %v", err)
	}
	if len(feed) != 2 || feed[0].ID != 2 || feed[1].ID != 1 {
		t.Fatalf("feed order wrong %+v", feed)
	}
}

func TestStoreLikeIdempotent(t *testing.T) {
	st := openTestStore(t)
	if _, err := st.createPost(7, "alice", "x"); err != nil {
		t.Fatal(err)
	}
	already, found, err := st.likePost(1, 7)
	if err != nil || already || !found {
		t.Fatalf("first like = %v,%v,%v", already, found, err)
	}
	already, found, err = st.likePost(1, 7)
	if err != nil || !already || !found {
		t.Fatalf("repeat like = %v,%v,%v", already, found, err)
	}
	got, _, _ := st.getPost(1)
	if got.LikeCount != 1 {
		t.Fatalf("like_count = %d, want 1", got.LikeCount)
	}
	if _, found, _ := st.likePost(999, 7); found {
		t.Fatal("likePost(999) found")
	}
}

func TestLikePrimaryKey(t *testing.T) {
	st := openTestStore(t)
	if _, err := st.createPost(7, "alice", "x"); err != nil {
		t.Fatal(err)
	}
	// The PRIMARY KEY (user_id, post_id) is what makes repeat likes a
	// no-op at the engine level; pin the constraint so a schema change
	// fails loudly here instead of silently double-counting.
	if _, err := st.db.Exec("INSERT INTO likes(user_id,post_id,created_at) VALUES(7,1,'2025-01-01T00:00:00.000Z')"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.Exec("INSERT INTO likes(user_id,post_id,created_at) VALUES(7,1,'2025-01-01T00:00:00.000Z')"); err == nil {
		t.Fatal("duplicate like accepted; PRIMARY KEY missing?")
	}
}

func TestMissingKeySemantics(t *testing.T) {
	st := openTestStore(t)
	if _, found, err := st.getPost(12345); err != nil || found {
		t.Fatalf("absent post = %v,%v", found, err)
	}
	if _, found, err := st.likePost(12345, 9); err != nil || found {
		t.Fatalf("absent like = %v,%v", found, err)
	}
	if feed, err := st.getFeed(); err != nil || len(feed) != 0 {
		t.Fatalf("empty feed = %v,%v", feed, err)
	}
	if !st.health() {
		t.Fatal("health false on fresh db")
	}
}
