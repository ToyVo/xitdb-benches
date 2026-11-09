package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

const maxRead = 8 * 1024

var errNotFound = errors.New("not found")

type post struct {
	ID        uint64
	Body      string
	CreatedAt string
	Author    string
	LikeCount uint64
}

func jstr(s string) string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(s); err != nil {
		return `""`
	}
	return strings.TrimRight(buf.String(), "\n")
}

func (p post) json() string {
	return fmt.Sprintf(`{"id":%d,"body":%s,"created_at":%s,"author":%s,"like_count":%d}`,
		p.ID, jstr(p.Body), jstr(p.CreatedAt), jstr(p.Author), p.LikeCount)
}

type Store struct {
	mu     sync.Mutex
	db     *sql.DB
	secret string
	boot   time.Time
}

func openStore(path, secret string) (*Store, error) {
	db, err := sql.Open("sqlite3", path+"?cache=shared&_pragma=busy_timeout%285000%29")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	return &Store{db: db, secret: secret, boot: time.Now()}, nil
}

func (s *Store) close() error {
	return s.db.Close()
}

func (s *Store) health() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	var n int64
	return s.db.QueryRow("SELECT COUNT(*) FROM users").Scan(&n) == nil
}

const feedSQL = `SELECT p.id,p.body,p.created_at,u.username,(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id) FROM posts p JOIN users u ON u.id=p.user_id ORDER BY p.created_at DESC,p.id DESC LIMIT 20`
const postSQL = `SELECT p.id,p.body,p.created_at,u.username,(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id) FROM posts p JOIN users u ON u.id=p.user_id WHERE p.id=?`

func scanPost(row *sql.Row, p *post) error {
	var id, lc int64
	if err := row.Scan(&id, &p.Body, &p.CreatedAt, &p.Author, &lc); err != nil {
		return err
	}
	p.ID, p.LikeCount = uint64(id), uint64(lc)
	return nil
}

func (s *Store) getPost(id uint64) (*post, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var p post
	if err := scanPost(s.db.QueryRow(postSQL, id), &p); err != nil {
		if err == sql.ErrNoRows {
			return nil, false, nil
		}
		return nil, false, err
	}
	return &p, true, nil
}

func (s *Store) getFeed() ([]post, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(feedSQL)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []post{}
	for rows.Next() {
		var p post
		var id, lc int64
		if err := rows.Scan(&id, &p.Body, &p.CreatedAt, &p.Author, &lc); err != nil {
			return nil, err
		}
		p.ID, p.LikeCount = uint64(id), uint64(lc)
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) createPost(userID uint64, username, body string) (post, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var created post
	createdAt := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	var maxID int64
	if err := s.db.QueryRow("SELECT COALESCE(MAX(id),0) FROM posts").Scan(&maxID); err != nil {
		return created, err
	}
	created = post{ID: uint64(maxID) + 1, Body: body, CreatedAt: createdAt, Author: username}
	if _, err := s.db.Exec("INSERT INTO posts(user_id,body,created_at) VALUES(?,?,?)", userID, body, createdAt); err != nil {
		return created, err
	}
	return created, nil
}

func (s *Store) likePost(id, user uint64) (already bool, found bool, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var exists bool
	if err = s.db.QueryRow("SELECT EXISTS(SELECT 1 FROM posts WHERE id=?)", id).Scan(&exists); err != nil {
		return false, false, err
	}
	if !exists {
		return false, false, nil
	}
	createdAt := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	res, err := s.db.Exec("INSERT OR IGNORE INTO likes(user_id,post_id,created_at) VALUES(?,?,?)", user, id, createdAt)
	if err != nil {
		return false, true, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, true, err
	}
	return n == 0, true, nil
}
