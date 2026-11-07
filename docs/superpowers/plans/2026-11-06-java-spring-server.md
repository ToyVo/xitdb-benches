# Java/Spring Feed Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conformant `$12`-challenge feed server in `servers/java-spring` (Spring Boot 3.5 + `xitdb-java`), green on the committed goldens — the last fan-out item.

**Architecture:** Mirror of the references: `Database` over `CoreBufferedFile` with a HashMap root holding the 5 frozen collections; reads via `getCursor` (null = absent, no txn), mutations via single `runContext` each plus explicit `core.sync()` (the commit path syncs data but not the header write); one `ReentrantLock` around all DB access (MVC + Tomcat threads); compact JSON with fixed field order.

**Tech Stack:** JDK 21, Spring Boot 3.5.16 (`spring-boot-starter-web`), `io.github.radarroark:xitdb:0.48.0` (Clojars repo), `io.jsonwebtoken:jjwt-{api,impl,jackson}:0.13.0`, Maven (pinned 3.10.0 droplet-side).

## Global Constraints

- Repo root: `/Users/collindie/Code/xitdb-benches`; `servers/java-spring/` Maven project (`pom.xml` + `pom` wrapper? NO wrapper — pinned `install.sh` instead); every task ends committed there.
- Layout frozen: root keys `users,posts,feed,likes,meta`; `feedKey = createdAt + "\0" + zero-padded-10 id`; post JSON key order `id,body,created_at,author,like_count`; `Content-Type: application/json`.
- Hasher: `new Hasher(MessageDigest.getInstance("SHA-1"), Hasher.stringToId("sha1"))` (matches the seed header; id-0 default must NOT be used); core `new CoreBufferedFile(new RandomAccessBufferedFile(file, "rw"))`; **`db.core.sync()` after every mutating `runContext`** (flush+fsync; 201 means durable).
- Env: `XITDB_PATH`, `JWT_SECRET=twelve-dollar-challenge`, `HOST=127.0.0.1`, `PORT=3000` (read in code, applied to the connector — NOT `server.port` file config, so one artifact honors both Nginx and direct modes).
- `server.tomcat.keep-alive-timeout=70000` in `application.properties` (Tomcat defaults to 60s — below the ≥65s Nginx rule; this setting is load-bearing, pinned by test).
- Auth: jjwt `parser().verifyWith(hmacKey).clockSkewSeconds(60).build()` + explicit `claims.getHeader().getAlgorithm().equals("HS256")`, verified every request; `sub` = all-digit string `≥1` (unsigned-64), `username` = string; auth-before-id.
- Body rule: `String.strip()`, empty → required; `codePointCount > 500` → too-long (rune semantics like Rust/Go/Zig — NOT the TS/Clj UTF-16 rule; suite vectors are ASCII so all agree).
- Id rule: `^[0-9]+$`, `Long.parseUnsignedLong`, `≥1`; full u64 accepted, miss → 404.
- `created_at`: `Instant.now()` formatted `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` UTC (always 3-digit millis).
- `POST /:id/like`: `201 already_liked:false` first, `200 already_liked:true` repeat, count bumps once.
- `start.sh` runs `java -Xmx1g -jar` (2GB droplet budget); boot must complete ≤60s.

## Review Focus

- Missing-key reads: `getCursor` on absent keys must yield post-not-found / not-liked, never 500 — pinned in Task 2 (`missingKeys` test).
- `putCursor`-outside-`runContext` behavior (Rust throws / Go+Zig+Odin allow) — pinned in Task 2 (`txnRule` probe; whichever → ledgered ruling, planned shape kept).
- Header write after commit is un-synced by the library — pinned in Task 3 (write → close → reopen → read-back test).
- jjwt `verifyWith` accepts the whole HS family — an `HS384`/`none` token must still be rejected by the explicit alg check — pinned in Task 2 (`algConfusion` vectors).
- Tomcat's 60s default keep-alive violates the ≥65s rule — pinned in Task 3 (context test asserting the `70000` property is actually applied).

---

## File Structure

`servers/java-spring/` (existing stubs replaced):

- `pom.xml` — parent `spring-boot-starter-parent:3.5.16`; deps `spring-boot-starter-web`, `xitdb:0.48.0` (Clojars repo declared), `jjwt-api/impl/jackson:0.13.0`, `spring-boot-starter-test` (test scope); `spring-boot-maven-plugin` repackage; compiler release 21.
- `src/main/java/bench/Application.java` — Boot app; reads env; sets connector address/port; `IdleTimeout` comes from properties.
- `src/main/java/bench/Validate.java` — static pure: `feedKey`, `validPostId` (→ `Optional<Long>`? NO — unsigned range exceeds long: return `Optional<BigInteger>`), `trimBody` (→ result record).
- `src/main/java/bench/Auth.java` — `verifyJwt` (→ `AuthResult` record: `ok(userId, username)` / `err(message)`).
- `src/main/java/bench/Store.java` — `@Service`: `ReentrantLock`, `openStore`, `health`, `getFeed`, `getPost`, `createPost`, `likePost`, `Post` record + `postJson` (StringBuilder framing, `ObjectMapper.writeValueAsString` per string).
- `src/main/java/bench/FeedController.java` — 5 routes + 404 fallback (Boot: `NoHandlerFound`? Simpler: default 404 body differs — map `NoResourceFoundException` via `@ControllerAdvice` to `{"error":"not found"}`; Boot 3.2+ throws it when `spring.mvc.throw-exception-if-no-handler-found=true`. Set that property + advice. Pinned by suite's `/nope` check in Task 4 gate.)
- `src/main/resources/application.properties` — keep-alive 70s + throw-exception-if-no-handler-found.
- `src/test/java/bench/{ValidateTest,AuthTest,StoreTest,WebConfigTest}.java` — JUnit 5 (`mvn -q test`; store tests on `@TempDir` file DBs, never seed files).
- `install.sh` (Temurin 21 + Maven 3.10.0 pinned) / `build.sh` (`mvn -B -q package -DskipTests`) / `start.sh`; `README.md`.

Reference reads: `xitdb-java` `WriteHashMap/WriteSortedMap/WriteHashSet/ReadSortedMap/Database` (put/putCursor/getCursor/count/getIndexKeyValuePair/runContext/committedSize), `HighLevelDatabaseTest.java` (open pattern), `go-std`/`rust-axum` (route edge cases: multi-slash like → 404).

---

### Task 1: Build scaffold + pure validation + auth

**Files:**
- Create: `servers/java-spring/pom.xml`, `src/main/java/bench/{Validate,Auth}.java`, `src/main/resources/application.properties`, `src/test/java/bench/{ValidateTest,AuthTest}.java`
- Test: `mvn -q test`

**Interfaces:**
- Consumes: none.
- Produces:
  - `Validate.feedKey(String, BigInteger→long id): String` (ids here are small; signature takes `long`)
  - `Validate.validPostId(String): Optional<BigInteger>`
  - `Validate.trimBody(Object parsed-body): TrimResult(boolean ok, String valueOrMessage)`
  - `Auth.verifyJwt(String token, String secret): AuthResult` (`ok(BigInteger userId, String username)` / `err(String message)`)

- [ ] **Step 1: Write failing tests**

```java
// ValidateTest: feedKey format+ordering; validPostId table ("1"->1, "0","-1","abc","1.5",""->empty, 2^64->empty, u64-max->present);
//   trimBody: padded/whitespace/numeric/missing->required, 501->too-long, 500 ok, 500xé ok (codePointCount)
// AuthTest (jjwt signs HS256 test tokens + hand-built alg:none): good->{1,"alice"}; bad-sig/expired-1h/garbage/alg-none->token error;
//   string+numeric sub, missing+numeric username->payload error; expired-30s->ok (leeway_parity)
// AuthTest.algConfusion: HS384-signed token (if craftable with jjwt) -> token error via the explicit alg check
```

- [ ] **Step 2: Run to verify fail**

Run: `mvn -q test 2>&1 | tail -5`
Expected: FAIL — classes missing (plus first-time dependency downloads).

- [ ] **Step 3: Implement `pom.xml` + `Validate.java` + `Auth.java`** with the exact signatures. JWT via `Jwts.parser().verifyWith(Keys.hmacShaKeyFor(secret.getBytes(UTF_8))).clockSkewSeconds(60).build()` in try/catch (any `JwtException` → token error); then explicit `claims.getHeader().get("alg").equals("HS256")` (→ token error otherwise); then hand-checked `sub` (all-digit string, unsigned range, ≥1) / `username` (string) → payload errors.

- [ ] **Step 4: Run to verify pass**

Run: `mvn -q test 2>&1 | tail -3`
Expected: PASS (`Tests run: N, Failures: 0, Errors: 0`).

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/java-spring && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: java pure validation + jwt vectors"
```

### Task 2: Store over xitdb-java

**Files:**
- Create: `servers/java-spring/src/main/java/bench/Store.java`, `src/test/java/bench/StoreTest.java`
- Test: `mvn -q -Dtest=StoreTest test`

**Interfaces:**
- Consumes: `feedKey` from Task 1.
- Produces: `Store` (`openStore/health/getFeed/getPost/createPost/likePost`) + `Post` record + `postJson` per File Structure.

- [ ] **Step 1: Write failing store tests** (`@TempDir` file DBs, hand-seeded through the store)

```java
// roundTrip: create("alice","hi") -> id 1/trimmed/count 0/createdAt regex; get(1) equals; get(999) empty; 2nd -> feed ids [2,1]
// likeIdempotent: first/second/missing shapes, count exactly 1
// missingKeys: get/like empty, empty feed, health true
// txnRule: putCursor-descend outside runContext -> record behavior; whichever -> ledgered ruling, planned shape kept
```

- [ ] **Step 2: Run to verify fail**

Run: `mvn -q -Dtest=StoreTest test 2>&1 | tail -5`
Expected: FAIL — `Store` missing.

- [ ] **Step 3: Implement `Store.java`**: open `RandomAccessFile(path,"rw")` → `CoreBufferedFile` → `Database(core, sha1Hasher, null)`; root via `new WriteHashMap(db.rootCursor())`; reads descend with `getCursor` (null = absent); mutations in `db.runContext(w -> {...})` with `putCursor` + sorted/set inits + `db.core.sync()` before returning; feed = `count()` → `getIndexKeyValuePair(start..count)` → `valueCursor.readBytes` ids → point gets → reverse; `postJson` StringBuilder framing with `ObjectMapper.writeValueAsString` per string.

- [ ] **Step 4: Run to verify pass**

Run: `mvn -q test 2>&1 | tail -3`
Expected: PASS, Tasks 1+2 green.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/java-spring && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: java xitdb store + like/feed semantics"
```

### Task 3: HTTP server + wiring

**Files:**
- Create: `servers/java-spring/src/main/java/bench/{Application,FeedController}.java`, `src/test/java/bench/WebConfigTest.java`; Modify: `servers/java-spring/{install,build,start}.sh`, `servers/java-spring/README.md`
- Test: `WebConfigTest` + live small-DB smoke with curl + durability check

**Interfaces:**
- Consumes: `Store` + validate/auth from Tasks 1–2.
- Produces: listening server honoring env; exact bytes per SPEC-XITDB.

- [ ] **Step 1: Write the failing smoke** (nothing serving)

Run: `PORT=3015 bash servers/java-spring/start.sh & sleep 2; curl -sf http://127.0.0.1:3015/health; echo "EXIT:$?"`
Expected: FAIL — `target/*.jar` missing.

- [ ] **Step 2: Implement `Application.java` + `FeedController.java`**: `@SpringBootApplication` reading `XITDB_PATH/JWT_SECRET/HOST/PORT` (defaults per contract; invalid PORT → 3000); `@RestController` with the 5 routes (raw `String` body read + `ObjectMapper.readTree` in try/catch → `malformed JSON body`; non-textual/missing `body` → `body is required`); like handler auths before id-check; multi-segment like ids → 404 (mirror the Zig fix); `uptime_s` from boot instant; `@ControllerAdvice` mapping `NoResourceFoundException` → 404 `not found`.

- [ ] **Step 3: Wire scripts + README + config test**: `install.sh` (Temurin 21 + Maven 3.10.0 tarballs), `build.sh` (`mvn -B -q package -DskipTests`), `start.sh` (`exec java -Xmx1g -jar target/*.jar` — exactly one jar expected; fail loudly otherwise); README (mirror go README + Boot notes). `WebConfigTest`: boots the Spring context (`@SpringBootTest`) and asserts `server.tomcat.keep-alive-timeout` resolves to `70000` (note: proves the property is applied, not the socket behavior — M3 nginx proves that).

- [ ] **Step 4: Run smoke + durability to verify pass** (fresh small seed)

Run: `cp /tmp/xb-small/feed.xitdb /tmp/xb-java-smoke.db && XITDB_PATH=/tmp/xb-java-smoke.db PORT=3015 java -Xmx1g -jar target/*.jar & sleep 15; curl -s http://127.0.0.1:3015/posts/1 | head -c 120; curl -s http://127.0.0.1:3015/feed | python3 -c "import json,sys;print(len(json.load(sys.stdin)['posts']))"`
Expected: post-1 bytes + `20` (JVM+Boot need the longer sleep). Then: create+like via curl, kill, reopen read-back of the created post (durability gate for the `core.sync` decision).

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add servers/java-spring && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: java spring feed server"
```

### Task 4: Gate + CI + docs

**Files:**
- Modify: `.github/workflows/ci.yml` (add `java-spring` job), `LEADERBOARD-XITDB.md` (java row)
- Test: `harness/run.sh` (small + full) + k6 smoke

**Interfaces:**
- Consumes: Tasks 1–3 + committed goldens (targets, never regenerated).
- Produces: leaderboard java row (local numbers, labeled).

- [ ] **Step 1: Run small gate**

Run: `bash harness/run.sh servers/java-spring 2>&1 | tail -2`
Expected: `passed=42 failed=0`.

- [ ] **Step 2: Run full gate**

Run: `SIZE=full bash harness/run.sh servers/java-spring 2>&1 | tail -2`
Expected: `passed=42 failed=0`.

- [ ] **Step 3: k6 smoke** (persistent full seed + fresh copy, VUS=50/30s — same shape as prior plans with `/tmp/xb-java-k6` paths and `target/*.jar`)
Expected: thresholds `✓`, `0.00%`.

- [ ] **Step 4: Add CI job** (`actions/setup-java@v4`: Temurin 21 + bundled Maven; `bash harness/run.sh servers/java-spring`, small) and record local numbers in `LEADERBOARD-XITDB.md` java row.

- [ ] **Step 5: Commit**

```bash
git -C /Users/collindie/Code/xitdb-benches add -A && git -C /Users/collindie/Code/xitdb-benches commit -m "feat: java-spring green small+full + ci"
```
