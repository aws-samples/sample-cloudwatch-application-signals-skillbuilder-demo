package com.example.deliveryapi;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.util.HtmlUtils;
import org.springframework.http.ResponseEntity;
import org.springframework.http.HttpStatus;

import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.DynamoDbException;
import software.amazon.awssdk.services.dynamodb.model.ProvisionedThroughputExceededException;
import software.amazon.awssdk.auth.credentials.WebIdentityTokenFileCredentialsProvider;
import software.amazon.awssdk.regions.Region;

import java.util.HashMap;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.apache.commons.lang3.StringUtils;

@RestController
@RequestMapping("/api/delivery")
public class DeliveryController {

    private static final Logger logger = LoggerFactory.getLogger(DeliveryController.class);

    private final DynamoDbClient dynamoDbClient;
    private final String tableName;
    public DeliveryController(@Value("${aws.region}") String awsRegion,
                              @Value("${dynamodb.table.name}") String tableName) {
        this.dynamoDbClient = DynamoDbClient.builder()
                .credentialsProvider(WebIdentityTokenFileCredentialsProvider.create())
                .region(Region.of(awsRegion))
                .build();
        this.tableName = tableName;
        logger.info("DeliveryController initialized with region: {} and table: {}", awsRegion, tableName);
    }
    
    /**
     * Helper method to extract values from JSON string without using Jackson deserialization
     */
    private String extractValueFromJson(String json, String key) {
        String searchKey = "\"" + key + "\"";
        int keyIndex = json.indexOf(searchKey);
        if (keyIndex == -1) {
            return null;
        }
        
        int colonIndex = json.indexOf(':', keyIndex);
        if (colonIndex == -1) {
            return null;
        }
        
        // Skip whitespace after colon
        int valueStartIndex = colonIndex + 1;
        while (valueStartIndex < json.length() && Character.isWhitespace(json.charAt(valueStartIndex))) {
            valueStartIndex++;
        }
        
        if (valueStartIndex >= json.length()) {
            return null;
        }
        
        char firstChar = json.charAt(valueStartIndex);
        
        // Handle string values
        if (firstChar == '"') {
            int valueEndIndex = json.indexOf('"', valueStartIndex + 1);
            if (valueEndIndex == -1) {
                return null;
            }
            return json.substring(valueStartIndex + 1, valueEndIndex);
        }
        
        // Handle numeric values
        if (Character.isDigit(firstChar) || firstChar == '-') {
            int valueEndIndex = valueStartIndex;
            while (valueEndIndex < json.length() && 
                  (Character.isDigit(json.charAt(valueEndIndex)) || 
                   json.charAt(valueEndIndex) == '.' || 
                   json.charAt(valueEndIndex) == '-')) {
                valueEndIndex++;
            }
            return json.substring(valueStartIndex, valueEndIndex);
        }
        
        return null;
    }

    @PostMapping
    public ResponseEntity<String> createDelivery(@RequestBody String deliveryDetails) {
        logger.info("Received delivery request: {}", StringUtils.replaceEach(deliveryDetails, new String[]{"\n", "\r"}, new String[]{"_", "_"}));
        try {
            // Extract orderId directly using string operations to avoid Jackson compatibility issues
            String orderId = extractValueFromJson(deliveryDetails, "orderId");
            if (orderId == null) {
                return ResponseEntity.badRequest().body("Missing orderId in request");
            }
            
            String id = orderId + "-" + System.currentTimeMillis();
            
            // Create item map directly
            Map<String, AttributeValue> item = new HashMap<>();
            item.put("Id", AttributeValue.builder().s(HtmlUtils.htmlEscape(id)).build());
            
            // Add orderId
            item.put("orderId", AttributeValue.builder().s(HtmlUtils.htmlEscape(orderId)).build());
            
            // Extract other common fields
            String customerName = extractValueFromJson(deliveryDetails, "customerName");
            if (customerName != null) {
                item.put("customerName", AttributeValue.builder().s(HtmlUtils.htmlEscape(customerName)).build());
            }
            
            String totalAmount = extractValueFromJson(deliveryDetails, "totalAmount");
            if (totalAmount != null) {
                item.put("totalAmount", AttributeValue.builder().s(HtmlUtils.htmlEscape(totalAmount)).build());
            }
            
            String shippingAddress = extractValueFromJson(deliveryDetails, "shippingAddress");
            if (shippingAddress != null) {
                item.put("shippingAddress", AttributeValue.builder().s(HtmlUtils.htmlEscape(shippingAddress)).build());
            }
            
            // Store the raw JSON as a string to preserve all data
            item.put("rawData", AttributeValue.builder().s(deliveryDetails).build());

            PutItemRequest putItemRequest = PutItemRequest.builder()
                .tableName(tableName)
                .item(item)
                .build();

            logger.info("Putting item into DynamoDB: {}", StringUtils.replaceEach(item.toString(), new String[]{"\n", "\r"}, new String[]{"_", "_"}));
            dynamoDbClient.putItem(putItemRequest);
            
            logger.info("Delivery information stored successfully with Id: {}", StringUtils.replaceEach(id, new String[]{"\n", "\r"}, new String[]{"_", "_"}));
            return ResponseEntity.ok("Delivery information stored successfully with Id: " + HtmlUtils.htmlEscape(id));
        } catch (ProvisionedThroughputExceededException e) {
            logger.warn("DynamoDB write capacity exceeded: ", e);
            return ResponseEntity
                .status(HttpStatus.TOO_MANY_REQUESTS)
                .body("Unable to process request due to write capacity limits. Please try again later.");
        } catch (DynamoDbException e) {
            logger.error("Error interacting with DynamoDB: ", e);
            return ResponseEntity
                .status(HttpStatus.INTERNAL_SERVER_ERROR)
                .body("Error storing delivery information. Please try again later.");
        } catch (RuntimeException e) {
            logger.error("Unexpected runtime error: ", e);
            return ResponseEntity
                .status(HttpStatus.INTERNAL_SERVER_ERROR)
                .body("An unexpected error occurred. Please contact support.");

        }
    }



    @GetMapping("/health")
    public ResponseEntity<String> healthCheck() {
        logger.info("Health check endpoint called");
        return ResponseEntity.ok("Delivery API is healthy");
    }
}
