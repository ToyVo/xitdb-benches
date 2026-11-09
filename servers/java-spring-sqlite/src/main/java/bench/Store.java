package bench;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.locks.ReentrantLock;

public class Store implements AutoCloseable {

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final DateTimeFormatter CREATED_FMT =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC);

    private static final String FEED_SQL =
            "SELECT p.id,p.body,p.created_at,u.username,"
                    + "(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id)"
                    + " FROM posts p JOIN users u ON u.id=p.user_id"
                    + " ORDER BY p.created_at DESC,p.id DESC LIMIT 20";
    private static final String POST_SQL =
            "SELECT p.id,p.body,p.created_at,u.username,"
                    + "(SELECT COUNT(*) FROM likes l WHERE l.post_id=p.id)"
                    + " FROM posts p JOIN users u ON u.id=p.user_id WHERE p.id=?";

    private final Connection conn;
    private final ReentrantLock lock = new ReentrantLock();
    private final Instant boot = Instant.now();

    public record Post(long id, String body, String createdAt, String author, long likeCount) {}

    public record LikeOutcome(boolean already, boolean found) {}

    private Store(Connection conn) {
        this.conn = conn;
    }

    public static Store openStore(String path, String secret) throws Exception {
        var conn = DriverManager.getConnection("jdbc:sqlite:" + path);
        try (var st = conn.createStatement()) {
            st.execute("PRAGMA busy_timeout = 5000");
            try (var rs =
                    st.executeQuery(
                            "SELECT name FROM sqlite_master WHERE type='table' AND name='users'")) {
                if (!rs.next()) {
                    for (var stmt : Schema.SQL.split(";")) {
                        var t = stmt.trim();
                        if (!t.isEmpty()) {
                            st.execute(t);
                        }
                    }
                }
            }
        } catch (Exception e) {
            conn.close();
            throw e;
        }
        return new Store(conn);
    }

    @Override
    public void close() throws Exception {
        conn.close();
    }

    public Instant boot() {
        return boot;
    }

    public boolean health() {
        lock.lock();
        try (var st = conn.createStatement();
                var rs = st.executeQuery("SELECT COUNT(*) FROM users")) {
            return rs.next();
        } catch (Exception e) {
            return false;
        } finally {
            lock.unlock();
        }
    }

    static Post readPost(ResultSet rs) throws Exception {
        return new Post(
                rs.getLong(1), rs.getString(2), rs.getString(3), rs.getString(4), rs.getLong(5));
    }

    public Optional<Post> getPost(String id) throws Exception {
        lock.lock();
        try (var ps = conn.prepareStatement(POST_SQL)) {
            ps.setLong(1, Long.parseUnsignedLong(id));
            try (var rs = ps.executeQuery()) {
                if (!rs.next()) {
                    return Optional.empty();
                }
                return Optional.of(readPost(rs));
            }
        } finally {
            lock.unlock();
        }
    }

    public List<Post> getFeed() throws Exception {
        lock.lock();
        try (var ps = conn.prepareStatement(FEED_SQL);
                var rs = ps.executeQuery()) {
            var out = new ArrayList<Post>();
            while (rs.next()) {
                out.add(readPost(rs));
            }
            return out;
        } finally {
            lock.unlock();
        }
    }

    public Post createPost(String username, String body) throws Exception {
        lock.lock();
        try (var find = conn.prepareStatement("SELECT id FROM users WHERE username=?")) {
            find.setString(1, username);
            long userId;
            try (var rs = find.executeQuery()) {
                if (!rs.next()) {
                    throw new IllegalStateException("unknown author");
                }
                userId = rs.getLong(1);
            }
            var createdAt = CREATED_FMT.format(Instant.now());
            try (var ins =
                    conn.prepareStatement("INSERT INTO posts(user_id,body,created_at) VALUES(?,?,?)")) {
                ins.setLong(1, userId);
                ins.setString(2, body);
                ins.setString(3, createdAt);
                ins.executeUpdate();
            }
            long id;
            try (var st = conn.createStatement();
                    var rs = st.executeQuery("SELECT last_insert_rowid()")) {
                rs.next();
                id = rs.getLong(1);
            }
            return new Post(id, body, createdAt, username, 0);
        } finally {
            lock.unlock();
        }
    }

    public LikeOutcome likePost(String id, String user) throws Exception {
        lock.lock();
        try (var exists = conn.prepareStatement("SELECT 1 FROM posts WHERE id=?")) {
            exists.setLong(1, Long.parseUnsignedLong(id));
            try (var rs = exists.executeQuery()) {
                if (!rs.next()) {
                    return new LikeOutcome(false, false);
                }
            }
            var createdAt = CREATED_FMT.format(Instant.now());
            try (var ins =
                    conn.prepareStatement(
                            "INSERT OR IGNORE INTO likes(user_id,post_id,created_at) VALUES(?,?,?)")) {
                ins.setLong(1, Long.parseUnsignedLong(user));
                ins.setLong(2, Long.parseUnsignedLong(id));
                ins.setString(3, createdAt);
                var n = ins.executeUpdate();
                return new LikeOutcome(n == 0, true);
            }
        } finally {
            lock.unlock();
        }
    }

    /** Sorted table names, for the schema pin test. */
    public List<String> schemaTables() throws Exception {
        try (var st = conn.createStatement();
                var rs =
                        st.executeQuery(
                                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")) {
            var out = new ArrayList<String>();
            while (rs.next()) {
                out.add(rs.getString(1));
            }
            return out;
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
