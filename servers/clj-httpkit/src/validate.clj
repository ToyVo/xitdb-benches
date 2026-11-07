(ns validate
  (:require [clojure.string :as str])
  (:import [java.math BigInteger]))

(def max-u64 (BigInteger. "18446744073709551615"))

(defn feed-key [created-at id]
  (str created-at (char 0) (format "%010d" id)))

(defn valid-post-id
  "All-digit string in [1, 2^64-1] (full u64 like Rust/Go/Zig; miss -> 404),
  else nil."
  [s]
  (when (and (string? s) (re-matches #"\d+" s))
    (let [n (BigInteger. ^String s)]
      (when (and (pos? n) (<= (.compareTo n max-u64) 0))
        n))))

(defn trim-body
  "Returns [true trimmed] or [false message]. .length is UTF-16 units,
  exactly the upstream reference semantics."
  [b]
  (if-not (string? b)
    [false "body is required"]
    (let [t (str/trim b)]
      (cond
        (empty? t) [false "body is required"]
        (> (.length ^String t) 500) [false "body must be at most 500 characters"]
        :else [true t]))))
