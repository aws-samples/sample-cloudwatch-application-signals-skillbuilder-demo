# CloudWatch Application Signals Sample Applications

A collection of sample applications demonstrating AWS CloudWatch Application Signals across different programming languages and runtimes. These samples are designed for AWS SkillBuilder courses and provide hands-on experience with observability, monitoring, and distributed tracing.

## Overview

CloudWatch Application Signals automatically instruments your applications to collect and correlate metrics, traces, and logs, providing deep insights into application performance and health. This repository contains sample applications that demonstrate these capabilities across various technology stacks.

## Available Sample Applications

### ✅ Java
**Status**: Available  
**Path**: [`java-sample-app/`](./java-sample-app/)  
**Description**: Spring Boot microservices application with Order API and Delivery API, deployed on Amazon EKS with DynamoDB integration.

### ✅ Python
**Status**: Available  
**Path**: [`python-sample-app/`](./python-sample-app/)  
**Description**: Flask/FastAPI microservices application demonstrating CloudWatch Application Signals with Python runtime.

### ✅ .NET
**Status**: Available  
**Path**: [`dotnet-sample-app/`](./dotnet-sample-app/)  
**Description**: ASP.NET Core microservices application showcasing CloudWatch Application Signals integration.

### ✅  Node.js
**Status**: Coming Soon  
**Path**: [`nodejs-sample-app/`](./nodejs-sample-app/) 
**Description**: Express.js microservices application with CloudWatch Application Signals instrumentation.

## Getting Started

1. **Choose your runtime**: Navigate to the appropriate sample application folder
2. **Follow the README**: Each sample includes detailed setup and deployment instructions
3. **Deploy and explore**: Use the provided scripts to deploy infrastructure and generate sample data
4. **Monitor with CloudWatch**: Observe metrics, traces, and logs in the AWS Console

## Common Prerequisites

All sample applications require:
- AWS CLI configured with appropriate permissions
- AWS account with CloudWatch Application Signals enabled
- Docker installed and running
- kubectl and eksctl for Kubernetes deployments

## Repository Structure

```
.
├── README.md                    # This landing page
├── LICENSE                      # Repository license
├── CODE_OF_CONDUCT.md          # Community guidelines
├── CONTRIBUTING.md             # Contribution guidelines
├── java-sample-app/            # Java Spring Boot sample
├── python-sample-app/          # Python sample (coming soon)
├── dotnet-sample-app/          # .NET sample (coming soon)
└── nodejs-sample-app/          # Node.js sample (coming soon)
```

## Key Features Demonstrated

Each sample application showcases:

- **Automatic Instrumentation**: Zero-code observability with CloudWatch Application Signals
- **Distributed Tracing**: End-to-end request tracking across microservices
- **Custom Metrics**: Application-specific performance indicators
- **Service Maps**: Visual representation of service dependencies
- **Anomaly Detection**: Automated identification of performance issues
- **Alerting**: Proactive notifications based on application health

## AWS Services Used

- **Amazon CloudWatch**: Application Signals, Container Insights, Logs
- **Amazon EKS**: Kubernetes container orchestration
- **Amazon DynamoDB**: NoSQL database for application data
- **Amazon ECR**: Container image registry
- **AWS IAM**: Identity and access management
- **AWS X-Ray**: Distributed tracing (integrated with Application Signals)

## Learning Path

1. **Start with Java or .NET**: Both provide comprehensive examples with detailed documentation
2. **Compare implementations**: Explore differences between Java Spring Boot and ASP.NET Core patterns
3. **Explore other runtimes**: Compare implementation patterns across languages (Python and Node.js coming soon)
4. **Customize and extend**: Modify samples to match your use cases
5. **Apply to production**: Use patterns learned in your own applications

## Support and Feedback

- **Issues**: Report bugs or request features via GitHub Issues
- **Discussions**: Join community discussions for questions and best practices
- **Contributions**: See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines

## License

This project is licensed under the MIT-0 License. See [LICENSE](./LICENSE) file for details.

---

**Note**: This repository is actively maintained and new runtime samples are added regularly. Star the repository to stay updated with new releases.