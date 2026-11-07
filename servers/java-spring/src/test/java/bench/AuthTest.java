package bench;

import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import org.junit.jupiter.api.Test;

public class AuthTest {

    static final String SECRET = "twelve-dollar-challenge";
    static final ObjectMapper JSON = new ObjectMapper();

    static String b64url(byte[] b) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(b);
    }

    static String sign(Map<String, Object> claims, String secret) {
        try {
            String h =
                    b64url(
                            "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
                                    .getBytes(StandardCharsets.UTF_8));
            String p = b64url(JSON.writeValueAsBytes(claims));
            String sig = b64url(Auth.hmacSha256(h + "." + p, secret));
            return h + "." + p + "." + sig;
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    static Map<String, Object> base(long now) {
        var m = new LinkedHashMap<String, Object>();
        m.put("sub", "1");
        m.put("username", "alice");
        m.put("iat", now);
        m.put("exp", now + 3600);
        return m;
    }

    @Test
    void goodToken() {
        long now = Instant.now().getEpochSecond();
        var r = Auth.verifyJwt(sign(base(now), SECRET), SECRET);
        assertTrue(r instanceof Auth.AuthResult.Ok);
        var ok = (Auth.AuthResult.Ok) r;
        assertEquals(1L, ok.userId().longValueExact());
        assertEquals("alice", ok.username());
    }

    @Test
    void badSignatures() {
        long now = Instant.now().getEpochSecond();
        assertTokenError(sign(base(now), "wrong-secret"));
        var expired = new LinkedHashMap<>(base(now));
        expired.put("iat", now - 7200);
        expired.put("exp", now - 3600);
        assertTokenError(sign(expired, SECRET));
        assertTokenError("abc");
        String none =
                "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiIxIiwidXNlcm5hbWUiOiJhbGljZSIsImlhdCI6MTc2MjgzNjkwMCwiZXhwIjoxNzYyODQwNTAwfQ.";
        assertTokenError(none);
    }

    @Test
    void badPayloads() {
        long now = Instant.now().getEpochSecond();
        assertPayloadError(
                sign(Map.of("sub", "abc", "username", "alice", "iat", now, "exp", now + 3600), SECRET));
        assertPayloadError(
                sign(Map.of("sub", 9, "username", "alice", "iat", now, "exp", now + 3600), SECRET));
        assertPayloadError(sign(Map.of("sub", "1", "iat", now, "exp", now + 3600), SECRET));
        assertPayloadError(
                sign(Map.of("sub", "1", "username", 123, "iat", now, "exp", now + 3600), SECRET));
    }

    @Test
    void leewayParity() {
        long now = Instant.now().getEpochSecond();
        var m = new LinkedHashMap<String, Object>();
        m.put("sub", "1");
        m.put("username", "alice");
        m.put("iat", now - 3600);
        m.put("exp", now - 30);
        var r = Auth.verifyJwt(sign(m, SECRET), SECRET);
        assertTrue(r instanceof Auth.AuthResult.Ok);
        assertEquals(1L, ((Auth.AuthResult.Ok) r).userId().longValueExact());
    }

    @Test
    void algConfusion() {
        // HS384 header must be rejected by the explicit HS256 check even
        // though only the header is inspected before the signature.
        long now = Instant.now().getEpochSecond();
        String h =
                b64url(
                        "{\"alg\":\"HS384\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.UTF_8));
        String tok = h + "." + b64url(new byte[] {1, 2, 3}) + ".c2ln";
        assertTokenError(tok);
        // ... and a correctly HS256-signed token still verifies (sanity).
        var r = Auth.verifyJwt(sign(base(now), SECRET), SECRET);
        assertTrue(r instanceof Auth.AuthResult.Ok);
    }

    static void assertTokenError(String tok) {
        var r = Auth.verifyJwt(tok, SECRET);
        assertTrue(r instanceof Auth.AuthResult.Err);
        assertEquals("invalid or expired token", ((Auth.AuthResult.Err) r).message());
    }

    static void assertPayloadError(String tok) {
        var r = Auth.verifyJwt(tok, SECRET);
        assertTrue(r instanceof Auth.AuthResult.Err);
        assertEquals("invalid token payload", ((Auth.AuthResult.Err) r).message());
    }
}
