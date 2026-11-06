package main

import (
	"crypto/sha1"
	"os"
	"path/filepath"
	"regexp"
	"testing"

	xitdb "github.com/xit-vcs/xitdb-go"
)

func testHasher() xitdb.Hasher {
	return xitdb.Hasher{Hash: sha1.New, ID: xitdb.BytesToID([4]byte{'s', 'h', 'a', '1'})}
}

func openTestStore(t *testing.T) *Store {
	t.Helper()
	st, err := openStore(filepath.Join(t.TempDir(), "t.xitdb"), "test-secret")
	if err != nil {
		t.Fatalf("openStore: %v", err)
	}
	t.Cleanup(func() { st.close() })
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

func TestTxnRule(t *testing.T) {
	dir := t.TempDir()
	f, err := os.Create(filepath.Join(dir, "r.xitdb"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	db, err := xitdb.NewDatabase(xitdb.NewCoreFile(f), testHasher())
	if err != nil {
		t.Fatal(err)
	}
	root, err := xitdb.NewWriteHashMap(db.RootCursor())
	if err != nil {
		t.Fatal(err)
	}
	// Unlike Rust (ExpectedTxStart), xitdb-go ALLOWS PutCursor-descend
	// outside a transaction (see ledger ruling). Pin ALLOWED so a future
	// xitdb-go behavior change fails loudly. The planned shape stands
	// anyway: reads via GetCursor, writes inside RunContext.
	if _, err := root.PutCursor("txn-probe"); err != nil {
		t.Fatalf("PutCursor outside txn now errors (%v); revisit the ruling", err)
	}
	if _, err := root.GetCursor("posts"); err != nil {
		t.Fatalf("GetCursor outside txn: %v", err)
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
