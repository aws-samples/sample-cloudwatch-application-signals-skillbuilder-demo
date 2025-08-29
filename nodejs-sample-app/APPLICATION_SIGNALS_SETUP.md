# CloudWatch Application Signals - Trace to Log Correlation Setup

This guide explains how to configure Amazon CloudWatch Application Signals with trace to log correlation for the Node.js sample application.

## Overview

CloudWatch Application Signals provides automatic instrumentation for your applications to track performance metrics and traces. With trace to log correlation enabled, trace IDs and span IDs are automatically injected into your application logs, allowing you to correlate logs with specific traces in the Application Signals console.

## Architecture

The setup includes:
- **AWS Distro for OpenTelemetry (ADOT)** for automatic instrumentation
- **Winston logging** with OpenTelemetry instrumentation for trace context injection
- **CloudWatch Agent** configured for Application Signals
- **Enhanced log formatters** for proper trace correlation

## Prerequisites

1. **Enable Application Signals** in your AWS account:
   ```bash
   aws application-signals put-service-level-objective --region us-east-1
   ```

2. **Install dependencies** (already included in package.json):
   ```bash
   cd delivery-api && npm install
   cd ../order-api && npm install
   ```

## Configuration Details

### 1. OpenTelemetry Instrumentation

Both services are configured with:
- **ADOT auto-instrumentation**: Automatically instruments HTTP, database, and other operations
- **Winston instrumentation**: Injects trace context into log records
- **Custom logHook**: Ensures proper field naming for CloudWatch Application Signals

### 2. Logger Configuration

The logger is configured to:
- Extract trace context from multiple sources (Winston injection, OpenTelemetry API, X-Ray environment)
- Format logs with proper field names (`trace_id`, `span_id`, `trace_flags`)
- Provide fallback mechanisms for trace context extraction

### 3. CloudWatch Agent Configuration

The `cloudwatch-agent-config.json` file configures:
- **Application Signals metrics collection**
- **Trace collection**
- **Cardinality management** with rules and limits
- **Debug logging** for dropped metrics

## Deployment Options

### Option 1: Amazon EKS
- Install the Amazon CloudWatch Observability EKS add-on
- Application Signals is enabled by default
- No additional environment variables needed

### Option 2: Amazon ECS
- Deploy with the CloudWatch agent as a sidecar or daemon
- Application Signals is enabled by default
- No additional environment variables needed

### Option 3: Amazon EC2
- Install and configure the CloudWatch agent
- Set the following environment variable:
  ```bash
  export OTEL_AWS_APPLICATION_SIGNALS_ENABLED=true
  ```

## Environment Variables

For EC2 deployments, set these environment variables:

```bash
# Enable Application Signals
export OTEL_AWS_APPLICATION_SIGNALS_ENABLED=true

# Optional: Configure service name
export OTEL_SERVICE_NAME=delivery-api  # or order-api

# Optional: Configure resource attributes
export OTEL_RESOURCE_ATTRIBUTES="service.name=delivery-api,service.version=1.0.0"

# Optional: Configure sampling rate (default is 5%)
export OTEL_TRACES_SAMPLER=traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.1  # 10% sampling rate
```

## Running the Application

### Development Mode
```bash
# Delivery API
cd delivery-api
npm run dev

# Order API  
cd order-api
npm run dev
```

### Production Mode
```bash
# Delivery API
cd delivery-api
npm start

# Order API
cd order-api
npm start
```

## Verification

### 1. Check Log Output
Logs should include trace context fields:
```json
{
  "@timestamp": "2024-01-15T10:30:45.123Z",
  "level": "INFO",
  "service": "delivery-api",
  "message": "HTTP request received",
  "trace_id": "1-507f4e1a-2f9f4e1a2f9f4e1a2f9f4e1a",
  "span_id": "53995c3f42cd8ad8",
  "trace_flags": "01",
  "method": "POST",
  "url": "/api/delivery"
}
```

### 2. Verify Application Signals
1. Open the CloudWatch console
2. Navigate to Application Signals
3. Check that your services appear in the service map
4. Click on a trace to view details
5. Scroll down to see correlated log entries

### 3. Test Trace Correlation
1. Generate some traffic to your services
2. Find a trace with high latency or errors
3. Click on the trace to view details
4. Verify that relevant log entries appear at the bottom of the trace detail page

## Troubleshooting

### Logs Not Showing Trace Context
1. Verify ADOT instrumentation is loaded:
   ```bash
   # Check if the require flags are present in package.json scripts
   grep "aws-distro-opentelemetry" package.json
   ```

2. Check Winston instrumentation:
   ```bash
   # Verify instrumentation.js is being loaded
   grep "instrumentation.js" package.json
   ```

### Application Signals Not Appearing
1. Verify Application Signals is enabled in your account
2. Check CloudWatch agent configuration
3. Verify IAM permissions for CloudWatch and X-Ray
4. Check application logs for ADOT initialization messages

### High Cardinality Issues
1. Review the CloudWatch agent configuration rules
2. Adjust the `drop_threshold` in the limiter configuration
3. Add more specific `drop` rules for high-cardinality dimensions
4. Monitor CloudWatch agent logs for dropped metrics

## Cost Optimization

To optimize costs:
1. **Adjust sampling rate**: Lower the trace sampling rate for high-traffic applications
2. **Use filtering rules**: Drop or aggregate high-cardinality metrics
3. **Set appropriate limits**: Configure the limiter to prevent excessive metric publishing
4. **Monitor usage**: Regularly review CloudWatch costs and adjust configuration

## Additional Resources

- [AWS Application Signals Documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Application-Signals.html)
- [OpenTelemetry Node.js Documentation](https://opentelemetry.io/docs/instrumentation/js/)
- [Winston OpenTelemetry Instrumentation](https://www.npmjs.com/package/@opentelemetry/instrumentation-winston)