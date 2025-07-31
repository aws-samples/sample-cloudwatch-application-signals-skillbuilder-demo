# .NET Sample Application - CloudWatch Application Signals

✅ **Available**

This .NET sample demonstrates AWS CloudWatch Application Signals integration with ASP.NET Core microservices.

Try out this AWS SkillBuilder course to Monitor .NET Applications using CloudWatch Application Signals: [Monitor .NET Applications using Amazon CloudWatch Application Signals](https://skillbuilder.aws/learn/255DDEDPV5/monitor-net-applications-using-amazon-cloudwatch-application-signals/1WZ1NT16HJ)

## Getting Started

Since we have a comprehensive .NET sample already available, please use the existing repository:

### 1. Clone the .NET Sample Repository

```bash
git clone https://github.com/aws-samples/dotnet-observability-cloudwatch-application-signals.git
cd dotnet-observability-cloudwatch-application-signals
```

### 2. Deployment Steps

#### Step 1: Create EKS Environment

This step creates the EKS cluster, DynamoDB table, and required IAM roles:

```bash
chmod +x scripts/create-eks-env.sh
./scripts/create-eks-env.sh --region <your-aws-region>
```

#### Step 2: Build and Deploy Application

Make script executable and build and deploy application:

```bash
chmod +x scripts/build-deploy.sh
./scripts/build-deploy.sh --region <your-aws-region>
```

#### Step 3: Install Amazon CloudWatch Observability EKS add-on

Install the addon using the below script:

```bash
chmod +x scripts/setup-cloudwatch-agent.sh
./scripts/setup-cloudwatch-agent.sh
```

#### Step 4: Annotate the Workload

Run the below script to add annotation under the `PodTemplate` section in order to inject auto-instrumentation agent:

```bash
chmod +x scripts/annotate-workloads.sh
./scripts/annotate-workloads.sh
```

#### Step 5: Restart pods

Run the below commands to restart application pods in order for new changes to take effect:

```bash
kubectl apply -f kubernetes/cart-deployment.yaml 
kubectl apply -f kubernetes/delivery-deployment.yaml 
```

Wait for 2min for new pods to attain `Running` status

#### Step 6: Test the application deployment

You can test and generate load on the application by running the below script. Keep the script running for ~2min:

```bash
chmod +x scripts/load-generator.sh
./scripts/load-generator.sh 
```

#### Step 7: Monitor .NET applications using CloudWatch Application Signals

Check AWS Application Signals:

- Open [Amazon CloudWatch Console](https://console.aws.amazon.com/cloudwatch/)
- Navigate to CloudWatch Application Signals from the left hand side navigation pane

#### Step 8: Cleanup

To remove all created resources run the below scripts:

```bash    
chmod +x scripts/build-cleanup.sh
chmod +x scripts/cleanup-eks-env.sh
./scripts/build-cleanup.sh
./scripts/cleanup-eks-env.sh
```

### Troubleshooting

1. Check pod status:
```bash
kubectl get pods
kubectl describe pod <pod-name>
```

2. View logs:
```bash
kubectl logs -l app=dotnet-order-api
kubectl logs -l app=dotnet-delivery-api
```

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

- **AWS CLI** configured with appropriate credentials
- **.NET 8.0 SDK** installed
- **Docker** installed and running
- **kubectl** and **eksctl** for Kubernetes management
- **jq** command-line JSON processor
- **AWS account** with CloudWatch Application Signals enabled
- **Permissions** to create EKS clusters, DynamoDB tables, IAM roles, and ECR repositories

> **Tip**: Run `./0-check-prerequisites.sh` to verify all prerequisites are met before starting deployment.

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