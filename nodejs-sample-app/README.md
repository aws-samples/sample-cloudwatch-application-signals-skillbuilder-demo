# Node.js Sample Application - CloudWatch Application Signals

A containerized Node.js microservices application demonstrating AWS CloudWatch Application Signals with Express.js framework. This sample showcases synchronous order processing using direct HTTP communication between services and MySQL on AWS RDS for persistent storage, with automated AWS infrastructure deployment, monitoring, and observability.

## Architecture Overview

This project implements a simplified, cloud-native microservices architecture using Node.js with two main services:
- **Order API**: Express.js-based service for order creation and direct HTTP communication
- **Delivery API**: Express.js-based REST service for order processing and MySQL storage

The application leverages AWS services including EKS for container orchestration, RDS MySQL for relational data persistence, ECR for container registry, and CloudWatch Application Signals for comprehensive observability with automatic instrumentation across direct service-to-service communication.

### CloudWatch Application Signals Features

This sample application demonstrates:
- **Automatic instrumentation** using AWS Distro for OpenTelemetry (ADOT)
- **Trace to log correlation** with automatic injection of trace IDs and span IDs into application logs
- **Service map visualization** showing dependencies and performance metrics
- **Performance monitoring** with latency, error rates, and throughput metrics
- **Log correlation** allowing you to view relevant log entries directly from trace details

## Prerequisites

- AWS CLI configured with appropriate credentials
- kubectl installed and configured
- eksctl installed
- Docker installed and running
- jq command-line JSON processor
- Node.js 18.0.0 or later (for local development)
- npm package manager
- MySQL client (for local testing and verification)
- AWS account with permissions to create:
  - EKS clusters
  - RDS MySQL instances
  - VPC, subnets, and security groups
  - IAM roles and policies
  - ECR repositories
  - CloudWatch resources

## Quick Start

### 1. Navigate to Node.js Sample
```bash
cd nodejs-sample-app
```

### 2. Deploy Infrastructure
```bash
./scripts/1-create-env.sh --region us-east-2
```

### 3. Build and Deploy Application
```bash
./scripts/2-build-deploy-app.sh
```

### 4. Configure Monitoring
```bash
./scripts/3-setup-cloudwatch-agent.sh
./scripts/4-annotate-workloads.sh
```

### 5. Generate Test Traffic
```bash
./scripts/5-generate-load.sh
```

### 6. Fault Injection (Optional)
```bash
# Inject database connection pool fault for demonstration
./scripts/6-introduce-fault.sh

# Restore normal operation
./scripts/7-restore-normal.sh
```

### 7. View in CloudWatch
- Navigate to CloudWatch Console
- Go to Application Signals
- Explore service maps, metrics, and traces

## Script Reference

The sample includes a complete set of automation scripts for deployment, testing, and cleanup:

| Script | Purpose | Description |
|--------|---------|-------------|
| `1-create-env.sh` | **Environment Setup** | Creates EKS cluster, RDS MySQL, IAM roles, and SSM parameters |
| `2-build-deploy-app.sh` | **Application Deployment** | Builds Docker images and deploys to Kubernetes |
| `3-setup-cloudwatch-agent.sh` | **Monitoring Setup** | Configures CloudWatch Application Signals |
| `4-annotate-workloads.sh` | **Observability** | Adds annotations for service discovery |
| `5-generate-load.sh` | **Load Testing** | Generates synthetic traffic for testing |
| `6-introduce-fault.sh` | **Fault Injection** | Injects database connection pool exhaustion fault |
| `7-restore-normal.sh` | **Fault Recovery** | Restores normal database configuration |
| `8-build-cleanup.sh` | **App Cleanup** | Removes application deployments (keeps infrastructure) |
| `9-cleanup-env.sh` | **Full Cleanup** | Removes all AWS resources including SSM parameters |

### Script Dependencies

```mermaid
graph TD
    A[1-create-env.sh] --> B[2-build-deploy-app.sh]
    B --> C[3-setup-cloudwatch-agent.sh]
    C --> D[4-annotate-workloads.sh]
    D --> E[5-generate-load.sh]
    E --> F[6-introduce-fault.sh]
    F --> G[7-restore-normal.sh]
    
    B --> H[8-build-cleanup.sh]
    A --> I[9-cleanup-env.sh]
    
    style F fill:#ffcccc
    style G fill:#ccffcc
    style I fill:#ffcccc
```

## Trace to Log Correlation

This application is configured with CloudWatch Application Signals trace to log correlation, which automatically injects trace IDs and span IDs into your application logs.

### Quick Test

Run the trace correlation test script:

```bash
# Make sure both services are running locally or deployed
node test-trace-correlation.js
```

### Verification Steps

1. **Check Log Output**: Look for trace context fields in your logs:
   ```json
   {
     "@timestamp": "2024-01-15T10:30:45.123Z",
     "level": "INFO",
     "service": "delivery-api",
     "message": "HTTP request received",
     "trace_id": "1-507f4e1a-2f9f4e1a2f9f4e1a2f9f4e1a",
     "span_id": "53995c3f42cd8ad8",
     "trace_flags": "01"
   }
   ```

2. **View in Application Signals Console**:
   - Open CloudWatch Application Signals
   - Navigate to your service map
   - Click on a trace to view details
   - Scroll down to see correlated log entries

3. **Troubleshoot Issues**: See [APPLICATION_SIGNALS_SETUP.md](./APPLICATION_SIGNALS_SETUP.md) for detailed configuration and troubleshooting.

## Testing Direct Order Processing

After deployment, test the direct order processing flow:

### 1. Test Order Creation (Direct HTTP Communication)

```bash
# Get service endpoint
kubectl get svc nodejs-order-api

# Create an order (processes directly through Delivery API)
curl -X POST http://<order-api-endpoint>/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "order_id": "123",
    "customer_name": "John Doe",
    "items": [{
      "product_id": "456",
      "quantity": 1,
      "price": 29.99
    }],
    "total_amount": 29.99,
    "shipping_address": "123 Main St"
  }'

# Expected response: 200 OK (order processed successfully)
```

### 2. Verify Direct Service Communication

```bash
# Monitor Order API logs for HTTP calls to Delivery API
kubectl logs -f -l app=nodejs-order-api

# Monitor Delivery API logs for direct request processing
kubectl logs -f -l app=nodejs-delivery-api
```

### 3. Verify MySQL Data Storage

```bash
# Get RDS endpoint
aws rds describe-db-instances --db-instance-identifier nodejs-orders-db --query 'DBInstances[0].Endpoint.Address' --output text

# Connect to MySQL and verify order storage
mysql -h <rds-endpoint> -u admin -p orders_db
# Password will be retrieved from AWS Secrets Manager during deployment

# Query stored orders
SELECT * FROM orders WHERE order_id = '123';
```

### 4. Health Check Endpoints

```bash
# Check Order API health
curl http://<order-api-endpoint>/api/orders/health

# Check Delivery API health (REST service)
kubectl port-forward deployment/nodejs-delivery-api 3000:3000
curl http://localhost:3000/api/delivery/health
```

## Node.js Framework Features

This sample demonstrates CloudWatch Application Signals integration with:

### Express.js (Both APIs)
- **High-Performance HTTP Server**: Fast, unopinionated web framework
- **Middleware Architecture**: Modular request processing pipeline
- **JSON API Support**: Built-in JSON parsing and response handling
- **Route Organization**: Clean separation of concerns with controllers
- **Error Handling**: Centralized error handling middleware
- **Auto-instrumentation**: OpenTelemetry Express.js integration

### Sequelize ORM (Delivery API)
- **Database Abstraction**: Object-relational mapping for MySQL
- **Connection Pooling**: Efficient database connection management
- **Migration Support**: Database schema versioning
- **Query Optimization**: Automatic query optimization and caching
- **Transaction Support**: ACID transaction handling
- **Auto-instrumentation**: OpenTelemetry database integration

## CloudWatch Application Signals Features

This sample demonstrates:

- **Automatic Service Discovery**: Services are automatically detected and mapped
- **Distributed Tracing**: Request flows tracked across Order API → Delivery API → RDS MySQL
- **Synchronous Processing Observability**: HTTP service-to-service communication metrics and traces
- **Database Performance Monitoring**: MySQL query performance, connection pool usage, and transaction metrics
- **Performance Metrics**: Latency, error rates, and throughput automatically collected
- **Service Level Objectives (SLOs)**: Define and monitor application performance targets
- **Anomaly Detection**: Automatic identification of performance deviations
- **Custom Metrics**: Application-specific business metrics
- **Node.js Runtime Metrics**: Memory usage, event loop lag, and garbage collection metrics

## Data Flow

```
[Client] → [Order API (Express.js)] → [Delivery API (Express.js)] → [RDS MySQL]
    ↓              ↓                        ↓                           ↓
    └──────────────── CloudWatch Application Signals ──────────────────┘
```

### Direct Processing Benefits

- **Simplified Architecture**: Direct service-to-service communication reduces complexity
- **Immediate Response**: Synchronous processing provides immediate feedback to clients
- **Easier Debugging**: Direct call stack makes troubleshooting more straightforward
- **Observability**: Full visibility into HTTP service communication and database operations

## Infrastructure Components

- **EKS Cluster**: Managed Kubernetes with t3.large nodes
- **RDS MySQL**: `nodejs-orders-db` for relational data storage with Multi-AZ deployment
- **VPC & Security Groups**: Network isolation and secure RDS access from EKS
- **ECR Repositories**: Container images for both Node.js services
- **IAM Roles**: Service accounts with RDS and SSM permissions
- **SSM Parameter Store**: Dynamic configuration for database connection pooling
- **CloudWatch**: Application Signals, Container Insights, and logging
- **Load Balancer**: External access to Order API
- **ClusterIP Service**: Internal communication between Order API and Delivery API

## Environment Variables

### Order API Configuration
- `DELIVERY_API_URL`: Delivery API service URL for direct HTTP communication
- `AWS_REGION`: AWS region for RDS operations
- `LOG_LEVEL`: Logging level (info, debug, warn, error)
- `NODE_ENV`: Node.js environment (development, production)
- `PORT`: Service port (default: 3000)
- `OTEL_SERVICE_NAME`: Service name for OpenTelemetry tracing
- `OTEL_RESOURCE_ATTRIBUTES`: Additional service metadata for tracing

### Delivery API Configuration
- `MYSQL_HOST`: RDS MySQL endpoint hostname
- `MYSQL_PORT`: MySQL port (default: 3306)
- `MYSQL_DATABASE`: Database name (orders_db)
- `MYSQL_USER`: Database username
- `MYSQL_PASSWORD`: Database password (from AWS Secrets Manager)
- `AWS_REGION`: AWS region for RDS operations
- `LOG_LEVEL`: Logging level (info, debug, warn, error)
- `NODE_ENV`: Node.js environment (development, production)
- `PORT`: Service port (default: 3000)
- `OTEL_SERVICE_NAME`: Service name for OpenTelemetry tracing
- `OTEL_RESOURCE_ATTRIBUTES`: Additional service metadata for tracing

### Dynamic Configuration (SSM Parameter Store)
- `/nodejs-sample-app/mysql/pool-size`: MySQL connection pool size (default: 10)
- `/nodejs-sample-app/mysql/max-overflow`: MySQL connection pool max overflow (default: 20)
- `/nodejs-sample-app/mysql/fault-injection`: Database fault injection flag (default: false)

These parameters are read at application startup and can be modified for fault injection without code changes.

### Automatic OpenTelemetry Configuration
- `OTEL_NODE_ENABLED_INSTRUMENTATIONS`: Enable specific auto-instrumentations
- `OTEL_EXPORTER_OTLP_ENDPOINT`: CloudWatch Application Signals endpoint
- `OTEL_PROPAGATORS`: Trace context propagation format

## Fault Injection for Demonstrations

This sample includes built-in fault injection capabilities to demonstrate how CloudWatch Application Signals helps identify and troubleshoot issues in microservices architectures.

### Database Connection Pool Exhaustion

The application includes a configurable database connection pool fault that can be injected for demonstration purposes:

#### **Inject Fault:**
```bash
./scripts/6-introduce-fault.sh
```

This script will:
- Reduce MySQL connection pool size to 1 connection
- Set max overflow to 0 connections  
- Restart delivery API pods to apply changes
- Verify fault injection via health endpoint

#### **Expected Impact:**
- **Increased Latency**: Requests queue waiting for database connections
- **Connection Timeouts**: Under concurrent load, requests may timeout
- **Cascading Failures**: Delivery API issues propagate to Order API
- **Observable Degradation**: Clear performance impact visible in CloudWatch Application Signals

#### **Restore Normal Operation:**
```bash
./scripts/7-restore-normal.sh
```

This script will:
- Restore pool size to 10 connections
- Restore max overflow to 20 connections
- Restart delivery API pods
- Verify normal operation restored

### Configuration Management

The fault injection system uses AWS SSM Parameter Store for dynamic configuration:

- **Parameters Created:**
  - `/nodejs-sample-app/mysql/pool-size` (default: 10)
  - `/nodejs-sample-app/mysql/max-overflow` (default: 20)
  - `/nodejs-sample-app/mysql/fault-injection` (default: false)

- **Manual Configuration:**
```bash
# View current values
aws ssm get-parameters --names "/nodejs-sample-app/mysql/pool-size" "/nodejs-sample-app/mysql/max-overflow" "/nodejs-sample-app/mysql/fault-injection"

# Inject fault manually
aws ssm put-parameter --name "/nodejs-sample-app/mysql/fault-injection" --value "true" --overwrite
kubectl rollout restart deployment/nodejs-delivery-api

# Restore normal operation manually  
aws ssm put-parameter --name "/nodejs-sample-app/mysql/fault-injection" --value "false" --overwrite
kubectl rollout restart deployment/nodejs-delivery-api
```

## Project Structure

```
nodejs-sample-app/
├── order-api/           # Order API service
│   ├── src/
│   │   ├── config/      # Configuration management
│   │   ├── controllers/ # Route handlers
│   │   ├── services/    # Business logic
│   │   ├── schemas/     # Validation schemas
│   │   ├── middleware/  # Express middleware
│   │   └── app.js       # Main application
│   ├── package.json
│   ├── Dockerfile
│   └── README.md
├── delivery-api/        # Delivery API service
│   ├── src/
│   │   ├── config/      # Configuration management
│   │   ├── controllers/ # Route handlers
│   │   ├── services/    # Business logic
│   │   ├── models/      # Database models (Sequelize)
│   │   ├── schemas/     # Validation schemas
│   │   ├── middleware/  # Express middleware
│   │   └── app.js       # Main application
│   ├── package.json
│   ├── Dockerfile
│   └── README.md
├── kubernetes/          # Kubernetes deployment manifests
├── scripts/            # Deployment and management scripts
├── docker-compose.yml  # Local development setup
└── README.md           # This file
```

## Local Development

### Prerequisites for Local Development

- Node.js 18.0.0 or higher
- Docker and Docker Compose
- MySQL client

### Setup

1. Navigate to each service directory and install dependencies:
   ```bash
   cd order-api && npm install
   cd ../delivery-api && npm install
   ```

2. Start local MySQL database:
   ```bash
   docker-compose up -d mysql
   ```

3. Configure environment variables by copying `.env.example` to `.env` in each service directory

4. Start the services:
   ```bash
   # Terminal 1 - Delivery API
   cd delivery-api && npm run dev
   
   # Terminal 2 - Order API  
   cd order-api && npm run dev
   ```

### Local Testing

```bash
# Test order creation locally
curl -X POST http://localhost:3000/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "order_id": "local-123",
    "customer_name": "Local Test",
    "items": [{"product_id": "456", "quantity": 1, "price": 29.99}],
    "total_amount": 29.99,
    "shipping_address": "123 Local St"
  }'
```

## Cleanup

From the `nodejs-sample-app` directory:

Remove application resources (keep infrastructure):
```bash
./scripts/8-build-cleanup.sh
```

Remove all AWS resources (including SSM parameters):
```bash
./scripts/9-cleanup-env.sh --region us-east-2
```

---

**Back to**: [Main Repository](../README.md)