# Java Sample Application - CloudWatch Application Signals

A containerized Java microservices application demonstrating Amazon CloudWatch Application Signals with Spring Boot. This sample showcases order processing and delivery management with automated AWS infrastructure deployment, monitoring, and observability.

### Take the AWS Skill Builder course: [Monitor Java Application using CloudWatch Application Signals](https://skillbuilder.aws/learn/PMCTXKYK1Y/monitor-java-applications-using-amazon-cloudwatch-application-signals/15ZK4ETKE9)

## Architecture Overview

This project implements a scalable microservices architecture using Spring Boot with two main services:
- **Order API**: Handles order creation and validation
- **Delivery API**: Manages order fulfillment and storage

The application leverages AWS services including EKS for container orchestration, DynamoDB for data persistence, ECR for container registry, and CloudWatch Application Signals for comprehensive observability.

## Repository Structure
```
java-sample-app/
├── delivery-api/                 # Delivery service implementation
│   ├── Dockerfile               # Container image definition
│   ├── pom.xml                  # Maven configuration
│   └── src/                     # Source code
├── order-api/                   # Order service implementation
│   ├── Dockerfile              # Container image definition
│   ├── pom.xml                 # Maven configuration
│   └── src/                    # Source code
├── scripts/                    # Infrastructure automation scripts
│   ├── 1-create-env.sh        # Creates EKS cluster and AWS resources
│   ├── 2-build-deploy-app.sh  # Builds and deploys applications
│   ├── 3-setup-cloudwatch-agent.sh  # Configures CloudWatch monitoring
│   ├── 4-annotate-wokloads.sh # Configures OpenTelemetry instrumentation
│   ├── 5-generate-load.sh     # Load testing utility
│   ├── 6-build-cleanup.sh     # Removes application resources
│   ├── 7-cleanup-env.sh       # Removes all AWS resources
│   └── traffic-generator/     # Load testing components
├── docs/                      # Architecture diagrams
└── pom.xml                   # Parent Maven configuration
```

## Prerequisites

- AWS CLI configured with appropriate credentials
- kubectl installed and configured
- eksctl installed
- Docker installed and running
- jq command-line JSON processor
- Maven 3.6+ 
- Java 21
- AWS account with permissions to create:
  - EKS clusters
  - DynamoDB tables
  - IAM roles and policies
  - ECR repositories
  - CloudWatch resources

## Quick Start

### 1. Navigate to Java Sample
```bash
cd java-sample-app
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
./scripts/4-annotate-wokloads.sh
kubectl apply -f kubernetes/order-api-deployment.yaml 
kubectl apply -f kubernetes/delivery-api-deployment.yaml
```

### 5. Generate Test Traffic
```bash
./scripts/5-generate-load.sh
```

### 5. View in CloudWatch
- Navigate to CloudWatch Console
- Go to Application Signals
- Explore service maps, metrics, and traces

## Testing the Application

After deployment, test the Order API:

```bash
# Get service endpoint
kubectl get svc java-order-api

# Create an order
curl -X POST http://<order-api-endpoint>/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "orderId": "123",
    "customerName": "John Doe",
    "items": [{
      "productId": "456",
      "quantity": 1,
      "price": 29.99
    }],
    "totalAmount": 29.99,
    "shippingAddress": "123 Main St"
  }'
```

## CloudWatch Application Signals Features

This sample demonstrates:

- **Automatic Service Discovery**: Services are automatically detected and mapped
- **Distributed Tracing**: Request flows tracked across Order API → Delivery API → DynamoDB
- **Performance Metrics**: Latency, error rates, and throughput automatically collected
- **Service Level Objectives (SLOs)**: Define and monitor application performance targets
- **Anomaly Detection**: Automatic identification of performance deviations
- **Custom Metrics**: Application-specific business metrics

## Data Flow

```
[Client] → [Order API] → [Delivery API] → [DynamoDB]
    ↓           ↓             ↓              ↓
    └─────── CloudWatch Application Signals ──────┘
```

## Infrastructure Components

- **EKS Cluster**: Managed Kubernetes with t3.large nodes
- **DynamoDB Table**: `orders-catalog` for order storage
- **ECR Repositories**: Container images for both services
- **IAM Roles**: Service accounts with appropriate permissions
- **CloudWatch**: Application Signals, Container Insights, and logging

## Cleanup

From the `java-sample-app` directory:

Remove application resources (keep infrastructure):
```bash
./scripts/6-build-cleanup.sh
```

Remove all AWS resources:
```bash
./scripts/7-cleanup-env.sh --region us-east-2
```

## Troubleshooting

### Common Issues

1. **Pod startup failures**:
   ```bash
   kubectl describe pod <pod-name>
   kubectl logs <pod-name>
   ```

2. **Service connectivity**:
   ```bash
   kubectl get endpoints
   kubectl logs -l app=java-order-api
   ```

3. **DynamoDB permissions**:
   ```bash
   kubectl describe serviceaccount <service-account-name>
   ```

## Learning Objectives

After completing this sample, you will understand:

- How to instrument Java applications for CloudWatch Application Signals
- Microservices observability patterns
- Distributed tracing in containerized environments
- AWS EKS deployment and monitoring best practices
- Integration between CloudWatch and OpenTelemetry

## Next Steps

- Explore other runtime samples in the parent repository
- Customize the application for your use case
- Implement additional CloudWatch features like alarms and dashboards
- Scale the application and observe performance characteristics

---

**Back to**: [Main Repository](../README.md)