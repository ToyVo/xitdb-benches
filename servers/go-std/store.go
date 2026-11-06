package main

import (
	"bytes"
	"crypto/sha1"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	xitdb "github.com/xit-vcs/xitdb-go"
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
	db     *xitdb.Database
	file   *os.File
	secret string
	boot   time.Time
}

func testHasherForStore() xitdb.Hasher {
	return xitdb.Hasher{Hash: sha1.New, ID: xitdb.BytesToID([4]byte{'s', 'h', 'a', '1'})}
}

func openStore(path, secret string) (*Store, error) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0644)
	if err != nil {
		return nil, err
	}
	db, err := xitdb.NewDatabase(xitdb.NewCoreFile(f), testHasherForStore())
	if err != nil {
		f.Close()
		return nil, err
	}
	return &Store{db: db, file: f, secret: secret, boot: time.Now()}, nil
}

func (s *Store) close() error {
	return s.file.Close()
}

func (s *Store) health() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.CommittedSize()
	return err == nil
}

func getText(m *xitdb.ReadHashMap, key string) (string, error) {
	c, err := m.GetCursor(key)
	if err != nil {
		return "", err
	}
	if c == nil {
		return "", fmt.Errorf("corrupt post: missing %s", key)
	}
	raw, err := c.ReadBytes(maxRead)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func readPost(m *xitdb.ReadHashMap, id string) (*post, error) {
	c, err := m.GetCursor(id)
	if err != nil {
		return nil, err
	}
	if c == nil {
		return nil, errNotFound
	}
	pm, err := xitdb.NewReadHashMap(c)
	if err != nil {
		return nil, err
	}
	idC, err := pm.GetCursor("id")
	if err != nil {
		return nil, err
	}
	if idC == nil {
		return nil, errors.New("corrupt post: missing id")
	}
	num, err := idC.ReadUint()
	if err != nil {
		return nil, err
	}
	body, err := getText(pm, "body")
	if err != nil {
		return nil, err
	}
	created, err := getText(pm, "created_at")
	if err != nil {
		return nil, err
	}
	author, err := getText(pm, "author")
	if err != nil {
		return nil, err
	}
	lcC, err := pm.GetCursor("like_count")
	if err != nil {
		return nil, err
	}
	if lcC == nil {
		return nil, errors.New("corrupt post: missing like_count")
	}
	lc, err := lcC.ReadUint()
	if err != nil {
		return nil, err
	}
	return &post{ID: num, Body: body, CreatedAt: created, Author: author, LikeCount: lc}, nil
}

func (s *Store) getPost(id uint64) (*post, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	root, err := xitdb.NewWriteHashMap(s.db.RootCursor())
	if err != nil {
		return nil, false, err
	}
	pc, err := root.GetCursor("posts")
	if err != nil {
		return nil, false, err
	}
	if pc == nil {
		return nil, false, nil
	}
	posts, err := xitdb.NewReadHashMap(pc)
	if err != nil {
		return nil, false, err
	}
	p, err := readPost(posts, strconv.FormatUint(id, 10))
	if err == errNotFound {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return p, true, nil
}

func (s *Store) getFeed() ([]post, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	root, err := xitdb.NewWriteHashMap(s.db.RootCursor())
	if err != nil {
		return nil, err
	}
	fc, err := root.GetCursor("feed")
	if err != nil {
		return nil, err
	}
	if fc == nil {
		return []post{}, nil
	}
	feed, err := xitdb.NewReadSortedMap(fc)
	if err != nil {
		return nil, err
	}
	count, err := feed.Count()
	if err != nil {
		return nil, err
	}
	start := count - 20
	if start < 0 {
		start = 0
	}
	var ids []string
	for i := start; i < count; i++ {
		kv, err := feed.GetIndexKeyValuePair(i)
		if err != nil {
			return nil, err
		}
		if kv == nil {
			continue
		}
		raw, err := kv.ValueCursor.ReadBytes(maxRead)
		if err != nil {
			return nil, err
		}
		ids = append(ids, string(raw))
	}
	pc, err := root.GetCursor("posts")
	if err != nil {
		return nil, err
	}
	if pc == nil {
		return []post{}, nil
	}
	posts, err := xitdb.NewReadHashMap(pc)
	if err != nil {
		return nil, err
	}
	out := []post{}
	for _, id := range ids {
		p, err := readPost(posts, id)
		if err == errNotFound {
			continue
		}
		if err != nil {
			return nil, err
		}
		out = append(out, *p)
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, nil
}

func (s *Store) createPost(userID uint64, username, body string) (post, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var created post
	err := s.db.RunContext(func(w *xitdb.WriteCursor) error {
		root, err := xitdb.NewWriteHashMap(w)
		if err != nil {
			return err
		}
		metaC, err := root.PutCursor("meta")
		if err != nil {
			return err
		}
		meta, err := xitdb.NewWriteHashMap(metaC)
		if err != nil {
			return err
		}
		next := uint64(1)
		if c, err := meta.GetCursor("next_post_id"); err != nil {
			return err
		} else if c != nil {
			if next, err = c.ReadUint(); err != nil {
				return err
			}
		}
		createdAt := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
		postsC, err := root.PutCursor("posts")
		if err != nil {
			return err
		}
		posts, err := xitdb.NewWriteHashMap(postsC)
		if err != nil {
			return err
		}
		idStr := strconv.FormatUint(next, 10)
		pc, err := posts.PutCursor(idStr)
		if err != nil {
			return err
		}
		pm, err := xitdb.NewWriteHashMap(pc)
		if err != nil {
			return err
		}
		if err := pm.Put("id", xitdb.NewUint(next)); err != nil {
			return err
		}
		if err := pm.Put("body", xitdb.NewString(body)); err != nil {
			return err
		}
		if err := pm.Put("created_at", xitdb.NewString(createdAt)); err != nil {
			return err
		}
		if err := pm.Put("author", xitdb.NewString(username)); err != nil {
			return err
		}
		if err := pm.Put("like_count", xitdb.NewUint(0)); err != nil {
			return err
		}
		feedC, err := root.PutCursor("feed")
		if err != nil {
			return err
		}
		feed, err := xitdb.NewWriteSortedMap(feedC)
		if err != nil {
			return err
		}
		if err := feed.Put(feedKey(createdAt, next), xitdb.NewString(idStr)); err != nil {
			return err
		}
		likesC, err := root.PutCursor("likes")
		if err != nil {
			return err
		}
		likes, err := xitdb.NewWriteHashMap(likesC)
		if err != nil {
			return err
		}
		setC, err := likes.PutCursor(idStr)
		if err != nil {
			return err
		}
		if _, err := xitdb.NewWriteHashSet(setC); err != nil {
			return err
		}
		if err := meta.Put("next_post_id", xitdb.NewUint(next+1)); err != nil {
			return err
		}
		created = post{ID: next, Body: body, CreatedAt: createdAt, Author: username}
		_ = userID
		return nil
	})
	return created, err
}

func (s *Store) likePost(id, user uint64) (already bool, found bool, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	idStr := strconv.FormatUint(id, 10)
	userStr := strconv.FormatUint(user, 10)
	err = s.db.RunContext(func(w *xitdb.WriteCursor) error {
		root, err := xitdb.NewWriteHashMap(w)
		if err != nil {
			return err
		}
		postsC, err := root.PutCursor("posts")
		if err != nil {
			return err
		}
		posts, err := xitdb.NewWriteHashMap(postsC)
		if err != nil {
			return err
		}
		if _, err := readPost(posts.ReadHashMap, idStr); err == errNotFound {
			return nil
		} else if err != nil {
			return err
		}
		found = true
		likesC, err := root.PutCursor("likes")
		if err != nil {
			return err
		}
		likes, err := xitdb.NewWriteHashMap(likesC)
		if err != nil {
			return err
		}
		setC, err := likes.PutCursor(idStr)
		if err != nil {
			return err
		}
		set, err := xitdb.NewWriteHashSet(setC)
		if err != nil {
			return err
		}
		if c, err := set.GetCursor(userStr); err != nil {
			return err
		} else if c != nil {
			already = true
			return nil
		}
		if err := set.Put(userStr); err != nil {
			return err
		}
		pc, err := posts.PutCursor(idStr)
		if err != nil {
			return err
		}
		pm, err := xitdb.NewWriteHashMap(pc)
		if err != nil {
			return err
		}
		lcC, err := pm.GetCursor("like_count")
		if err != nil {
			return err
		}
		if lcC == nil {
			return errors.New("corrupt post: missing like_count")
		}
		cur, err := lcC.ReadUint()
		if err != nil {
			return err
		}
		if err := pm.Put("like_count", xitdb.NewUint(cur+1)); err != nil {
			return err
		}
		return nil
	})
	return already, found, err
}
