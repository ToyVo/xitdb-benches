(ns validate-test
  (:require [clojure.test :refer [deftest is testing]]
            [validate :refer [feed-key valid-post-id trim-body]]))

(deftest feed-key-test
  (is (= (str "2025-01-01T00:00:00.000Z" (char 0) "0000000007")
         (feed-key "2025-01-01T00:00:00.000Z" 7)))
  (is (neg? (compare (feed-key "2025-01-01T00:00:00.000Z" 7)
                     (feed-key "2025-01-01T00:00:00.000Z" 8)))))

(deftest valid-post-id-test
  (is (= 1 (valid-post-id "1")))
  (is (= 999999999 (valid-post-id "999999999")))
  (doseq [bad ["0" "-1" "abc" "1.5" ""]]
    (is (nil? (valid-post-id bad)) (str "input " (pr-str bad))))
  (testing "unsigned-64 overflow rejected"
    (is (nil? (valid-post-id "18446744073709551616")))))

(deftest trim-body-test
  (is (= [true "hi"] (trim-body "  hi ")))
  (is (= [false "body is required"] (trim-body "   ")))
  (is (= [false "body is required"] (trim-body 123)))
  (is (= [false "body is required"] (trim-body nil)))
  (is (= [false "body must be at most 500 characters"] (trim-body (apply str (repeat 501 "a")))))
  (is (= [true (apply str (repeat 500 "b"))] (trim-body (apply str (repeat 500 "b")))))
  (testing "multibyte counts UTF-16 units like upstream"
    (is (= [true (apply str (repeat 500 "é"))] (trim-body (apply str (repeat 500 "é")))))))
