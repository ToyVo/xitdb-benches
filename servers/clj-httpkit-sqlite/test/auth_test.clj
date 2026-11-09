(ns auth-test
  (:require [clojure.test :refer [deftest is]]
            [buddy.sign.jwt :as jwt]
            [auth :refer [verify-jwt]]))

(def secret "twelve-dollar-challenge")

(defn sign [payload & [s]]
  (jwt/sign payload (or s secret) {:alg :hs256}))

(defn now [] (quot (System/currentTimeMillis) 1000))

(deftest good-token-test
  (let [n (now)
        tok (sign {:sub "1" :username "alice" :iat n :exp (+ n 3600)})]
    (is (= {:user-id 1 :username "alice"} (verify-jwt tok secret)))))

(deftest bad-signature-test
  (let [n (now)]
    (doseq [[label tok] {"bad-sig" (sign {:sub "1" :username "alice" :iat n :exp (+ n 3600)} "wrong-secret")
                         "expired" (sign {:sub "1" :username "alice" :iat (- n 7200) :exp (- n 3600)})
                         "garbage" "abc"
                         "alg-none" (str "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0"
                                         ".eyJzdWIiOiIxIiwidXNlcm5hbWUiOiJhbGljZSIsImlhdCI6MTc2MjgzNjkwMCwiZXhwIjoxNzYyODQwNTAwfQ.")}]
      (is (= {:error "invalid or expired token"} (verify-jwt tok secret)) label))))

(deftest bad-payload-test
  (let [n (now)]
    (doseq [[label payload] {"string-sub" {:sub "abc" :username "alice" :iat n :exp (+ n 3600)}
                             "numeric-sub" {:sub 9 :username "alice" :iat n :exp (+ n 3600)}
                             "missing-username" {:sub "1" :iat n :exp (+ n 3600)}
                             "numeric-username" {:sub "1" :username 123 :iat n :exp (+ n 3600)}}]
      (is (= {:error "invalid token payload"} (verify-jwt (sign payload) secret)) label))))

(deftest leeway-parity-test
  (let [n (now)
        tok (sign {:sub "1" :username "alice" :iat (- n 3600) :exp (- n 30)})]
    (is (= {:user-id 1 :username "alice"} (verify-jwt tok secret)))))
