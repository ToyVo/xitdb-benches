package bench;

import java.math.BigInteger;
import java.util.Optional;
import java.util.regex.Pattern;

public final class Validate {

    private Validate() {}

    private static final BigInteger MAX_U64 =
            new BigInteger("18446744073709551615");
    private static final Pattern DIGITS = Pattern.compile("[0-9]+");

    public static String feedKey(String createdAt, long id) {
        return createdAt + "\0" + String.format("%010d", id);
    }

    /** All-digit string in [1, 2^64-1] (full u64 like Rust/Go/Zig), else empty. */
    public static Optional<BigInteger> validPostId(String s) {
        if (s == null || !DIGITS.matcher(s).matches()) {
            return Optional.empty();
        }
        var n = new BigInteger(s);
        if (n.signum() <= 0 || n.compareTo(MAX_U64) > 0) {
            return Optional.empty();
        }
        return Optional.of(n);
    }

    public record TrimResult(boolean ok, String valueOrMessage) {
        public static TrimResult ok(String v) {
            return new TrimResult(true, v);
        }

        public static TrimResult err(String m) {
            return new TrimResult(false, m);
        }
    }

    /** .length() is UTF-16 units — the upstream reference semantics. */
    public static TrimResult trimBody(Object body) {
        if (!(body instanceof String s)) {
            return TrimResult.err("body is required");
        }
        var t = s.strip();
        if (t.isEmpty()) {
            return TrimResult.err("body is required");
        }
        if (t.codePointCount(0, t.length()) > 500) {
            return TrimResult.err("body must be at most 500 characters");
        }
        return TrimResult.ok(t);
    }
}
