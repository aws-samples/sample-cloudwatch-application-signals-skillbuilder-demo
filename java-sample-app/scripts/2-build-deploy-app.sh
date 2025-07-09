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
    DYNAMODB_TABLE_NAME=$(jq -r '.resources.dynamodb_table' .cluster-config/cluster-resources.json)
    ORDER_SERVICE_ACCOUNT=$(jq -r '.resources.order_service_account' .cluster-config/cluster-resources.json)
    DELIVERY_SERVICE_ACCOUNT=$(jq -r '.resources.delivery_service_account' .cluster-config/cluster-resources.json)

    log "SUCCESS" "Configuration loaded successfully"
}

# Create ECR repositories
create_ecr_repos() {
    log "INFO" "Creating ECR repositories..."
    
    for repo in "java-order-api" "java-delivery-api"; do
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

    # Build and push Order API
    log "INFO" "Building Order API..."
    if ! docker build \
        --platform=linux/amd64 \
        -t "$ecr_url/java-order-api:latest" \
        -f order-api/Dockerfile \
        . \
        --no-cache; then
        
        log "ERROR" "Failed to build Order API image"
        exit 1
    fi

    log "INFO" "Pushing Order API image..."
    if ! docker push "$ecr_url/java-order-api:latest"; then
        log "ERROR" "Failed to push Order API image"
        exit 1
    fi

    # Build and push Delivery API
    log "INFO" "Building Delivery API..."
    if ! docker build \
        --platform=linux/amd64 \
        -t "$ecr_url/java-delivery-api:latest" \
        -f delivery-api/Dockerfile \
        . \
        --no-cache; then
        
        log "ERROR" "Failed to build Delivery API image"
        exit 1
    fi
    log "INFO" "Pushing Delivery API image..."
    if ! docker push "$ecr_url/java-delivery-api:latest"; then
        log "ERROR" "Failed to push Delivery API image"
        exit 1
    fi

    log "SUCCESS" "Docker images built and pushed successfully"
}

# Create Kubernetes deployment files
create_k8s_files() {
    log "INFO" "Creating Kubernetes deployment files..."
    mkdir -p kubernetes

    # Create Order API deployment
    cat > kubernetes/order-api-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: java-order-api
  namespace: default
  labels:
    app: java-order-api
    component: api
    service: order
spec:
  replicas: 2
  selector:
    matchLabels:
      app: java-order-api
      component: api
      service: order
  template:
    metadata:
      labels:
        app: java-order-api
        component: api
        service: order
    spec:
      serviceAccountName: ${ORDER_SERVICE_ACCOUNT}
      containers:
      - name: java-order-api
        image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/java-order-api:latest
        ports:
        - name: http
          containerPort: 8080
        env:
        - name: DYNAMODB_TABLE_NAME
          value: "${DYNAMODB_TABLE_NAME}"
        - name: AWS_REGION
          value: "${AWS_REGION}"
        - name: DELIVERY_API_URL
          value: "http://java-delivery-api/api/delivery"
EOF

    # Create Delivery API deployment
    cat > kubernetes/delivery-api-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: java-delivery-api
  namespace: default
  labels:
    app: java-delivery-api
    component: api
    service: delivery
spec:
  replicas: 2
  selector:
    matchLabels:
      app: java-delivery-api
      component: api
      service: delivery
  template:
    metadata:
      labels:
        app: java-delivery-api
        component: api
        service: delivery
    spec:
      serviceAccountName: ${DELIVERY_SERVICE_ACCOUNT}
      containers:
      - name: java-delivery-api
        image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/java-delivery-api:latest
        ports:
        - name: http
          containerPort: 8080
        env:
        - name: DYNAMODB_TABLE_NAME
          value: "${DYNAMODB_TABLE_NAME}"
        - name: AWS_REGION
          value: "${AWS_REGION}"
EOF


# Create services
    cat > kubernetes/services.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: java-order-api
  namespace: default
  labels:
    app: java-order-api
    component: api
    service: order
spec:
  selector:
    app: java-order-api
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
  name: java-delivery-api
  namespace: default
  labels:
    app: java-delivery-api
    component: api
    service: delivery
spec:
  selector:
    app: java-delivery-api
    component: api
    service: delivery
  ports:
    - name: http
      protocol: TCP
      port: 80             
      targetPort: 8080
  type: ClusterIP
EOF
    log "SUCCESS" "Kubernetes manifests created successfully"
}


# Deploy to Kubernetes
deploy_to_k8s() {
    log "INFO" "Deploying to Kubernetes..."
    
    log "INFO" "Applying Order API deployment..."
    kubectl apply -f kubernetes/order-api-deployment.yaml
    
    log "INFO" "Applying Delivery API deployment..."
    kubectl apply -f kubernetes/delivery-api-deployment.yaml
    
    log "INFO" "Applying services..."
    kubectl apply -f kubernetes/services.yaml
    
    log "INFO" "Waiting for deployments to be ready..."
    
    log "INFO" "Waiting for Order API deployment..."
    kubectl rollout status deployment java-order-api
    
    log "INFO" "Waiting for Delivery API deployment..."
    kubectl rollout status deployment java-delivery-api
    
    log "SUCCESS" "Deployments completed successfully"
}

# Verify deployment
verify_deployment() {
    log "INFO" "Verifying deployment..."
    local max_attempts=30
    local wait_seconds=10
    local deployments=("java-order-api" "java-delivery-api")

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
    
    ORDER_API_ENDPOINT=$(kubectl get service java-order-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    log "SUCCESS" "\n========================================="
    log "SUCCESS" "Deployment Summary"
    log "SUCCESS" "========================================="
    
    log "INFO" "Order API Endpoint: http://${ORDER_API_ENDPOINT}"
    log "INFO" "Delivery API (internal service): http://java-delivery-api (cluster-internal only)"
    
#    log "WARNING" "Note: It may take a few minutes for the load balancers to become available"
    
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
    log "INFO" "Starting build and deployment process..."
    
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
