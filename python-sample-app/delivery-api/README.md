# Delivery API Documentation

The Delivery API is a Flask-based REST service that receives order processing requests via HTTP and stores order data in MySQL on AWS RDS. It operates as a standard web service for synchronous order processing.

## Overview

- **Framework**: Flask
- **Port**: 5000
- **Language**: Python 3.12+
- **Architecture**: REST API service with MySQL RDS integration
- **Processing Mode**: Synchronous HTTP request processing

## HTTP Request Processing

### Direct Order Processing

The service receives HTTP POST requests from the Order API and processes them synchronously.

**HTTP Request Format:**
```json
{
  "order_id": "ORD-12345",           // Required: Order identifier
  "customer_name": "John Doe",       // Required: Customer name (1-200 chars)
  "items": [                         // Required: Array of order items
    {
      "product_id": "PROD-001",      // Required: Product identifier
      "quantity": 2,                 // Required: Positive integer
      "price": 29.99                 // Required: Price per unit
    }
  ],
  "total_amount": 59.98,            // Required: Total order amount
  "shipping_address": "123 Main St, Anytown, ST 12345",  // Required: Shipping address (1-500 chars)
  "timestamp": "2024-01-15T10:30:00.000Z"  // Request timestamp
}
```

**Processing Behavior:**
- Requests are processed immediately upon receipt
- Successfully processed requests return HTTP 200 with confirmation
- Failed requests return appropriate HTTP error codes
- Database operations are wrapped in transactions for consistency
- Processing includes automatic OpenTelemetry trace generation

**Error Handling:**
- `Database Connection Errors`: HTTP 500 with retry suggestion
- `SQL Errors`: Transaction rollback and HTTP 500 response
- `Request Format Errors`: HTTP 400 with validation details
- `Timeout Errors`: HTTP 408 with timeout information

## API Endpoints

### POST /api/delivery

Processes order data and stores it in MySQL database.

**Request Body:**
```json
{
  "order_id": "ORD-12345",
  "customer_name": "John Doe",
  "items": [
    {
      "product_id": "PROD-001",
      "quantity": 2,
      "price": 29.99
    }
  ],
  "total_amount": 59.98,
  "shipping_address": "123 Main St, Anytown, ST 12345",
  "timestamp": "2024-01-15T10:30:00.000Z"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "message": "Order processed successfully",
  "order_id": "ORD-12345",
  "processed_at": "2024-01-15T10:30:01.234Z",
  "database_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "trace_id": "abc123def456"
}
```

**Error Responses:**
- `400 Bad Request`: Invalid request data or validation errors
- `500 Internal Server Error`: Database operation failures
- `408 Request Timeout`: Database connection timeout

### GET /api/delivery/health

Health check endpoint that verifies service status and MySQL database connection.

**Response (200 OK):**
```json
{
  "status": "healthy",
  "service": "delivery-api",
  "version": "1.0.0",
  "timestamp": "2024-01-15T10:30:00.000Z",
  "dependencies": {
    "mysql_database": {
      "status": "healthy",
      "host": "python-orders-db.cluster-xyz.us-east-2.rds.amazonaws.com",
      "database": "orders_db"
    }
  },
  "trace_id": "abc123def456"
}
```

**Response (503 Service Unavailable):**
```json
{
  "status": "degraded",
  "service": "delivery-api",
  "version": "1.0.0",
  "timestamp": "2024-01-15T10:30:00.000Z",
  "dependencies": {
    "mysql_database": {
      "status": "unhealthy",
      "host": "python-orders-db.cluster-xyz.us-east-2.rds.amazonaws.com",
      "database": "orders_db",
      "error": "Connection timeout"
    }
  },
  "trace_id": "abc123def456"
}
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Server bind address |
| `PORT` | `5000` | Server port |
| `DEBUG` | `false` | Enable debug mode |
| `AWS_REGION` | `us-east-1` | AWS region for RDS operations |
| `MYSQL_HOST` | `null` | RDS MySQL endpoint hostname |
| `MYSQL_PORT` | `3306` | MySQL port |
| `MYSQL_DATABASE` | `orders_db` | MySQL database name |
| `MYSQL_USER` | `admin` | MySQL username |
| `MYSQL_PASSWORD` | `null` | MySQL password (from AWS Secrets Manager) |
| `MYSQL_POOL_SIZE` | `10` | Database connection pool size |
| `MYSQL_POOL_TIMEOUT` | `30` | Connection pool timeout in seconds |
| `OTEL_SERVICE_NAME` | `delivery-api` | OpenTelemetry service name |
| `OTEL_SERVICE_VERSION` | `1.0.0` | Service version |
| `OTEL_RESOURCE_ATTRIBUTES` | `null` | Additional service metadata for tracing |
| `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED` | `true` | Enable automatic log correlation |
| `LOG_LEVEL` | `INFO` | Logging level (DEBUG, INFO, WARNING, ERROR) |
| `LOG_FORMAT` | `json` | Log format (json, console) |

### Configuration Example

```bash
# Development configuration
export DEBUG=true
export LOG_LEVEL=DEBUG
export LOG_FORMAT=console
export MYSQL_HOST=localhost
export MYSQL_PASSWORD=password

# Production configuration
export DEBUG=false
export LOG_LEVEL=INFO
export LOG_FORMAT=json
export AWS_REGION=us-east-2
export MYSQL_HOST=python-orders-db.cluster-xyz.us-east-2.rds.amazonaws.com
export MYSQL_DATABASE=orders_db
export MYSQL_USER=admin
export MYSQL_PASSWORD=$(aws secretsmanager get-secret-value --secret-id rds-mysql-password --query SecretString --output text)
export OTEL_SERVICE_NAME=python-delivery-api
export OTEL_RESOURCE_ATTRIBUTES=service.namespace=python-sample-app,service.version=1.0.0
export OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
```

## Data Storage

### MySQL Database Schema

**Database Name**: `orders_db`

**Table Name**: `orders`

**Schema**:
```sql
CREATE TABLE orders (
    id VARCHAR(36) PRIMARY KEY,
    order_id VARCHAR(50) NOT NULL,
    customer_name VARCHAR(255) NOT NULL,
    total_amount DECIMAL(10,2) NOT NULL,
    shipping_address TEXT NOT NULL,
    raw_data JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_order_id (order_id),
    INDEX idx_created_at (created_at)
);
```

**Sample Record**:
```json
{
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "order_id": "ORD-12345",
  "customer_name": "John Doe",
  "total_amount": 59.98,
  "shipping_address": "123 Main St, Anytown, ST 12345",
  "raw_data": "{\"items\": [...], \"timestamp\": \"...\"}",
  "created_at": "2024-01-15 10:30:00",
  "updated_at": "2024-01-15 10:30:00"
}
```

### Data Validation

The service validates incoming data with the following rules:

- **order_id**: Required, non-empty string, max 100 characters
- **customer_name**: Required, non-empty string, max 200 characters
- **total_amount**: Required, non-negative decimal number
- **shipping_address**: Required, non-empty string, max 500 characters
- **items**: Optional array of item objects
  - **product_id**: Required for each item, non-empty string
  - **quantity**: Required for each item, positive integer
  - **price**: Optional for each item, non-negative decimal

## Features

### MySQL Integration
- Connection pooling with SQLAlchemy for efficient database access
- Automatic transaction management with rollback on errors
- Prepared statements for SQL injection prevention
- Connection health monitoring and automatic reconnection

### HTTP Request Processing
- JSON parsing and validation
- Decimal precision handling for monetary values
- Structured error responses with proper HTTP status codes

### Error Handling
- HTTP request processing with proper status codes
- Database connection error recovery
- Transaction rollback on SQL errors
- Comprehensive error logging with trace correlation

### Observability
- OpenTelemetry auto-instrumentation for Flask and SQLAlchemy
- Structured logging with trace correlation across HTTP request processing
- Health check with MySQL dependency status
- Automatic trace propagation from HTTP requests to database operations

## Usage Examples

### Processing Orders via HTTP

```bash
# Send order to Delivery API (simulates Order API call)
curl -X POST http://localhost:5000/api/delivery \
  -H "Content-Type: application/json" \
  -d '{
    "order_id": "TEST-001",
    "customer_name": "Test User",
    "items": [{"product_id": "TEST-PROD", "quantity": 1, "price": 25.00}],
    "total_amount": 25.00,
    "shipping_address": "123 Test St, Test City, TC 12345",
    "timestamp": "2024-01-15T10:30:00.000Z"
  }'

# Check health
curl http://localhost:5000/api/delivery/health

# Verify data was processed and stored in MySQL
mysql -h localhost -u root -ppassword orders_db -e "SELECT * FROM orders WHERE order_id = 'TEST-001';"
```

## Development

### Running Locally

1. **Install dependencies:**
   ```bash
   cd delivery-api
   pip install -r requirements.txt
   ```

2. **Set up local MySQL database:**
   ```bash
   # Using Docker
   docker run --name local-mysql \
     -e MYSQL_ROOT_PASSWORD=password \
     -e MYSQL_DATABASE=orders_db \
     -p 3306:3306 -d mysql:8.0
   
   # Wait for MySQL to start, then create table
   mysql -h localhost -u root -ppassword orders_db -e "
   CREATE TABLE IF NOT EXISTS orders (
     id VARCHAR(36) PRIMARY KEY,
     order_id VARCHAR(50) NOT NULL,
     customer_name VARCHAR(255) NOT NULL,
     total_amount DECIMAL(10,2) NOT NULL,
     shipping_address TEXT NOT NULL,
     raw_data JSON,
     created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
     updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
     INDEX idx_order_id (order_id),
     INDEX idx_created_at (created_at)
   );"
   ```

3. **Set environment variables:**
   ```bash
   export MYSQL_HOST=localhost
   export MYSQL_PORT=3306
   export MYSQL_DATABASE=orders_db
   export MYSQL_USER=root
   export MYSQL_PASSWORD=password
   export AWS_REGION=us-east-2
   export DEBUG=true
   export LOG_LEVEL=DEBUG
   ```

4. **Run the service:**
   ```bash
   python app.py
   # Service will start HTTP server on port 5000
   ```

### Testing

```bash
# Send test HTTP request (simulates Order API)
curl -X POST http://localhost:5000/api/delivery \
  -H "Content-Type: application/json" \
  -d '{
    "order_id": "TEST-001",
    "customer_name": "Test User",
    "items": [{"product_id": "TEST-PROD", "quantity": 1, "price": 25.00}],
    "total_amount": 25.00,
    "shipping_address": "123 Test St, Test City, TC 12345",
    "timestamp": "2024-01-15T10:30:00.000Z"
  }'

# Check health
curl http://localhost:5000/api/delivery/health

# Verify data was processed and stored in MySQL
mysql -h localhost -u root -ppassword orders_db -e "SELECT * FROM orders WHERE order_id = 'TEST-001';"
```

## Deployment

### Docker

```dockerfile
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
EXPOSE 5000

CMD ["python", "app.py"]
```

### Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: python-delivery-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: python-delivery-api
  template:
    metadata:
      labels:
        app: python-delivery-api
    spec:
      serviceAccountName: delivery-api-service-account
      containers:
      - name: delivery-api
        image: your-registry/python-delivery-api:latest
        ports:
        - containerPort: 5000
        env:
        - name: AWS_REGION
          value: "us-east-2"
        - name: MYSQL_HOST
          value: "python-orders-db.cluster-xyz.us-east-2.rds.amazonaws.com"
        - name: LOG_LEVEL
          value: "INFO"
```

### IAM Permissions

Required IAM policy for RDS access:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "rds-db:connect"
      ],
      "Resource": "arn:aws:rds-db:*:*:dbuser:python-orders-db/admin"
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:*:*:secret:rds-mysql-password-*"
    }
  ]
}
```

## Troubleshooting

### Common Issues

1. **HTTP request processing errors:**
   ```bash
   # Check service is running and accessible
   curl http://localhost:5000/api/delivery/health
   
   # Check logs for request processing issues
   kubectl logs -l app=python-delivery-api
   
   # Test service connectivity from Order API
   kubectl exec -it <order-api-pod> -- curl http://python-delivery-api:5000/api/delivery/health
   ```

2. **MySQL connection errors:**
   ```bash
   # Test RDS connectivity from EKS
   kubectl run mysql-test --image=mysql:8.0 --rm -it --restart=Never -- \
     mysql -h python-orders-db.cluster-xyz.us-east-2.rds.amazonaws.com -u admin -p
   
   # Check RDS instance status
   aws rds describe-db-instances --db-instance-identifier python-orders-db
   
   # Verify security group allows EKS access
   aws ec2 describe-security-groups --group-ids <rds-security-group-id>
   ```

3. **Request processing errors:**
   ```bash
   # Check request format and validation
   curl -X POST http://localhost:5000/api/delivery \
     -H "Content-Type: application/json" \
     -d '{"order_id": "TEST", "customer_name": "Test"}' -v
   
   # Monitor processing metrics
   kubectl logs -f -l app=python-delivery-api
   ```

### Performance Tuning

- **MySQL Connection Pool**: Tune `MYSQL_POOL_SIZE` based on concurrent request processing needs
- **Logging**: Use `json` format in production for structured logs
- **Error Handling**: Implement proper HTTP status codes for different error conditions
- **Request Processing**: Consider request validation and sanitization for security
- **Database Transactions**: Use proper transaction management for data consistency

### Monitoring

- **Metrics**: HTTP request processing and MySQL operations tracked via OpenTelemetry
- **Traces**: Request processing spans from HTTP receipt to database storage
- **Health**: Monitor `/api/delivery/health` endpoint with dependency status
- **Logs**: Structured JSON logs with trace correlation across HTTP processing
- **Database Metrics**: Track connection pool usage, query performance, and transaction success rates
- **HTTP Metrics**: Monitor request rates, response times, and error rates
- **Alarms**: Set up CloudWatch alarms for processing errors and database connectivity

## Security Considerations

- **Input Validation**: All HTTP request data is validated and sanitized before processing
- **SQL Injection Prevention**: Use parameterized queries and prepared statements
- **IAM Roles**: Use IAM roles instead of hardcoded credentials for RDS access
- **Network Security**: Deploy in private subnets with security groups restricting RDS access
- **Encryption**: Enable RDS encryption at rest and in transit
- **Secrets Management**: Store database passwords in AWS Secrets Manager
- **Request Security**: Validate HTTP request format and source to prevent malicious requests
- **HTTPS**: Use HTTPS for production deployments to encrypt data in transit