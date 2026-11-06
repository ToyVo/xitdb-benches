# schema-xitdb (frozen canonical layout, all 7 share)

Root is a `HashMap` with exactly 5 keys: `users`, `posts`, `feed`,
`likes`, `meta`.

- `users`: `HashMap<id_str -> {username, created_at}>`. Write-once at
  seed. Never on hot path (auth uses JWT `username` as-is).
- `posts`: `HashMap<id_str -> post-object HashMap{id:Uint,
  body:String, created_at:String, author:String, like_count:Uint}>`.
  Denormalized: `author` + `like_count` embedded; reads do zero joins.
- `feed`: `SortedMap<feed_key -> post_id_str>` with
  `feed_key = created_at + '\0' + id_padded_10` (`id` zero-padded to
  10 digits). Lexicographic order = `ORDER BY created_at ASC, id ASC`.
  Newest-20 = `count()` → `iter_from_index(count-20)` → 20 forward →
  reverse in memory → 20× `posts.get()`.
- `likes`: `HashMap<post_id_str -> HashSet<user_id_str>>`.
  `POST /:id/like` = one txn: put-if-absent + bump
  `posts[id].like_count` iff inserted. `201 already_liked:false` vs
  `200 already_liked:true`; atomic under the single-writer mutex.
- `meta`: `HashMap{next_post_id:Uint, seed_sha:String}`.
  `POST /posts` = one txn: `id = next_post_id++`,
  `created_at = now_utc_millis_Z`, insert `posts[id]` +
  `feed.put(feed_key)`.

Txn rules: one `run_context` per mutating request; `FileCore`
fsync:true; 201 after commit; reads never hold the writer lock past
the copy. `created_at` format `YYYY-MM-DDTHH:MM:SS.mmmZ` (UTC).
