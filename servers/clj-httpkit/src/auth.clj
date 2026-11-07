(ns auth
  (:require [buddy.sign.jwt :as jwt])
  (:import [java.math BigInteger]
           [clojure.lang ExceptionInfo]))

(def ^:private max-u64 (BigInteger. "18446744073709551615"))

(defn verify-jwt
  "Returns {:user-id n :username s} or {:error msg} with the spec message."
  [token secret]
  (let [claims (try
                 (jwt/unsign token secret {:alg :hs256 :leeway 60})
                 (catch ExceptionInfo _ ::bad)
                 (catch Exception _ ::bad))]
    (if (= claims ::bad)
      {:error "invalid or expired token"}
      (let [{:keys [sub username]} claims]
        (if (and (string? sub)
                 (re-matches #"\d+" sub)
                 (string? username))
          (let [n (BigInteger. ^String sub)]
            (if (and (pos? n) (<= (.compareTo n max-u64) 0))
              {:user-id n :username username}
              {:error "invalid token payload"}))
          {:error "invalid token payload"})))))
