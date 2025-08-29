# HTTP Client Service

A comprehensive HTTP client service for the Order API that provides robust communication with the Delivery API service. This service implements enterprise-grade patterns including retry logic with exponential backoff, comprehensive logging, and error handling.

## Features

### 🔁 Retry Logic with Exponential Backoff
- Automatic retry of failed requests with intelligent backoff
- Exponential delay calculation with jitter to prevent thundering herd
- Configurable maximum retry attempts
- Smart retry decision based on error type (doesn't retry 4xx client errors)

### 📊 Comprehensive Logging
- Structured JSON logging for all HTTP operations
- Request/response timing and correlation ID tracking
- Detailed error logging with context
- Sanitized header logging (removes sensitive information)

### 🔗 Connection Pooling
- HTTP/HTTPS agent configuration with keep-alive
- Configurable socket limits and timeouts
- Efficient connection reuse

### 🛡️ Error Handling
- Transforms HTTP errors to application-specific error types
- Proper error categorization and status code mapping
- Detailed error context for debugging

## Configuration

The service uses configuration from `config/index.js`:

```javascript
{
  deliveryApi: {
    url: 'http://delivery-api-service:5000',
    timeout: 30000,
    retries: 3
  }
}
```

## Usage

### Basic Initialization

```javascript
const { httpClientService } = require('../services');

// Initialize the service (call once at application startup)
httpClientService.initialize();
```

### Sending Orders to Delivery API

```javascript
const orderData = {
  order_id: 'ORD-12345',
  customer_name: 'John Doe',
  items: [{ product_id: 'PROD-001', quantity: 2, price: 29.99 }],
  total_amount: 59.98,
  shipping_address: '123 Main St, Anytown, USA 12345'
};

try {
  const response = await httpClientService.sendOrderToDelivery(orderData, {
    correlationId: 'unique-correlation-id'
  });
  console.log('Order sent successfully:', response);
} catch (error) {
  console.error('Failed to send order:', error.message);
}
```

### Health Checks

```javascript
try {
  const healthResult = await httpClientService.checkDeliveryHealth({
    correlationId: 'health-check-id'
  });
  console.log('Delivery API health:', healthResult);
} catch (error) {
  console.error('Health check failed:', error.message);
}
```

### Generic HTTP Methods

```javascript
// POST request
const postResponse = await httpClientService.post('/api/endpoint', data, {
  correlationId: 'request-id'
});

// GET request
const getResponse = await httpClientService.get('/api/endpoint', {
  correlationId: 'request-id'
});
```

## Error Types

The service transforms HTTP errors into application-specific error types:

- **ServiceUnavailableError**: For timeouts and 5xx errors
- **AppError**: For 4xx client errors with specific error codes

## Logging Output

The service provides structured logging for all operations:

```json
{
  "level": "info",
  "message": "HTTP request completed successfully",
  "method": "POST",
  "url": "/api/delivery",
  "status": 200,
  "duration": 245,
  "correlationId": "abc-123",
  "responseSize": 156,
  "service": "order-api",
  "timestamp": "2024-01-01T12:00:00.000Z"
}
```

## Testing

The service includes comprehensive unit tests covering:

- Initialization and configuration
- Retry logic and exponential backoff
- Header sanitization
- Error handling scenarios

Run tests with:
```bash
npm test -- --testPathPattern=httpClient.test.js
```

## Performance Considerations

- **Connection Pooling**: Reuses HTTP connections for better performance
- **Timeout Management**: Configurable timeouts prevent hanging requests
- **Memory Management**: Proper cleanup of connections and resources
- **Jitter in Backoff**: Prevents thundering herd problems during recovery

## Monitoring and Observability

The service provides several monitoring capabilities:

1. **Request Timing**: Response time tracking for all requests
2. **Error Categorization**: Detailed error logging with context
3. **Correlation ID Tracking**: Request tracing across service boundaries

## Graceful Shutdown

```javascript
// Clean shutdown of HTTP connections
await httpClientService.shutdown();
```

This ensures all keep-alive connections are properly closed during application shutdown.