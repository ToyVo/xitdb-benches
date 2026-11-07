(ns store
  (:require [xitdb.db :as xdb]
            [xitdb.sorted :as xs]
            [cheshire.core :as json]
            [validate :refer [feed-key]])
  (:import [xitdb.db XITDBDatabase]
           [io.github.radarroark.xitdb Database Core]))

(defn open-store
  "Opens path (or :memory). Existing files decide their own mode;
  the canonical seed opens as string-key :compat."
  [path]
  (xdb/xit-db path))

(defn- sync! [db]
  ;; commitRoot syncs data but not the header write: without this,
  ;; a 201 could vanish on crash.
  (.sync ^Core (.-core ^Database (.-rwdb ^XITDBDatabase db))))

(defn health? [db]
  (try (do @db true)
       (catch Throwable _ false)))

(defn- ->post [m]
  (when m
    {:id         (get m "id")
     :body       (get m "body")
     :created-at (get m "created_at")
     :author     (get m "author")
     :like-count (get m "like_count")}))

(defn get-post [db id-str]
  (->post (get-in @db ["posts" (str id-str)])))

(defn get-feed [db]
  (let [feed (get @db "feed")]
    (if (nil? feed)
      []
      (let [n (count feed)
        start (max 0 (- n 20))]
    (into []
            (comp (map second)
                  (map #(get-post db %))
                  (remove nil?))
            (rseq (vec (xs/page feed start 20))))))))

(defn- now-z []
  (.format (java.time.format.DateTimeFormatter/ofPattern "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
           (java.time.ZonedDateTime/now java.time.ZoneOffset/UTC)))

(defn create-post! [db username body]
  (let [created (atom nil)]
    (swap! db
           (fn [m]
             (let [next-id (long (get-in m ["meta" "next_post_id"] 1))
                   id-str (str next-id)
                   created-at (now-z)
                   post {"id" next-id "body" body "created_at" created-at
                         "author" username "like_count" 0}
                   ;; Fresh DBs have no feed collection; assoc-in would make it
                   ;; a hash map. Bootstrap a Clojure sorted-map, which the
                   ;; engine persists as an on-disk sorted collection.
                   m (if (nil? (get m "feed")) (assoc m "feed" (sorted-map)) m)]
               (reset! created {:id next-id :body body :created-at created-at
                                :author username :like-count 0})
               (-> m
                   (assoc-in ["posts" id-str] post)
                   (assoc-in ["feed" (feed-key created-at next-id)] id-str)
                   (assoc-in ["likes" id-str] #{})
                   (assoc-in ["meta" "next_post_id"] (inc next-id))))))
    (sync! db)
    @created))

(defn like-post! [db id-str user-str]
  (let [id-str (str id-str)
        user-str (str user-str)]
    (if (nil? (get-in @db ["posts" id-str]))
      nil
      (if (contains? (get-in @db ["likes" id-str] #{}) user-str)
        {:already true}
        (do
          (swap! db
                 (fn [m]
                   (let [n (long (get-in m ["posts" id-str "like_count"] 0))]
                     (-> m
                         (assoc-in ["likes" id-str]
                                   (conj (get-in m ["likes" id-str] #{}) user-str))
                         (assoc-in ["posts" id-str "like_count"] (inc n))))))
          (sync! db)
          {:already false})))))

(defn post->json [p]
  (str "{\"id\":" (:id p)
       ",\"body\":" (json/generate-string (:body p))
       ",\"created_at\":" (json/generate-string (:created-at p))
       ",\"author\":" (json/generate-string (:author p))
       ",\"like_count\":" (:like-count p) "}"))
