package bench;

import java.time.Instant;

/** Process-wide collaborators, set once in main before Boot starts. */
public final class Shared {

    private Shared() {}

    public static volatile Store store;
    public static volatile String secret;
    public static volatile Instant boot = Instant.now();
}
