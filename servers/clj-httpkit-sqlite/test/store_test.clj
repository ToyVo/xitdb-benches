(ns store-test
  (:require [clojure.test :refer [deftest is]]
            [cheshire.core :as json]
            [clojure.java.jdbc :as jdbc]
            [store :refer [open-store health? get-post get-feed
                           create-post! like-post! post->json]])
  (:import [java.nio.file Files]
           [java.nio.file.attribute FileAttribute]
           [java.sql Connection]))

(defn- seed-alice! [db]
  (jdbc/execute! {:connection db}
                 ["INSERT INTO users(id,username,created_at) VALUES(7,'alice','2025-01-01T00:00:00.000Z')"]))

(deftest round-trip-test
  (with-open [db (open-store :memory)]
    (seed-alice! db)
    (let [p (create-post! db "alice" "hi")]
      (is (= 1 (:id p)))
      (is (= "hi" (:body p)))
      (is (= "alice" (:author p)))
      (is (= 0 (:like-count p)))
      (is (re-matches #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z" (:created-at p)))
      (is (= p (get-post db "1")))
      (is (nil? (get-post db "999")))
      (create-post! db "alice" "second")
      (is (= [2 1] (mapv :id (get-feed db)))))))

(deftest like-idempotent-test
  (with-open [db (open-store :memory)]
    (seed-alice! db)
    (create-post! db "alice" "x")
    (is (= {:already false} (like-post! db "1" "7")))
    (is (= {:already true} (like-post! db "1" "7")))
    (is (= 1 (:like-count (get-post db "1"))))
    (is (nil? (like-post! db "999" "7")))))

(deftest missing-keys-test
  (with-open [db (open-store :memory)]
    (is (nil? (get-post db "12345")))
    (is (nil? (like-post! db "12345" "9")))
    (is (= [] (get-feed db)))
    (is (true? (health? db)))))

(deftest feed-window-test
  (with-open [db (open-store :memory)]
    (jdbc/execute! {:connection db}
                   ["INSERT INTO users(id,username,created_at) VALUES(9,'u','2025-01-01T00:00:00.000Z')"])
    (dotimes [i 25] (create-post! db "u" (str "post " i)))
    (let [feed (get-feed db)]
      (is (= 20 (count feed)))
      (is (= (range 25 5 -1) (mapv :id feed))))))

(deftest json-str-test
  (is (= "\"b\"" (store/json-str "b")))
  (is (= "\"a\\\"b\\\\c\"" (store/json-str "a\"b\\c")))
  (is (= "\"x\\u001fy\"" (store/json-str (str "x" (char 31) "y"))))
  (is (= "\"caf\u00e9 \u2713\"" (store/json-str "caf\u00e9 \u2713")))
  (is (= "q\"q"
         (get (json/parse-string
               (store/post->json {:id 1 :body "q\"q" :created-at "c" :author "a" :like-count 0}))
              "body"))))

(deftest durability-test
  (let [path (str (Files/createTempFile "xb-clj-" ".xitdb" (into-array FileAttribute [])))]
    (with-open [db (open-store path)]
      (seed-alice! db)
      (create-post! db "alice" "durable?"))
    (with-open [db (open-store path)]
      (is (= "durable?" (:body (get-post db "1")))))))

(deftest post-json-test
  (is (= "{\"id\":1,\"body\":\"b\",\"created_at\":\"c\",\"author\":\"a\",\"like_count\":2}"
         (post->json {:id 1 :body "b" :created-at "c" :author "a" :like-count 2}))))

(deftest schema-pins-upstream-test
  ;; store.clj carries a verbatim copy of seed/schema.sql; fail loudly on drift.
  (let [norm (fn [x] (-> x
                         (.replaceAll "--[^\n]*" "")
                         (.replaceAll "\\s+" " ")
                         (.replaceAll "\\( " "(")
                         (.replaceAll " \\)" ")")
                         (.replaceAll "; " ";")
                         (.trim)))
        vendored (slurp "../../seed/schema.sql")
        inline @#'store/schema-sql]
    (is (= (norm vendored) (norm inline)))))
