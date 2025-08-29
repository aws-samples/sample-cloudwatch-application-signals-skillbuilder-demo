#!/bin/bash

set -e

# Log levels and colors
ERROR_COLOR='\033[0;31m'    # Red
SUCCESS_COLOR='\033[0;32m'  # Green
WARNING_COLOR='\033[1;33m'  # Yellow
INFO_COLOR='\033[0;34m'     # Blue
DEBUG_COLOR='\033[0;37m'    # Light Gray
NO_COLOR='\033[0m'

# Logging function
log() {
    local level=$1
    local message=$2
    local color

    case $level in
        ERROR)   color=$ERROR_COLOR ;;
        SUCCESS) color=$SUCCESS_COLOR ;;
        WARNING) color=$WARNING_COLOR ;;
        INFO)    color=$INFO_COLOR ;;
        DEBUG)   color=$DEBUG_COLOR ;;
        *)       color=$INFO_COLOR; level="INFO" ;;
    esac
    
    echo -e "${color}${level}: ${message}${NO_COLOR}"
}

# Error handling
handle_error() {
    log "ERROR" "Error occurred on line $1"
    log "ERROR" "Command: $2"
    exit 1
}

trap 'handle_error ${LINENO} "${BASH_COMMAND}"' ERR

# Load configuration
load_configuration() {
    if [ ! -f .cluster-config/cluster-resources.json ]; then
        log "ERROR" "Cluster configuration not found. Please run 1-create-env.sh first."
        exit 1
    fi

    log "INFO" "Loading configuration..."
    
    AWS_REGION=$(jq -r '.cluster.region' .cluster-config/cluster-resources.json)
    AWS_ACCOUNT_ID=$(jq -r '.cluster.account_id' .cluster-config/cluster-resources.json)
    CLUSTER_NAME=$(jq -r '.cluster.name' .cluster-config/cluster-resources.json)
    RDS_ENDPOINT=$(jq -r '.resources.rds_instance.endpoint' .cluster-config/cluster-resources.json)
    RDS_DATABASE=$(jq -r '.resources.rds_instance.database' .cluster-config/cluster-resources.json)
    RDS_USERNAME=$(jq -r '.resources.rds_instance.username' .cluster-config/cluster-resources.json)
    RDS_PASSWORD=$(jq -r '.resources.rds_instance.password' .cluster-config/cluster-resources.json)
    NODEJS_ORDER_SERVICE_ACCOUNT=$(jq -r '.resources.nodejs_order_service_account' .cluster-config/cluster-resources.json)
    NODEJS_DELIVERY_SERVICE_ACCOUNT=$(jq -r '.resources.nodejs_delivery_service_account' .cluster-config/cluster-resources.json)

    log "SUCCESS" "Configuration loaded successfully"
}

# Create ECR repositories for Node.js
create_ecr_repos() {
    log "INFO" "Creating ECR repositories for Node.js..."
    
    for repo in "nodejs-order-api" "nodejs-delivery-api"; do
        if ! aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" &>/dev/null; then
            aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION"
            log "SUCCESS" "Created ECR repository: $repo"
        else
            log "INFO" "ECR repository already exists: $repo"
        fi
    done
}

# Log in to ECR
ecr_login() {
    log "INFO" "Logging in to ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
    log "SUCCESS" "Successfully logged in to ECR"
}

# Build and push Docker images for Node.js
build_and_push_images() {
    local ecr_url="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

    log "INFO" "Building and pushing Node.js Docker images..."

    # Build and push Node.js Order API
    log "INFO" "Building Node.js Order API..."
    if ! docker build \
        --platform=linux/amd64 \
        -t "$ecr_url/nodejs-order-api:latest" \
        order-api \
        --no-cache; then
        
        log "ERROR" "Failed to build Node.js Order API image"
        exit 1
    fi

    log "INFO" "Pushing Node.js Order API image..."
    if ! docker push "$ecr_url/nodejs-order-api:latest"; then
        log "ERROR" "Failed to push Node.js Order API image"
        exit 1
    fi

    # Build and push Node.js Delivery API
    log "INFO" "Building Node.js Delivery API..."
    if ! docker build \
        --platform=linux/amd64 \
        -t "$ecr_url/nodejs-delivery-api:latest" \
        delivery-api \
        --no-cache; then
        
        log "ERROR" "Failed to build Node.js Delivery API image"
        exit 1
    fi
    log "INFO" "Pushing Node.js Delivery API image..."
    if ! docker push "$ecr_url/nodejs-delivery-api:latest"; then
        log "ERROR" "Failed to push Node.js Delivery API image"
        exit 1
    fi

    log "SUCCESS" "Node.js Docker images built and pushed successfully"
}

# Generate Kubernetes deployment files for Node.js
create_k8s_files() {
    log "INFO" "Generating Kubernetes deployment files for Node.js..."
    
    # Use the manifest generation script
    if [ -f "scripts/generate-k8s-manifests.sh" ]; then
        bash scripts/generate-k8s-manifests.sh
        return 0
    fi
    
    # Fallback: create manifests directly (for backward compatibility)
    mkdir -p kubernetes

    # Create Node.js Order API deployment
    cat > kubernetes/nodejs-order-api-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nodejs-order-api
  namespace: default
  labels:
    app: nodejs-order-api
    component: api
    service: order
    framework: express
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nodejs-order-api
      component: api
      service: order
  template:
    metadata:
      labels:
        app: nodejs-order-api
        component: api
        service: order
        framework: express
    spec:
      serviceAccountName: ${NODEJS_ORDER_SERVICE_ACCOUNT}
      containers:
      - name: nodejs-order-api
        image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/nodejs-order-api:latest
        ports:
        - name: http
          containerPort: 8080
        env:
        - name: HOST
          value: "0.0.0.0"
        - name: PORT
          value: "8080"
        - name: NODE_ENV
          value: "production"
        - name: DELIVERY_API_URL
          value: "http://nodejs-delivery-api-service:5000"
        - name: HTTP_TIMEOUT
          value: "30000"
        - name: HTTP_MAX_RETRIES
          value: "3"
        - name: OTEL_SERVICE_NAME
          value: "nodejs-order-api"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "service.name=nodejs-order-api,service.version=1.0"
        - name: LOG_LEVEL
          value: "info"
        - name: LOG_FORMAT
          value: "json"
        - name: OTEL_NODE_LOG_CORRELATION
          value: "true"
        - name: OTEL_NODE_ENABLED_INSTRUMENTATIONS
          value: "http,express,fs,dns,net"
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://cloudwatch-agent.amazon-cloudwatch:4316"
        - name: OTEL_PROPAGATORS
          value: "tracecontext,baggage,b3,xray"
        - name: OTEL_TRACES_EXPORTER
          value: "otlp"
        - name: OTEL_METRICS_EXPORTER
          value: "otlp"
        - name: OTEL_LOGS_EXPORTER
          value: "otlp"
        livenessProbe:
          httpGet:
            path: /api/orders/health
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
          successThreshold: 1
        readinessProbe:
          httpGet:
            path: /api/orders/health
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
          successThreshold: 1
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
EOF

    # Create Node.js Delivery API deployment
    cat > kubernetes/nodejs-delivery-api-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nodejs-delivery-api
  namespace: default
  labels:
    app: nodejs-delivery-api
    component: api
    service: delivery
    framework: express
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nodejs-delivery-api
      component: api
      service: delivery
  template:
    metadata:
      labels:
        app: nodejs-delivery-api
        component: api
        service: delivery
        framework: express
    spec:
      serviceAccountName: ${NODEJS_DELIVERY_SERVICE_ACCOUNT}
      containers:
      - name: nodejs-delivery-api
        image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/nodejs-delivery-api:latest
        ports:
        - name: http
          containerPort: 5000
        env:
        - name: HOST
          value: "0.0.0.0"
        - name: PORT
          value: "5000"
        - name: NODE_ENV
          value: "production"
        - name: AWS_REGION
          value: "${AWS_REGION}"
        - name: MYSQL_HOST
          value: "${RDS_ENDPOINT}"
        - name: MYSQL_DATABASE
          value: "${RDS_DATABASE}"
        - name: MYSQL_USER
          value: "${RDS_USERNAME}"
        - name: MYSQL_PASSWORD
          value: "${RDS_PASSWORD}"
        - name: MYSQL_PORT
          value: "3306"
        - name: OTEL_SERVICE_NAME
          value: "nodejs-delivery-api"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "service.name=nodejs-delivery-api,service.version=1.0,service.namespace=delivery,aws.local.service=nodejs-delivery-api"
        - name: LOG_LEVEL
          value: "info"
        - name: LOG_FORMAT
          value: "json"
        - name: OTEL_NODE_LOG_CORRELATION
          value: "true"
        - name: OTEL_NODE_ENABLED_INSTRUMENTATIONS
          value: "http,express,fs,dns,net,mysql2,sequelize"
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://cloudwatch-agent.amazon-cloudwatch:4316"
        - name: OTEL_PROPAGATORS
          value: "tracecontext,baggage,b3,xray"
        - name: OTEL_TRACES_EXPORTER
          value: "otlp"
        - name: OTEL_METRICS_EXPORTER
          value: "otlp"
        - name: OTEL_LOGS_EXPORTER
          value: "otlp"
        livenessProbe:
          httpGet:
            path: /api/delivery/health
            port: 5000
            scheme: HTTP
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
          successThreshold: 1
        readinessProbe:
          httpGet:
            path: /api/delivery/health
            port: 5000
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
          successThreshold: 1
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
EOF

    # Create services for Node.js (Order API external, Delivery API internal)
    cat > kubernetes/nodejs-services.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: nodejs-order-api
  namespace: default
  labels:
    app: nodejs-order-api
    component: api
    service: order
    framework: express
spec:
  selector:
    app: nodejs-order-api
    component: api
    service: order
  ports:
    - name: http
      protocol: TCP
      port: 80              
      targetPort: 8080
  type: LoadBalancer

---
apiVersion: v1
kind: Service
metadata:
  name: nodejs-delivery-api-service
  namespace: default
  labels:
    app: nodejs-delivery-api
    component: api
    service: delivery
    framework: express
spec:
  selector:
    app: nodejs-delivery-api
    component: api
    service: delivery
  ports:
    - name: http
      protocol: TCP
      port: 5000
      targetPort: 5000
  type: ClusterIP
EOF
    log "SUCCESS" "Kubernetes manifests created successfully"
}

# Deploy to Kubernetes
deploy_to_k8s() {
    log "INFO" "Deploying Node.js applications to Kubernetes..."
    
    # Use generated manifests if available, otherwise use templates
    MANIFEST_DIR="kubernetes"
    if [ -d "kubernetes/generated" ]; then
        MANIFEST_DIR="kubernetes/generated"
        log "INFO" "Using generated manifests from ${MANIFEST_DIR}"
    else
        log "WARNING" "Using template manifests from ${MANIFEST_DIR}"
    fi
    
    log "INFO" "Applying Node.js Order API deployment..."
    kubectl apply -f ${MANIFEST_DIR}/nodejs-order-api-deployment.yaml
    
    log "INFO" "Applying Node.js Delivery API deployment..."
    kubectl apply -f ${MANIFEST_DIR}/nodejs-delivery-api-deployment.yaml
    
    log "INFO" "Applying Node.js services..."
    kubectl apply -f ${MANIFEST_DIR}/nodejs-services.yaml
    
    log "INFO" "Waiting for deployments to be ready..."
    
    log "INFO" "Waiting for Node.js Order API deployment..."
    kubectl rollout status deployment nodejs-order-api
    
    log "INFO" "Waiting for Node.js Delivery API deployment..."
    kubectl rollout status deployment nodejs-delivery-api
    
    log "SUCCESS" "Deployments completed successfully"
}

# Verify deployment
verify_deployment() {
    log "INFO" "Verifying Node.js deployment..."
    local max_attempts=30
    local wait_seconds=10
    local deployments=("nodejs-order-api" "nodejs-delivery-api")

    for deployment in "${deployments[@]}"; do
        log "INFO" "Verifying deployment: $deployment"
        for ((i=1; i<=max_attempts; i++)); do
            if kubectl rollout status "deployment/$deployment" &>/dev/null; then
                log "SUCCESS" "$deployment is ready"
                break
            fi
            if [ $i -eq $max_attempts ]; then
                log "ERROR" "$deployment failed to become ready"
                exit 1
            fi
            log "WARNING" "Waiting for $deployment... Attempt $i of $max_attempts"
            sleep $wait_seconds
        done
    done

    log "SUCCESS" "Deployment verification completed successfully"
}

# Print deployment summary
print_deployment_summary() {
    log "INFO" "Getting Node.js deployment summary..."
    
    NODEJS_ORDER_API_ENDPOINT=$(kubectl get service nodejs-order-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    log "SUCCESS" "\n========================================="
    log "SUCCESS" "Node.js Deployment Summary"
    log "SUCCESS" "========================================="
    
    log "INFO" "Node.js Order API Endpoint: http://${NODEJS_ORDER_API_ENDPOINT}"
    log "INFO" "Node.js Delivery API: Internal service (ClusterIP)"
    
    log "INFO" "\nFrameworks Used:"
    log "INFO" "  - Order API: Express.js (port 8080)"
    log "INFO" "  - Delivery API: Express.js (port 5000)"
    
    log "INFO" "\nNext Steps:"
    log "INFO" "Run the CloudWatch Agent setup script:"
    log "INFO" "   ./scripts/3-setup-cloudwatch-agent.sh"
}

# Parse arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                log "INFO" "Usage: $0 [--skip-build]"
                log "INFO" "Options:"
                log "INFO" "  --skip-build    Skip building and pushing Docker images"
                exit 0
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                log "INFO" "Usage: $0 [--skip-build]"
                exit 1
                ;;
        esac
    done
}

# Main execution
main() {
    log "INFO" "Starting Node.js build and deployment process..."
    
    parse_arguments "$@"
    load_configuration
    create_ecr_repos
    
    if [ "$SKIP_BUILD" != "true" ]; then
        ecr_login
        build_and_push_images
    else
        log "WARNING" "Skipping build and push of Docker images"
    fi
    
    create_k8s_files
    deploy_to_k8s
    verify_deployment
    print_deployment_summary
}

# Execute main function with arguments
main "$@"