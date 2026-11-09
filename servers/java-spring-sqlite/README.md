# java-spring-sqlite — SQLite twin of the Spring Boot server

Spring Boot 3.5 on upstream `schema.sql` via `org.xerial/sqlite-jdbc`
3.46.1.0 (plain JDBC, JVM-bundled natives). Controllers, auth, and JSON
are verbatim copies of `servers/java-spring`; only the store layer
(plus the 1-line default DB path) differs.

## Run

```bash
mvn -B -q package -DskipTests
XITDB_PATH=/tmp/x/feed.xitdb JWT_SECRET=twelve-dollar-challenge \
  HOST=127.0.0.1 PORT=3000 java -Xmx1g -jar target/*.jar
```

Or via the harness (fresh seed + suite): `bash harness/run.sh servers/java-spring`.

## Nginx or direct

Behind `harness/bench/nginx.conf` on `127.0.0.1:3000` (64 idle conns;
`server.tomcat.keep-alive-timeout=70000` — Tomcat defaults to 60s,
below the 65s rule), or directly on `0.0.0.0:80`. This repo's gate
runs direct. (`-Xmx1g` caps heap for the 2GB droplet.)

## Optimizations (and why)

- Denormalized `author` + `like_count` in the post object: feed and
  single-post reads do zero joins / zero `count(*)` (the xitdb-shaped
  trade the benchmark is meant to test).
- Feed = one `count()` + `getIndexKeyValuePair(count-20..)` + 20 point
  gets, reversed: O(log n) seek, constant reads.
- One xitdb txn per mutating request (`runContext`) plus an explicit
  `core.sync()` (the commit path syncs data but *not* the header
  write): 201 means committed + synced.
- One `ReentrantLock` around all DB access (MVC + Tomcat threads take
  one writer at a time); reads hold it only for the copy.
- Manual compact-JSON emission with frozen key order
  (`id,body,created_at,author,like_count`); Jackson
  `writeValueAsString` per string for escaping.
- JWT HS256 verified every request (hand-rolled over `javax.crypto` —
  jjwt refuses the challenge's fixed 184-bit secret — 60s leeway for
  parity with the other references); auth checked before id
  validation per spec.
