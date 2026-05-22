package com.fyntrac.data;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;

@SpringBootTest(properties = {
    "memcached.host=0.0.0.0",
    "spring.data.mongodb.host=0.0.0.0",
    "spring.pulsar.client.service-url=pulsar://0.0.0.0:6650"
})
class DataApplicationTests {

	@Test
	void contextLoads() {
	}

}
