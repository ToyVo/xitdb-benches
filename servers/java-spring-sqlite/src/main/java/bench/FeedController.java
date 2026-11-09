package bench;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.resource.NoResourceFoundException;

@RestController
public class FeedController {

    private static final ObjectMapper JSON = new ObjectMapper();

    static ResponseEntity<String> json(int status, String body) {
        return ResponseEntity.status(status)
                .contentType(MediaType.APPLICATION_JSON)
                .body(body);
    }

    static ResponseEntity<String> err(int status, String msg) {
        return json(status, "{\"error\":\"" + msg + "\"}");
    }

    record Authed(BigInteger userId, String username, String error) {}

    static Authed authed(String header) {
        if (header == null || !header.startsWith("Bearer ")) {
            return new Authed(null, null, "missing bearer token");
        }
        var r = Auth.verifyJwt(header.substring("Bearer ".length()), Shared.secret);
        if (r instanceof Auth.AuthResult.Err e) {
            return new Authed(null, null, e.message());
        }
        var ok = (Auth.AuthResult.Ok) r;
        return new Authed(ok.userId(), ok.username(), null);
    }

    @GetMapping("/health")
    public ResponseEntity<String> health() {
        if (!Shared.store.health()) {
            return json(
                    503,
                    "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"read failed\"}");
        }
        long uptime = Duration.between(Shared.boot, Instant.now()).getSeconds();
        return json(200, "{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":" + uptime + "}");
    }

    @GetMapping("/feed")
    public ResponseEntity<String> feed() {
        try {
            var sb = new StringBuilder("{\"posts\":[");
            var posts = Shared.store.getFeed();
            for (int i = 0; i < posts.size(); i++) {
                if (i > 0) {
                    sb.append(',');
                }
                sb.append(Store.postJson(posts.get(i)));
            }
            return json(200, sb.append("]}").toString());
        } catch (Exception e) {
            return err(500, "internal server error");
        }
    }

    @GetMapping("/posts/{id}")
    public ResponseEntity<String> getPost(@PathVariable String id) {
        var parsed = Validate.validPostId(id);
        if (parsed.isEmpty()) {
            return err(400, "invalid post id");
        }
        try {
            var found = Shared.store.getPost(parsed.get().toString());
            if (found.isEmpty()) {
                return err(404, "post not found");
            }
            return json(200, "{\"post\":" + Store.postJson(found.get()) + "}");
        } catch (Exception e) {
            return err(500, "internal server error");
        }
    }

    @PostMapping("/posts")
    public ResponseEntity<String> createPost(
            @RequestHeader(value = "Authorization", required = false) String auth,
            @RequestBody(required = false) byte[] raw) {
        var a = authed(auth);
        if (a.error() != null) {
            return err(401, a.error());
        }
        JsonNode value;
        try {
            value = JSON.readTree(raw == null ? "" : new String(raw, StandardCharsets.UTF_8));
        } catch (Exception e) {
            return err(400, "malformed JSON body");
        }
        var body = value.isObject() ? value.get("body") : null;
        var checked =
                Validate.trimBody(body != null && body.isTextual() ? body.asText() : marker());
        if (!checked.ok()) {
            return err(400, checked.valueOrMessage());
        }
        try {
            var p = Shared.store.createPost(a.username(), checked.valueOrMessage());
            return json(201, "{\"post\":" + Store.postJson(p) + "}");
        } catch (Exception e) {
            return err(500, "internal server error");
        }
    }

    // Sentinel distinguishing absent/non-textual body (required) — never a real body.
    static final Object MARKER = new Object();

    static Object marker() {
        return MARKER;
    }

    @PostMapping("/posts/{id}/like")
    public ResponseEntity<String> likePost(
            @PathVariable String id,
            @RequestHeader(value = "Authorization", required = false) String auth) {
        // Auth first, then id (spec order).
        var a = authed(auth);
        if (a.error() != null) {
            return err(401, a.error());
        }
        var parsed = Validate.validPostId(id);
        if (parsed.isEmpty()) {
            return err(400, "invalid post id");
        }
        try {
            var r = Shared.store.likePost(parsed.get().toString(), a.userId().toString());
            if (!r.found()) {
                return err(404, "post not found");
            }
            return json(
                    r.already() ? 200 : 201,
                    "{\"liked\":true,\"already_liked\":"
                            + r.already()
                            + ",\"post_id\":"
                            + parsed.get()
                            + "}");
        } catch (Exception e) {
            return err(500, "internal server error");
        }
    }

    @ControllerAdvice
    public static class Errors {
        @ExceptionHandler(NoResourceFoundException.class)
        public ResponseEntity<String> notFound() {
            return err(404, "not found");
        }
    }
}
