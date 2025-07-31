# .NET Sample Application - CloudWatch Application Signals

✅ **Available**

This .NET sample demonstrates AWS CloudWatch Application Signals integration with ASP.NET Core microservices.

## Getting Started

Since we have a comprehensive .NET sample already available, please use the existing repository:

### 1. Clone the .NET Sample Repository

```bash
git clone https://github.com/aws-samples/dotnet-observability-cloudwatch-application-signals.git
cd dotnet-observability-cloudwatch-application-signals
```

### 2. Follow the Setup Instructions

The repository contains automated scripts for easy deployment. Navigate to the scripts directory and follow the step-by-step process:

```bash
cd scripts
```

**Deployment Steps:**

1. **Create Infrastructure**: `./1-create-env.sh --region us-east-2`
2. **Build and Deploy**: `./2-build-deploy-app.sh`
3. **Setup Monitoring**: `./3-setup-cloudwatch-agent.sh`
4. **Configure Instrumentation**: `./4-annotate-workloads.sh`
5. **Generate Test Traffic**: `./5-generate-load.sh`

**Cleanup Steps:**

- **Remove Application**: `./6-build-cleanup.sh`
- **Remove Infrastructure**: `./7-cleanup-env.sh --region us-east-2`

### 3. Architecture Overview

The .NET sample includes:

- **ASP.NET Core microservices** with automatic instrumentation
- **Amazon EKS deployment** with container orchestration
- **DynamoDB integration** for data persistence
- **CloudWatch Application Signals** for comprehensive observability
- **OpenTelemetry integration** for distributed tracing

### 4. Key Features Demonstrated

- Automatic service discovery and mapping
- Distributed tracing across .NET microservices
- Performance metrics and anomaly detection
- Custom business metrics
- Service Level Objectives (SLOs)
- Integration with AWS services

## Repository Structure

The .NET sample repository contains:

```
dotnet-observability-cloudwatch-application-signals/
├── src/                           # .NET application source code
├── scripts/                       # Automated deployment scripts
├── kubernetes/                    # Kubernetes manifests
└── docs/                         # Documentation and diagrams
```

## Prerequisites

- AWS CLI configured with appropriate credentials
- .NET 8.0 SDK
- Docker installed and running
- kubectl and eksctl for Kubernetes
- AWS account with CloudWatch Application Signals enabled

## Learning Objectives

After completing this sample, you will understand:

- How to instrument .NET applications for CloudWatch Application Signals
- ASP.NET Core observability patterns
- Distributed tracing in containerized .NET environments
- AWS EKS deployment with .NET applications
- Integration between CloudWatch and OpenTelemetry in .NET

## Additional Resources

- **Repository**: [dotnet-observability-cloudwatch-application-signals](https://github.com/aws-samples/dotnet-observability-cloudwatch-application-signals)
- **Scripts Documentation**: [Deployment Scripts](https://github.com/aws-samples/dotnet-observability-cloudwatch-application-signals/tree/main/scripts)
- **AWS Documentation**: [CloudWatch Application Signals](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Application-Signals.html)

---

**Back to**: [Main Repository](../README.md)