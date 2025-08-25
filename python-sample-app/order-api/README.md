# Order API Documentation

The Order API is a FastAPI-based microservice that handles order creation and validation. It serves as the entry point for the direct order processing system and makes HTTP calls to the Delivery API for immediate order processing.

## Overview

- **Framework**: FastAPI
- **Port**: 8080
- **Language**: Python 3.12+
- **Architecture**: Async/await with Pydantic validation

## API Endpoints

### POST /api/orders

Creates a new order and sends it directly to the Delivery API for synchronous processing.

**Request Body:**
```json
{
  "order_id": "ORD-12345",           // Optional: Auto-generated if not provided
  "customer_name": "John Doe",       // Required: Customer name (1-200 chars)
  "items": [                         // Required: Array of order items (1-50 items)
    {
      "product_id": "PROD-001",      // Required: Product identifier
      "quantity": 2,                 // Required: Quantity (1-1000)
      "price": 29.99                 // Required: Price per unit
    }
  ],
  "total_amount": 59.98,            // Optional: Calculated if not provided
  "shipping_address": "123 Main St, Anytown, ST 12345"  // Required: Shipping address (10-500 chars)
}
```

**Response (200 OK):**
```json
{
  "order_id": "ORD-12345",
  "status": "processed",
  "message": "Order processed successfully",
  "customer_name": "John Doe",
  "total_amount": 59.98,
  "item_count": 1,
  "created_at": "2024-01-15T10:30:00.000Z",
  "processed_at": "2024-01-15T10:30:01.234Z",
  "trace_id": "abc123def456"
}
```

**Error Responses:**
- `400 Bad Request`: Invalid order data or validation errors
- `500 Internal Server Error`: Delivery API communication failures
- `502 Bad Gateway`: Delivery API unavailable or returning errors
- `503 Service Unavailable`: Delivery API timeout

### GET /api/orders/health

Health check endpoint that verifies the service status and connectivity to the Delivery API.

**Response (200 OK):**
```json
{
  "status": "healthy",
  "service": "order-api",
  "version": "1.0.0",
  "timestamp": "2024-01-15T10:30:00.000Z",
  "dependencies": {
    "delivery_api": {
      "status": "healthy",
      "url": "http://python-delivery-api:5000"
    }
  }
}
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Server bind address |
| `PORT` | `8080` | Server port |
| `DEBUG` | `false` | Enable debug mode |
| `DELIVERY_API_URL` | `null` | Delivery API URL for direct HTTP communication |
| `AWS_REGION` | `us-east-1` | AWS region for RDS operations |
| `OTEL_SERVICE_NAME` | `order-api` | OpenTelemetry service name |
| `OTEL_SERVICE_VERSION` | `1.0.0` | Service version |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `null` | OpenTelemetry collector endpoint |
| `OTEL_RESOURCE_ATTRIBUTES` | `null` | Additional service metadata for tracing |
| `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED` | `true` | Enable automatic log correlation |
| `LOG_LEVEL` | `INFO` | Logging level (DEBUG, INFO, WARNING, ERROR) |
| `LOG_FORMAT` | `json` | Log format (json, console) |
| `HTTP_TIMEOUT` | `30` | HTTP request timeout for Delivery API calls in seconds |

### Configuration Example

```bash
# Development configuration
export DEBUG=true
export LOG_LEVEL=DEBUG
export LOG_FORMAT=console
export DELIVERY_API_URL=http://localhost:5000

# Production configuration
export DEBUG=false
export LOG_LEVEL=INFO
export LOG_FORMAT=json
export DELIVERY_API_URL=http://python-delivery-api:5000
export AWS_REGION=us-east-2
export OTEL_SERVICE_NAME=python-order-api
export OTEL_RESOURCE_ATTRIBUTES=service.namespace=python-sample-app,service.version=1.0.0
export OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
```

## Data Models

### OrderItem

```python
class OrderItem(BaseModel):
    product_id: str      # 1-100 characters, alphanumeric with hyphens/underscores
    quantity: int        # 1-1000
    price: Decimal       # Positive decimal with 2 decimal places
```

### OrderRequest

```python
class OrderRequest(BaseModel):
    order_id: Optional[str] = None        # Auto-generated if not provided
    customer_name: str                    # 1-200 characters, letters/spaces/hyphens/apostrophes
    items: List[OrderItem]                # 1-50 items
    total_amount: Optional[Decimal] = None # Calculated if not provided
    shipping_address: str                 # 10-500 characters
```

### OrderResponse

```python
class OrderResponse(BaseModel):
    order_id: str
    status: str
    message: str
    customer_name: str
    total_amount: Decimal
    item_count: int
    created_at: datetime
    trace_id: Optional[str]
```

## Features

### Async Processing
- Built on FastAPI's async/await architecture
- Non-blocking HTTP calls to Delivery API
- High concurrency support for order processing

### Request Validation
- Automatic Pydantic model validation
- Type safety with Python type hints
- Comprehensive error messages

### Error Handling
- Structured error responses with trace IDs
- Proper HTTP status codes
- Detailed logging for debugging
- Retry logic for Delivery API communication failures

### Observability
- OpenTelemetry auto-instrumentation for FastAPI and HTTP client operations
- Structured logging with trace correlation
- Health check endpoint with Delivery API connectivity verification
- Automatic trace propagation to HTTP service calls

## Usage Examples

### Creating an Order

```bash
curl -X POST http://localhost:8080/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "customer_name": "Jane Smith",
    "items": [
      {
        "product_id": "LAPTOP-001",
        "quantity": 1,
        "price": 999.99
      },
      {
        "product_id": "MOUSE-001",
        "quantity": 2,
        "price": 25.50
      }
    ],
    "shipping_address": "456 Oak Ave, Springfield, IL 62701"
  }'
```

### Health Check

```bash
curl http://localhost:8080/api/orders/health
```

### Interactive API Documentation

When running the service, visit:
- Swagger UI: `http://localhost:8080/docs`
- ReDoc: `http://localhost:8080/redoc`

## Development

### Running Locally

1. **Install dependencies:**
   ```bash
   cd order-api
   pip install -r requirements.txt
   ```

2. **Set environment variables:**
   ```bash
   export DELIVERY_API_URL=http://localhost:5000
   export AWS_REGION=us-east-2
   export DEBUG=true
   export LOG_LEVEL=DEBUG
   ```

3. **Run the service:**
   ```bash
   python main.py
   # or
   uvicorn main:app --host 0.0.0.0 --port 8080 --reload
   ```

### Testing

```bash
# Test with curl
curl -X POST http://localhost:8080/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "customer_name": "Test User",
    "items": [{"product_id": "TEST-001", "quantity": 1, "price": 10.00}],
    "shipping_address": "123 Test St, Test City, TC 12345"
  }'

# Check health
curl http://localhost:8080/api/orders/health
```

## Deployment

### Docker

```dockerfile
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
EXPOSE 8080

CMD ["python", "main.py"]
```

### Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: python-order-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: python-order-api
  template:
    metadata:
      labels:
        app: python-order-api
    spec:
      containers:
      - name: order-api
        image: your-registry/python-order-api:latest
        ports:
        - containerPort: 8080
        env:
        - name: DELIVERY_API_URL
          value: "http://python-delivery-api:8081"
        - name: LOG_LEVEL
          value: "INFO"
```

## Troubleshooting

### Common Issues

1. **Service startup fails:**
   ```bash
   # Check logs
   kubectl logs -l app=python-order-api
   
   # Check environment variables
   kubectl exec -it <pod-name> -- env | grep -E "(DELIVERY_API|LOG_|DEBUG)"
   ```

2. **Delivery API connection errors:**
   ```bash
   # Test Delivery API accessibility
   kubectl exec -it <order-api-pod> -- curl http://python-delivery-api:5000/api/delivery/health
   
   # Check service discovery
   kubectl get svc python-delivery-api
   
   # Verify network connectivity
   kubectl exec -it <order-api-pod> -- nslookup python-delivery-api
   ```

3. **Validation errors:**
   - Check request payload format
   - Verify required fields are present
   - Ensure data types match model requirements

### Performance Tuning

- **HTTP Configuration**: Adjust `HTTP_TIMEOUT` for Delivery API calls
- **Logging**: Use `json` format in production, `console` for development
- **Concurrency**: FastAPI handles multiple requests concurrently by default
- **Connection Pooling**: HTTP client uses connection pooling for efficient service calls

### Monitoring

- **Metrics**: HTTP client metrics through OpenTelemetry instrumentation
- **Traces**: Distributed tracing from HTTP requests to Delivery API calls
- **Health**: Monitor `/api/orders/health` endpoint with Delivery API connectivity
- **Logs**: Structured JSON logs with trace correlation
- **Service Metrics**: Monitor response times, success rates, and error rates for service calls