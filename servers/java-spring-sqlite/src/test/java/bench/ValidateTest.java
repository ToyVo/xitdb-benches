package bench;

import static org.junit.jupiter.api.Assertions.*;

import java.util.Optional;
import org.junit.jupiter.api.Test;

public class ValidateTest {

    @Test
    void feedKeyFormatAndOrder() {
        assertEquals(
                "2025-01-01T00:00:00.000Z\0" + "0000000007",
                Validate.feedKey("2025-01-01T00:00:00.000Z", 7L));
        assertTrue(
                Validate.feedKey("2025-01-01T00:00:00.000Z", 7)
                        .compareTo(Validate.feedKey("2025-01-01T00:00:00.000Z", 8))
                        < 0);
    }

    @Test
    void postIdTable() {
        assertEquals(1L, Validate.validPostId("1").orElseThrow().longValueExact());
        assertEquals(
                999999999L, Validate.validPostId("999999999").orElseThrow().longValueExact());
        assertTrue(Validate.validPostId("0").isEmpty());
        assertTrue(Validate.validPostId("-1").isEmpty());
        assertTrue(Validate.validPostId("abc").isEmpty());
        assertTrue(Validate.validPostId("1.5").isEmpty());
        assertTrue(Validate.validPostId("").isEmpty());
        assertTrue(Validate.validPostId(null).isEmpty());
    }

    @Test
    void postIdOverflow() {
        // 2^64 -> rejected; u64 max -> present (full range like Rust/Go/Zig)
        assertTrue(Validate.validPostId("18446744073709551616").isEmpty());
        assertEquals(
                "18446744073709551615",
                Validate.validPostId("18446744073709551615").orElseThrow().toString());
    }

    @Test
    void trimBodyTable() {
        assertEquals(Validate.TrimResult.ok("hi"), Validate.trimBody("  hi "));
        assertEquals(Validate.TrimResult.err("body is required"), Validate.trimBody("   "));
        assertEquals(Validate.TrimResult.err("body is required"), Validate.trimBody(123));
        assertEquals(Validate.TrimResult.err("body is required"), Validate.trimBody(null));
        assertEquals(
                Validate.TrimResult.err("body must be at most 500 characters"),
                Validate.trimBody("a".repeat(501)));
        assertEquals(Validate.TrimResult.ok("b".repeat(500)), Validate.trimBody("b".repeat(500)));
    }

    @Test
    void trimBodyMultibyte() {
        // codePointCount: 500 é accepted (rune semantics like Rust/Go/Zig)
        assertEquals(
                Validate.TrimResult.ok("é".repeat(500)), Validate.trimBody("é".repeat(500)));
    }

}
