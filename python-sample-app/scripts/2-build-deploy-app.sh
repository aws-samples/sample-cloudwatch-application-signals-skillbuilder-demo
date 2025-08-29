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
    RDS_ENDPOINT=$(jq -r '.resources.rds_instance.endpoint' .cluster-config/cluster-resources.json)
    RDS_DATABASE=$(jq -r '.resources.rds_instance.database' .cluster-config/cluster-resources.json)
    RDS_USERNAME=$(jq -r '.resources.rds_instance.username' .cluster-config/cluster-resources.json)
    RDS_PASSWORD=$(jq -r '.resources.rds_instance.password' .cluster-config/cluster-resources.json)
    PYTHON_ORDER_SERVICE_ACCOUNT=$(jq -r '.resources.python_order_service_account' .cluster-config/cluster-resources.json)
    PYTHON_DELIVERY_SERVICE_ACCOUNT=$(jq -r '.resources.python_delivery_service_account' .cluster-config/cluster-resources.json)

    log "SUCCESS" "Configuration loaded successfully"
}

# Create ECR repositories
create_ecr_repos() {
    log "INFO" "Creating ECR repositories..."
    
    for repo in "python-order-api" "python-delivery-api"; do
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

# Build and push Docker images
build_and_push_images() {
    local ecr_url="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

    log "INFO" "Building and pushing Docker images..."

    # Build and push Python Order API
    log "INFO" "Building Python Order API..."
    if ! docker build \
        --platform=linux/amd64 \
        -t "$ecr_url/python-order-api:latest" \
        order-api \
        --no-cache; then
        
        log "ERROR" "Failed to build Python Order API image"
        exit 1
    fi

    log "INFO" "Pushing Python Order API image..."
    if ! docker push "$ecr_url/python-order-api:latest"; then
        log "ERROR" "Failed to push Python Order API image"
        exit 1
    fi

    # Build and push Python Delivery API
    log "INFO" "Building Python Delivery API..."
    if ! docker build \
        --platform=linux/amd64 \
        -t "$ecr_url/python-delivery-api:latest" \
        delivery-api \
        --no-cache; then
        
        log "ERROR" "Failed to build Python Delivery API image"
        exit 1
    fi
    log "INFO" "Pushing Python Delivery API image..."
    if ! docker push "$ecr_url/python-delivery-api:latest"; then
        log "ERROR" "Failed to push Python Delivery API image"
        exit 1
    fi

    log "SUCCESS" "Docker images built and pushed successfully"
}

# Create Kubernetes deployment files
create_k8s_files() {
    log "INFO" "Creating Kubernetes deployment files..."
    mkdir -p kubernetes

    # Create Python Order API deployment
    cat > kubernetes/python-order-api-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: python-order-api
  namespace: default
  labels:
    app: python-order-api
    component: api
    service: order
    framework: fastapi
spec:
  replicas: 2
  selector:
    matchLabels:
      app: python-order-api
      component: api
      service: order
  template:
    metadata:
      labels:
        app: python-order-api
        component: api
        service: order
        framework: fastapi
    spec:
      serviceAccountName: ${PYTHON_ORDER_SERVICE_ACCOUNT}
      containers:
      - name: python-order-api
        image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/python-order-api:latest
        command: ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
        ports:
        - name: http
          containerPort: 8080
        env:
        - name: DELIVERY_API_URL
          value: "http://delivery-api-service:5000"
        - name: OTEL_SERVICE_NAME
          value: "python-order-api"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "service.name=python-order-api,service.version=1.0"
        - name: LOG_LEVEL
          value: "INFO"
        - name: LOG_FORMAT
          value: "json"
        - name: OTEL_PYTHON_LOG_CORRELATION
          value: "true"
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

    # Create Python Delivery API deployment (REST service)
    cat > kubernetes/python-delivery-api-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: python-delivery-api
  namespace: default
  labels:
    app: python-delivery-api
    component: api
    service: delivery
    framework: flask
spec:
  replicas: 2
  selector:
    matchLabels:
      app: python-delivery-api
      component: api
      service: delivery
  template:
    metadata:
      labels:
        app: python-delivery-api
        component: api
        service: delivery
        framework: flask
    spec:
      serviceAccountName: ${PYTHON_DELIVERY_SERVICE_ACCOUNT}
      containers:
      - name: python-delivery-api
        image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/python-delivery-api:latest
        ports:
        - name: http
          containerPort: 5000
        env:
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
          value: "python-delivery-api"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "service.name=python-delivery-api,service.version=1.0,service.namespace=delivery,aws.local.service=python-delivery-api"
        - name: LOG_LEVEL
          value: "INFO"
        - name: LOG_FORMAT
          value: "json"
        - name: OTEL_PYTHON_LOG_CORRELATION
          value: "true"
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

    # Create services (Order API external, Delivery API internal)
    cat > kubernetes/python-services.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: python-order-api
  namespace: default
  labels:
    app: python-order-api
    component: api
    service: order
    framework: fastapi
spec:
  selector:
    app: python-order-api
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
  name: delivery-api-service
  namespace: default
  labels:
    app: python-delivery-api
    component: api
    service: delivery
    framework: flask
spec:
  selector:
    app: python-delivery-api
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
    log "INFO" "Deploying to Kubernetes..."
    
    log "INFO" "Applying Python Order API deployment..."
    kubectl apply -f kubernetes/python-order-api-deployment.yaml
    
    log "INFO" "Applying Python Delivery API deployment..."
    kubectl apply -f kubernetes/python-delivery-api-deployment.yaml
    
    log "INFO" "Applying Python services..."
    kubectl apply -f kubernetes/python-services.yaml
    
    log "INFO" "Waiting for deployments to be ready..."
    
    log "INFO" "Waiting for Python Order API deployment..."
    kubectl rollout status deployment python-order-api
    
    log "INFO" "Waiting for Python Delivery API deployment..."
    kubectl rollout status deployment python-delivery-api
    
    log "SUCCESS" "Deployments completed successfully"
}

# Verify deployment
verify_deployment() {
    log "INFO" "Verifying deployment..."
    local max_attempts=30
    local wait_seconds=10
    local deployments=("python-order-api" "python-delivery-api")

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
    log "INFO" "Getting deployment summary..."
    
    PYTHON_ORDER_API_ENDPOINT=$(kubectl get service python-order-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    log "SUCCESS" "\n========================================="
    log "SUCCESS" "Python Deployment Summary"
    log "SUCCESS" "========================================="
    
    log "INFO" "Python Order API Endpoint: http://${PYTHON_ORDER_API_ENDPOINT}"
    log "INFO" "Python Delivery API: Internal REST service (ClusterIP)"
    
    log "INFO" "\nFrameworks Used:"
    log "INFO" "  - Order API: FastAPI (port 8080)"
    log "INFO" "  - Delivery API: Flask REST service (port 5000)"
    
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
    log "INFO" "Starting Python build and deployment process..."
    
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