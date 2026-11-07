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
        return Store.openStore(tmp.resolve("t.xitdb").toString(), "test-secret");
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
    void txnRule() throws Exception {
        // putCursor-descend outside runContext: record behavior (Rust throws /
        // Go+Zig+Odin allow); whichever -> ledgered ruling, planned shape kept.
        try (var s = open()) {
            // Observed: allowed (Go/Zig/Odin-like, not Rust-like). Pin it so
            // a future behavior change fails loudly.
            assertEquals("allowed", s.probeDescendOutsideTxn());
        }
    }

    @Test
    void durability() throws Exception {
        var path = Files.createTempFile("xb-java-", ".xitdb").toString();
        try (var s = Store.openStore(path, "s")) {
            s.createPost("alice", "durable?");
        }
        try (var s = Store.openStore(path, "s")) {
            assertEquals("durable?", s.getPost("1").orElseThrow().body());
        } finally {
            Files.deleteIfExists(Path.of(path));
        }
    }
}
