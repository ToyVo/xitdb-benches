package bench;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.core.env.Environment;

@SpringBootTest
public class WebConfigTest {

    @Autowired
    Environment env;

    @Test
    void keepAliveTimeoutMeetsNginxRule() {
        // Tomcat defaults to 60s — below the >=65s rule. Proves the property
        // is applied (M3 nginx proves the socket behavior).
        assertEquals("70000", env.getProperty("server.tomcat.keep-alive-timeout"));
    }

    @Test
    void unknownPathsThrowForAdvice() {
        assertEquals(
                "true", env.getProperty("spring.mvc.throw-exception-if-no-handler-found"));
    }
}
