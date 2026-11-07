package bench;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.radarroark.xitdb.CoreBufferedFile;
import io.github.radarroark.xitdb.Database;
import io.github.radarroark.xitdb.Hasher;
import io.github.radarroark.xitdb.RandomAccessBufferedFile;
import io.github.radarroark.xitdb.ReadHashMap;
import io.github.radarroark.xitdb.ReadHashSet;
import io.github.radarroark.xitdb.ReadSortedMap;
import io.github.radarroark.xitdb.WriteHashMap;
import io.github.radarroark.xitdb.WriteHashSet;
import io.github.radarroark.xitdb.WriteSortedMap;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.locks.ReentrantLock;

public class Store implements AutoCloseable {

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final DateTimeFormatter CREATED_FMT =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC);

    private final Database db;
    private final RandomAccessBufferedFile file;
    private final ReentrantLock lock = new ReentrantLock();
    private final Instant boot = Instant.now();

    public record Post(long id, String body, String createdAt, String author, long likeCount) {}

    public record LikeOutcome(boolean already, boolean found) {}

    private Store(Database db, RandomAccessBufferedFile file) {
        this.db = db;
        this.file = file;
    }

    public static Store openStore(String path, String secret) throws Exception {
        var f = new RandomAccessBufferedFile(new File(path), "rw");
        try {
            var hasher =
                    new Hasher(
                            MessageDigest.getInstance("SHA-1"), Hasher.stringToId("sha1"));
            var db = new Database(new CoreBufferedFile(f), hasher);
            return new Store(db, f);
        } catch (Exception e) {
            f.close();
            throw e;
        }
    }

    @Override
    public void close() throws Exception {
        file.close();
    }

    public Instant boot() {
        return boot;
    }

    public boolean health() {
        lock.lock();
        try {
            db.committedSize();
            return true;
        } catch (Exception e) {
            return false;
        } finally {
            lock.unlock();
        }
    }

    static String text(ReadHashMap m, String key) throws Exception {
        var c = m.getCursor(key);
        if (c == null) {
            throw new IllegalStateException("corrupt post: missing " + key);
        }
        return new String(c.readBytes(null), StandardCharsets.UTF_8);
    }

    static Post readPost(ReadHashMap posts, String id) throws Exception {
        var pc = posts.getCursor(id);
        if (pc == null) {
            return null;
        }
        var pm = new ReadHashMap(pc);
        var idC = pm.getCursor("id");
        var lcC = pm.getCursor("like_count");
        if (idC == null || lcC == null) {
            throw new IllegalStateException("corrupt post: missing scalar");
        }
        return new Post(
                idC.readUint(),
                text(pm, "body"),
                text(pm, "created_at"),
                text(pm, "author"),
                lcC.readUint());
    }

    static ReadHashMap readMap(ReadHashMap root, String key) throws Exception {
        var c = root.getCursor(key);
        return c == null ? null : new ReadHashMap(c);
    }

    public Optional<Post> getPost(String id) throws Exception {
        lock.lock();
        try {
            var root = new WriteHashMap(db.rootCursor());
            var posts = readMap(root, "posts");
            if (posts == null) {
                return Optional.empty();
            }
            return Optional.ofNullable(readPost(posts, id));
        } finally {
            lock.unlock();
        }
    }

    public List<Post> getFeed() throws Exception {
        lock.lock();
        try {
            var root = new WriteHashMap(db.rootCursor());
            var feedC = root.getCursor("feed");
            if (feedC == null) {
                return List.of();
            }
            var feed = new ReadSortedMap(feedC);
            long count = feed.count();
            long start = Math.max(0, count - 20);
            var posts = readMap(root, "posts");
            if (posts == null) {
                return List.of();
            }
            var ids = new ArrayList<String>();
            for (long i = start; i < count; i++) {
                var kv = feed.getIndexKeyValuePair(i);
                if (kv == null) {
                    continue;
                }
                ids.add(new String(kv.valueCursor.readBytes(null), StandardCharsets.UTF_8));
            }
            var out = new ArrayList<Post>();
            for (var id : ids) {
                var p = readPost(posts, id);
                if (p != null) {
                    out.add(p);
                }
            }
            Collections.reverse(out);
            return out;
        } finally {
            lock.unlock();
        }
    }

    public Post createPost(String username, String body) throws Exception {
        lock.lock();
        try {
            var created = new Post[1];
            db.runContext(
                    w -> {
                        var root = new WriteHashMap(w);
                        var meta =
                                new WriteHashMap(root.putCursor("meta"));
                        long next = 1;
                        var nextC = meta.getCursor("next_post_id");
                        if (nextC != null) {
                            next = nextC.readUint();
                        }
                        var createdAt = CREATED_FMT.format(Instant.now());
                        var posts =
                                new WriteHashMap(root.putCursor("posts"));
                        var idStr = Long.toUnsignedString(next);
                        var pm =
                                new WriteHashMap(
                                        posts.putCursor(idStr));
                        pm.put("id", new Database.Uint(next));
                        pm.put("body", new Database.Bytes(body));
                        pm.put("created_at", new Database.Bytes(createdAt));
                        pm.put("author", new Database.Bytes(username));
                        pm.put("like_count", new Database.Uint(0));
                        var feed =
                                new WriteSortedMap(root.putCursor("feed"));
                        feed.put(
                                Validate.feedKey(createdAt, next),
                                new Database.Bytes(idStr));
                        var likes =
                                new WriteHashMap(root.putCursor("likes"));
                        new WriteHashSet(likes.putCursor(idStr));
                        meta.put("next_post_id", new Database.Uint(next + 1));
                        created[0] =
                                new Post(next, body, createdAt, username, 0);
                    });
            db.core.sync();
            if (created[0] == null) {
                throw new IllegalStateException("create produced nothing");
            }
            return created[0];
        } finally {
            lock.unlock();
        }
    }

    public LikeOutcome likePost(String id, String user) throws Exception {
        lock.lock();
        try {
            var outcome = new LikeOutcome[1];
            outcome[0] = new LikeOutcome(false, false);
            db.runContext(
                    w -> {
                        var root = new WriteHashMap(w);
                        var posts =
                                new WriteHashMap(root.putCursor("posts"));
                        if (readPost(posts, id) == null) {
                            return;
                        }
                        var likes =
                                new WriteHashMap(root.putCursor("likes"));
                        var set =
                                new WriteHashSet(likes.putCursor(id));
                        if (set.getCursor(user) != null) {
                            outcome[0] = new LikeOutcome(true, true);
                            return;
                        }
                        set.put(user);
                        var pm =
                                new WriteHashMap(
                                        posts.putCursor(id));
                        var lcC = pm.getCursor("like_count");
                        if (lcC == null) {
                            throw new IllegalStateException("corrupt post");
                        }
                        pm.put("like_count", new Database.Uint(lcC.readUint() + 1));
                        outcome[0] = new LikeOutcome(false, true);
                    });
            db.core.sync();
            return outcome[0];
        } finally {
            lock.unlock();
        }
    }

    /** Probes putCursor-descend outside runContext (see txnRule test). */
    public String probeDescendOutsideTxn() throws Exception {
        var root = new WriteHashMap(db.rootCursor());
        try {
            root.putCursor("txn-probe");
            return "allowed";
        } catch (Exception e) {
            return e.getClass().getSimpleName() + ": " + e.getMessage();
        }
    }

    public static String jsonStr(String s) throws Exception {
        return JSON.writeValueAsString(s);
    }

    public static String postJson(Post p) throws Exception {
        return "{\"id\":"
                + Long.toUnsignedString(p.id())
                + ",\"body\":"
                + jsonStr(p.body())
                + ",\"created_at\":"
                + jsonStr(p.createdAt())
                + ",\"author\":"
                + jsonStr(p.author())
                + ",\"like_count\":"
                + Long.toUnsignedString(p.likeCount())
                + "}";
    }
}
