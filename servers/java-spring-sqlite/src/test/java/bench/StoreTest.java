package bench;

import static org.junit.jupiter.api.Assertions.*;

import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

public class StoreTest {

    @TempDir
    Path tmp;

    Store open() throws Exception {
        var s = Store.openStore(tmp.resolve("t.db").toString(), "test-secret");
        try (var st = java.sql.DriverManager.getConnection("jdbc:sqlite:" + tmp.resolve("t.db"));
                var ins =
                        st.prepareStatement(
                                "INSERT INTO users(id,username,created_at) VALUES(7,'alice','2025-01-01T00:00:00.000Z')")) {
            ins.executeUpdate();
        }
        return s;
    }

    @Test
    void roundTrip() throws Exception {
        try (var s = open()) {
            var p = s.createPost("alice", "hi");
            assertEquals(1L, p.id());
            assertEquals("hi", p.body());
            assertEquals("alice", p.author());
            assertEquals(0L, p.likeCount());
            assertTrue(
                    p.createdAt().matches("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z"),
                    p.createdAt());
            assertEquals(p, s.getPost("1").orElseThrow());
            assertTrue(s.getPost("999").isEmpty());
            s.createPost("alice", "second");
            assertEquals(java.util.List.of(2L, 1L), s.getFeed().stream().map(Store.Post::id).toList());
        }
    }

    @Test
    void likeIdempotent() throws Exception {
        try (var s = open()) {
            s.createPost("alice", "x");
            assertEquals(new Store.LikeOutcome(false, true), s.likePost("1", "7"));
            assertEquals(new Store.LikeOutcome(true, true), s.likePost("1", "7"));
            assertEquals(1L, s.getPost("1").orElseThrow().likeCount());
            assertEquals(new Store.LikeOutcome(false, false), s.likePost("999", "7"));
        }
    }

    @Test
    void missingKeys() throws Exception {
        try (var s = open()) {
            assertTrue(s.getPost("12345").isEmpty());
            assertEquals(new Store.LikeOutcome(false, false), s.likePost("12345", "9"));
            assertTrue(s.getFeed().isEmpty());
            assertTrue(s.health());
        }
    }

    @Test
    void likePrimaryKey() throws Exception {
        // PRIMARY KEY (user_id, post_id) is what makes repeat likes a no-op
        // at the engine level; pin it so schema drift fails loudly.
        try (var s = open()) {
            s.createPost("alice", "x");
            try (var st = java.sql.DriverManager.getConnection("jdbc:sqlite:" + tmp.resolve("t.db"));
                    var ins =
                            st.prepareStatement(
                                    "INSERT INTO likes(user_id,post_id,created_at) VALUES(7,1,'2025-01-01T00:00:00.000Z')")) {
                assertEquals(1, ins.executeUpdate());
                assertThrows(java.sql.SQLException.class, ins::executeUpdate);
            }
        }
    }

    @Test
    void schemaPinsUpstream() throws Exception {
        // Schema.java carries a verbatim copy of seed/schema.sql.
        var vendored =
                java.nio.file.Files.readString(
                        Path.of("../../seed/schema.sql"), java.nio.charset.StandardCharsets.UTF_8);
        assertEquals(norm(vendored), norm(bench.Schema.SQL));
        try (var s = open()) {
            assertEquals(java.util.List.of("likes", "posts", "users"), s.schemaTables());
        }
    }

    static String norm(String x) {
        return x.replaceAll("--[^\n]*", "")
                .replaceAll("\\s+", " ")
                .replaceAll("\\( ", "(")
                .replaceAll(" \\)", ")")
                .replaceAll("; ", ";")
                .trim();
    }

    @Test
    void durability() throws Exception {
        var path = Files.createTempFile("xb-java-", ".db").toString();
        try (var s = Store.openStore(path, "s")) {
            try (var st = java.sql.DriverManager.getConnection("jdbc:sqlite:" + path);
                    var ins =
                            st.prepareStatement(
                                    "INSERT INTO users(id,username,created_at) VALUES(7,'alice','2025-01-01T00:00:00.000Z')")) {
                ins.executeUpdate();
            }
            s.createPost("alice", "durable?");
        }
        try (var s = Store.openStore(path, "s")) {
            assertEquals("durable?", s.getPost("1").orElseThrow().body());
        } finally {
            Files.deleteIfExists(Path.of(path));
        }
    }
}
