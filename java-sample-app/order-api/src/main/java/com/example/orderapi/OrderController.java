package com.example.orderapi;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.client.HttpStatusCodeException;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestTemplate;
import org.springframework.http.ResponseEntity;
import org.springframework.http.HttpStatus;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.apache.commons.lang3.StringUtils;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

    private static final Logger logger = LoggerFactory.getLogger(OrderController.class);

    @Autowired
    private RestTemplate restTemplate;

    @Value("${delivery.api.url}")
    private String deliveryApiUrl;

    @PostMapping
    public ResponseEntity<String> createOrder(@RequestBody String orderDetails) {
        logger.info("Received order request: {}", StringUtils.replaceEach(orderDetails, new String[]{"\n", "\r"}, new String[]{"_", "_"}));
        try {
            logger.info("Sending order to Delivery API: {}", deliveryApiUrl);
            String response = restTemplate.postForObject(deliveryApiUrl, orderDetails, String.class);
            logger.info("Received response from Delivery API: {}", StringUtils.replaceEach(response, new String[]{"\n", "\r"}, new String[]{"_", "_"}));
            return ResponseEntity.ok(response);
        } catch (HttpStatusCodeException e) {
            if (e.getStatusCode() == HttpStatus.TOO_MANY_REQUESTS) {
                logger.error("Delivery API throttled by DynamoDB: {}", StringUtils.replaceEach(e.getResponseBodyAsString(), new String[]{"\n", "\r"}, new String[]{"_", "_"}));
                return ResponseEntity
                    .status(HttpStatus.INTERNAL_SERVER_ERROR)
                    .body("Internal server error: Please try again later");
            } else {
                logger.error("Error from Delivery API: ", e);
                return ResponseEntity
                    .status(e.getStatusCode())
                    .body("Error processing order: Please try again later");
            }
        } catch (RestClientException e) {
            logger.error("Error communicating with Delivery API: ", e);
            return ResponseEntity
                .status(HttpStatus.INTERNAL_SERVER_ERROR)
                .body("Error processing order: Please try again later");
        }
    }



    @GetMapping("/health")
    public ResponseEntity<String> healthCheck() {
        logger.info("Health check endpoint called");
        return ResponseEntity.ok("Order API is healthy");
    }
}
