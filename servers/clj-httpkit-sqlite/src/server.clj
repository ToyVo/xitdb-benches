(ns server
  (:require [org.httpkit.server :as hk]
            [cheshire.core :as json]
            [clojure.string :as str]
            [validate :refer [valid-post-id trim-body]]
            [auth :refer [verify-jwt]]
            [store :as st])
  (:gen-class))

(def boot-ms (System/currentTimeMillis))

(def db-path (or (System/getenv "XITDB_PATH") "feed.db"))
(def secret (or (System/getenv "JWT_SECRET") "twelve-dollar-challenge"))
(def host (or (System/getenv "HOST") "127.0.0.1"))
(def port (try (Integer/parseInt (or (System/getenv "PORT") "3000"))
               (catch NumberFormatException _ 3000)))

(def db (st/open-store db-path))

(defn json-resp [status body]
  {:status status :headers {"Content-Type" "application/json"} :body body})

(defn err [status msg]
  (json-resp status (str "{\"error\":\"" msg "\"}")))

(defn bearer [req]
  (let [v (get-in req [:headers "authorization"])]
    (when (and (string? v) (str/starts-with? v "Bearer "))
      (subs v 7))))

(defn authed [req]
  (if-let [tok (bearer req)]
    (let [r (verify-jwt tok secret)]
      (if (:error r) {:error (:error r)} r))
    {:error "missing bearer token"}))

(defn post-route [uri]
  (second (re-matches #"^/posts/([^/]+)$" uri)))

(defn like-route [uri]
  (second (re-matches #"^/posts/(.+)/like$" uri)))

(defn app [req]
  (let [method (:request-method req)
        uri (:uri req)]
    (cond
      (and (= :get method) (= "/health" uri))
      (if (st/health? db)
        (json-resp 200 (str "{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":"
                            (quot (- (System/currentTimeMillis) boot-ms) 1000) "}"))
        (json-resp 503 "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"read failed\"}"))

      (and (= :get method) (= "/feed" uri))
      (try
        (let [posts (st/get-feed db)]
          (json-resp 200 (str "{\"posts\":[" (str/join "," (map st/post->json posts)) "]}")))
        (catch Throwable _ (err 500 "internal server error")))

      (and (= :get method) (post-route uri))
      (let [id (valid-post-id (post-route uri))]
        (if (nil? id)
          (err 400 "invalid post id")
          (try
            (if-let [p (st/get-post db (str id))]
              (json-resp 200 (str "{\"post\":" (st/post->json p) "}"))
              (err 404 "post not found"))
            (catch Throwable _ (err 500 "internal server error")))))

      (and (= :post method) (= "/posts" uri))
      (let [a (authed req)]
        (if (:error a)
          (err 401 (:error a))
          (let [raw (try (slurp (:body req)) (catch Throwable _ ::bad))]
            (if (= raw ::bad)
              (err 400 "malformed JSON body")
              (let [parsed (try (json/parse-string raw) (catch Throwable _ ::bad))]
                (if (= parsed ::bad)
                  (err 400 "malformed JSON body")
                  (let [b (get parsed "body")
                        [ok v] (trim-body b)]
                    (if-not ok
                      (err 400 v)
                      (try
                        (let [p (st/create-post! db (:username a) v)]
                          (json-resp 201 (str "{\"post\":" (st/post->json p) "}")))
                        (catch Throwable _ (err 500 "internal server error")))))))))))

      (and (= :post method) (like-route uri))
      (let [a (authed req)]
        (if (:error a)
          (err 401 (:error a))
          (let [id-raw (like-route uri)]
            (if (str/includes? id-raw "/")
              (err 404 "not found")
              (let [id (valid-post-id id-raw)]
                (if (nil? id)
                  (err 400 "invalid post id")
                  (try
                    (let [r (st/like-post! db (str id) (str (:user-id a)))]
                      (if (nil? r)
                        (err 404 "post not found")
                        (json-resp (if (:already r) 200 201)
                                   (str "{\"liked\":true,\"already_liked\":" (:already r)
                                        ",\"post_id\":" id "}"))))
                    (catch Throwable _ (err 500 "internal server error")))))))))

      :else (err 404 "not found"))))

(defn -main [& _args]
  (hk/run-server #'app {:ip host :port port})
  (println (str "serving " db-path " on http://" host ":" port))
  @(promise))
