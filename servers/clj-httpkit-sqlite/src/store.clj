(ns store
  (:require [clojure.java.jdbc :as jdbc]
            [cheshire.core :as json])
  (:import [java.sql Connection DriverManager]))

;; Verbatim copy of seed/schema.sql (upstream-fixed). A test pins equality
;; so the two cannot drift.
(def ^:private schema-sql
  (str "CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, "
       "created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));"
       "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), "
       "body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500), "
       "created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));"
       "CREATE TABLE likes (user_id INTEGER NOT NULL REFERENCES users(id), "
       "post_id INTEGER NOT NULL REFERENCES posts(id), "
       "created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), "
       "PRIMARY KEY (user_id, post_id));"
       "CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);"
       "CREATE INDEX posts_user_id_idx ON posts (user_id);"
       "CREATE INDEX likes_post_id_idx ON likes (post_id);"))

(defn open-store
  "Opens path (or :memory) as SQLite. Fresh files get upstream schema.sql;
  the returned java.sql.Connection is Closeable (with-open works)."
  [path]
  (let [url (str "jdbc:sqlite:" (if (= path :memory) ":memory:" path))
        ^Connection conn (DriverManager/getConnection url)]
    (when (empty? (jdbc/query {:connection conn}
                              ["SELECT name FROM sqlite_master WHERE type='table' AND name='users'"]))
      (doseq [stmt (.split ^String schema-sql ";")]
        (let [t (.trim stmt)]
          (when (seq t)
            (jdbc/execute! {:connection conn} [t])))))
    conn))

(defn health? [db]
  (try (do (jdbc/query {:connection db} ["SELECT COUNT(*) AS n FROM users"]) true)
       (catch Throwable _ false)))

(def ^:private feed-sql
  (str "SELECT p.id,p.body,p.created_at,u.username,"
       "(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id) AS like_count "
       "FROM posts p JOIN users u ON u.id=p.user_id "
       "ORDER BY p.created_at DESC,p.id DESC LIMIT 20"))

(def ^:private post-sql
  (str "SELECT p.id,p.body,p.created_at,u.username,"
       "(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id) AS like_count "
       "FROM posts p JOIN users u ON u.id=p.user_id WHERE p.id=?"))

(defn- ->post [m]
  (when m
    {:id         (long (:id m))
     :body       (:body m)
     :created-at (:created_at m)
     :author     (:username m)
     :like-count (long (:like_count m))}))

(defn get-post [db id-str]
  (->post (first (jdbc/query {:connection db} [post-sql (Long/parseLong (str id-str))]))))

(defn get-feed [db]
  (mapv ->post (jdbc/query {:connection db} [feed-sql])))

(defn- now-z []
  (.format (java.time.format.DateTimeFormatter/ofPattern "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
           (java.time.ZonedDateTime/now java.time.ZoneOffset/UTC)))

(defn- user-id [db username]
  (:id (first (jdbc/query {:connection db} ["SELECT id FROM users WHERE username=?" username]))))

(defn create-post! [db username body]
  (let [uid (user-id db username)
        created-at (now-z)]
    (when (nil? uid) (throw (ex-info "unknown author" {:username username})))
    (let [id (:id (first (jdbc/query {:connection db}
                                     ["INSERT INTO posts(user_id,body,created_at) VALUES(?,?,?) RETURNING id"
                                      uid body created-at])))]
      {:id (long id) :body body :created-at created-at :author username :like-count 0})))

(defn like-post! [db id-str user-str]
  (let [id-str (str id-str)
        user-str (str user-str)]
    (if (nil? (get-post db id-str))
      nil
      ;; execute! returns [update-count]; 0 means the row already existed.
      (let [counts (jdbc/execute! {:connection db}
                                  ["INSERT OR IGNORE INTO likes(user_id,post_id,created_at) VALUES(?,?,?)"
                                   (Long/parseLong user-str) (Long/parseLong id-str) (now-z)])]
        {:already (zero? (first counts))}))))

(defn json-str
  "Exact JSON string literal: escapes only \" \\ and U+0000-U+001F
  (\\u00XX); everything else passes through as UTF-8. Matches the
  reference servers byte-for-byte on ASCII and round-trips the rest."
  [^String s]
  (let [sb (StringBuilder. (+ 2 (.length s)))]
    (.append sb \")
    (dotimes [i (.length s)]
      (let [c (.charAt s i)]
        (case c
          \" (.append sb "\\\"")
          \\ (.append sb "\\\\")
          \newline (.append sb "\\n")
          \return (.append sb "\\r")
          \tab (.append sb "\\t")
          (if (< (int c) 0x20)
            (.append sb (format "\\u%04x" (int c)))
            (.append sb c)))))
    (.append sb \")
    (str sb)))

(defn post->json [p]
  (str "{\"id\":" (:id p)
       ",\"body\":" (json-str (:body p))
       ",\"created_at\":" (json-str (:created-at p))
       ",\"author\":" (json-str (:author p))
       ",\"like_count\":" (:like-count p) "}"))
