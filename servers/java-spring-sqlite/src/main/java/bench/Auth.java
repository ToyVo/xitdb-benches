package bench;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.Map;
import java.util.regex.Pattern;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

public final class Auth {

    private Auth() {}

    private static final BigInteger MAX_U64 =
            new BigInteger("18446744073709551615");
    private static final Pattern DIGITS = Pattern.compile("[0-9]+");
    private static final ObjectMapper JSON = new ObjectMapper();

    public sealed interface AuthResult permits AuthResult.Ok, AuthResult.Err {
        record Ok(BigInteger userId, String username) implements AuthResult {}

        record Err(String message) implements AuthResult {}
    }

    // Hand-rolled HS256: jjwt refuses the challenge's fixed 184-bit secret
    // (WeakKeyException at sign and verify time), and the stdlib needs no
    // extra dependency. Mirrors the Zig/Odin servers.
    public static AuthResult verifyJwt(String token, String secret) {
        var parts = token.split("\\.", -1);
        if (parts.length != 3) {
            return new AuthResult.Err("invalid or expired token");
        }
        Map<String, Object> header;
        try {
            header =
                    JSON.readValue(
                            b64url(parts[0]),
                            new TypeReference<Map<String, Object>>() {});
        } catch (Exception e) {
            return new AuthResult.Err("invalid or expired token");
        }
        if (!"HS256".equals(header.get("alg"))) {
            return new AuthResult.Err("invalid or expired token");
        }
        byte[] sig;
        try {
            sig = Base64.getUrlDecoder().decode(parts[2]);
        } catch (IllegalArgumentException e) {
            return new AuthResult.Err("invalid or expired token");
        }
        if (sig.length != 32
                || !MessageDigest.isEqual(hmacSha256(parts[0] + "." + parts[1], secret), sig)) {
            return new AuthResult.Err("invalid or expired token");
        }
        Map<String, Object> payload;
        try {
            payload =
                    JSON.readValue(
                            b64url(parts[1]),
                            new TypeReference<Map<String, Object>>() {});
        } catch (Exception e) {
            return new AuthResult.Err("invalid or expired token");
        }
        var sub = payload.get("sub");
        var username = payload.get("username");
        if (!(sub instanceof String subStr) || !DIGITS.matcher(subStr).matches()) {
            return new AuthResult.Err("invalid token payload");
        }
        var id = new BigInteger(subStr);
        if (id.signum() <= 0 || id.compareTo(MAX_U64) > 0) {
            return new AuthResult.Err("invalid token payload");
        }
        if (!(username instanceof String)) {
            return new AuthResult.Err("invalid token payload");
        }
        var exp = payload.get("exp");
        if (!(exp instanceof Number)) {
            return new AuthResult.Err("invalid or expired token");
        }
        long now = System.currentTimeMillis() / 1000L;
        if (((Number) exp).longValue() + 60 < now) {
            return new AuthResult.Err("invalid or expired token");
        }
        return new AuthResult.Ok(id, (String) username);
    }

    static byte[] hmacSha256(String msg, String secret) {
        try {
            var mac = Mac.getInstance("HmacSHA256");
            mac.init(
                    new SecretKeySpec(
                            secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            return mac.doFinal(msg.getBytes(StandardCharsets.US_ASCII));
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static byte[] b64url(String s) {
        return Base64.getUrlDecoder().decode(s);
    }
}
