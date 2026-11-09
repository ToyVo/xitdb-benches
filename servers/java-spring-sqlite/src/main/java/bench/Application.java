package bench;

import java.time.Instant;
import java.util.HashMap;
import java.util.Map;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class Application {

    public static void main(String[] args) throws Exception {
        String dbPath = env("XITDB_PATH", "feed.db");
        String secret = env("JWT_SECRET", "twelve-dollar-challenge");
        String host = env("HOST", "127.0.0.1");
        int port = parsePort(env("PORT", "3000"));
        Shared.store = Store.openStore(dbPath, secret);
        Shared.secret = secret;
        Shared.boot = Instant.now();
        var app = new SpringApplication(Application.class);
        Map<String, Object> props = new HashMap<>();
        props.put("server.address", host);
        props.put("server.port", port);
        app.setDefaultProperties(props);
        System.out.println("serving " + dbPath + " on http://" + host + ":" + port);
        app.run(args);
    }

    static String env(String key, String def) {
        String v = System.getenv(key);
        return v == null || v.isEmpty() ? def : v;
    }

    static int parsePort(String s) {
        try {
            return Integer.parseInt(s);
        } catch (NumberFormatException e) {
            return 3000;
        }
    }
}
