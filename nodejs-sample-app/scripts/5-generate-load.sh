#!/bin/bash
set -eo pipefail

# Enable debug mode if DEBUG environment variable is set
if [[ "${DEBUG}" == "true" ]]; then
    set -x
fi

# Get script and project directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TRAFFIC_GEN_DIR="${SCRIPT_DIR}/traffic-generator"

# Log levels and colors
ERROR_COLOR='\033[0;31m'
SUCCESS_COLOR='\033[0;32m'
WARNING_COLOR='\033[1;33m'
INFO_COLOR='\033[0;34m'
NO_COLOR='\033[0m'

# Logging function
log() {
    local level=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    local message="$2"
    local color
    
    case $level in
        ERROR)   color=$ERROR_COLOR ;;
        SUCCESS) color=$SUCCESS_COLOR ;;
        WARNING) color=$WARNING_COLOR ;;
        INFO)    color=$INFO_COLOR ;;
        *)       color=$INFO_COLOR ;;
    esac
    
    echo -e "${color}${level}: ${message}${NO_COLOR}"
}

# Error handling
handle_error() {
    log "ERROR" "$1"
    exit 1
}

trap 'handle_error "Error occurred on line $LINENO"' ERR

# Load configuration
load_configuration() {
    local config_file="${PROJECT_ROOT}/.cluster-config/cluster-resources.json"
    
    if [[ ! -f $config_file ]]; then
        handle_error "Cluster configuration not found at: $config_file. Run 1-create-env.sh first."
    fi

    AWS_ACCOUNT_ID=$(jq -r '.cluster.account_id' "$config_file")
    AWS_REGION=$(jq -r '.cluster.region' "$config_file")
    CLUSTER_NAME=$(jq -r '.cluster.name' "$config_file")

    if [[ -z $AWS_ACCOUNT_ID || -z $AWS_REGION || -z $CLUSTER_NAME ]]; then
        handle_error "Failed to load configuration"
    fi

    log "INFO" "Configuration loaded:"
    log "INFO" "Cluster: $CLUSTER_NAME"
    log "INFO" "Region: $AWS_REGION"
    log "INFO" "Account: $AWS_ACCOUNT_ID"
}

# Check prerequisites
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    local required_tools="docker kubectl aws jq"
    local missing_tools=()

    for tool in $required_tools; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        handle_error "Missing required tools: ${missing_tools[*]}"
    fi

    # Check AWS CLI configuration
    if ! aws sts get-caller-identity &>/dev/null; then
        handle_error "AWS CLI is not configured properly, refresh credentials if required"
    fi

    log "SUCCESS" "Prerequisites check passed"
}

# Build and push Docker image for Node.js workflow testing
build_and_push() {
    log "INFO" "Building Node.js traffic generator image..."

    # Change to the traffic-generator directory
    cd "${TRAFFIC_GEN_DIR}"

    # Create ECR repository if it doesn't exist
    if ! aws ecr describe-repositories --repository-names "nodejs-traffic-generator" --region "$AWS_REGION" &>/dev/null; then
        log "INFO" "Creating ECR repository for Node.js traffic generator..."
        aws ecr create-repository --repository-name "nodejs-traffic-generator" --region "$AWS_REGION"
    fi

    # Login to ECR
    log "INFO" "Logging into ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

    # Build image with platform specification
    log "INFO" "Building Docker image for Node.js workflow testing..."
    docker build -t nodejs-traffic-generator:v2.0 \
        --platform linux/amd64 \
        --no-cache \
        .

    # Tag and push
    log "INFO" "Pushing Node.js traffic generator image to ECR..."
    docker tag nodejs-traffic-generator:v2.0 "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/nodejs-traffic-generator:v2.0"
    docker push "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/nodejs-traffic-generator:v2.0"

    log "SUCCESS" "Node.js traffic generator image built and pushed successfully"
}

# Create ConfigMaps with Node.js service configuration
create_service_configs() {
    log "INFO" "Creating Node.js service ConfigMaps..."
    
    # Get Node.js Order API URL directly
    log "INFO" "Getting Node.js Order API URL..."
    
    if ! command -v kubectl &> /dev/null; then
        handle_error "kubectl is required but not installed"
    fi

    local alb_url=$(kubectl get service nodejs-order-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    if [ -z "$alb_url" ]; then
        log "ERROR" "Failed to get Node.js Order API URL. Is the service running?"
        kubectl get svc
        handle_error "Failed to get Node.js Order API URL"
    fi
    
    # Create ALB ConfigMap for Node.js workflow testing
    log "INFO" "Creating ALB configmap for Node.js workflow testing with URL: http://$alb_url"
    kubectl create configmap nodejs-alb-config \
        --from-literal=url="http://$alb_url" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Verify configmap was created
    if kubectl get configmap nodejs-alb-config &>/dev/null; then
        log "SUCCESS" "Node.js service ConfigMap created successfully"
        log "INFO" "Target URL: http://$alb_url"
        log "INFO" "Traffic will flow: Load Generator -> Order API -> Delivery API -> MySQL"
    else
        handle_error "Failed to create Node.js service ConfigMap"
    fi
}

# Create Kubernetes deployment files for Node.js workflow testing
create_k8s_files() {
    log "INFO" "Creating Kubernetes deployment files for Node.js workflow testing..."
    mkdir -p "${TRAFFIC_GEN_DIR}/kubernetes"

    # Create Node.js traffic-generator deployment
    cat > "${TRAFFIC_GEN_DIR}/kubernetes/deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nodejs-traffic-generator
  labels:
    app: nodejs-traffic-generator
    target: nodejs-apis
    workflow: direct
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nodejs-traffic-generator
  template:
    metadata:
      labels:
        app: nodejs-traffic-generator
        target: nodejs-apis
        workflow: direct
    spec:
      containers:
      - name: nodejs-traffic-generator
        image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/nodejs-traffic-generator:v2.0
        env:
        - name: ALB_URL
          valueFrom:
            configMapKeyRef:
              name: nodejs-alb-config
              key: url
        - name: API_PATH
          value: "/api/orders"
        - name: BATCH_SIZE
          value: "3"
        - name: STATS_INTERVAL
          value: "60"
        - name: WORKFLOW_TYPE
          value: "direct"
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"

EOF

    log "SUCCESS" "Kubernetes manifests created successfully for Node.js workflow testing"
}

# Deploy traffic generator for Node.js workflow testing
deploy() {
    log "INFO" "Deploying Node.js traffic generator..."
    
    # Check if deployment already exists and delete it
    if kubectl get deployment nodejs-traffic-generator &>/dev/null; then
        log "INFO" "Existing deployment found - deleting for clean redeploy..."
        kubectl delete deployment nodejs-traffic-generator
        # Wait for deletion to complete
        kubectl wait --for=delete deployment/nodejs-traffic-generator --timeout=60s 2>/dev/null || true
    fi
    
    # Apply the deployment
    log "INFO" "Applying Node.js traffic generator deployment..."
    kubectl apply -f "${TRAFFIC_GEN_DIR}/kubernetes/deployment.yaml" || {
        log "ERROR" "Failed to apply deployment"
        exit 1
    }
    
    # Wait for deployment with timeout
    log "INFO" "Waiting for Node.js traffic generator deployment..."
    
    # Use a portable timeout approach
    (
        # Start kubectl rollout in background and get its PID
        kubectl rollout status deployment/nodejs-traffic-generator &
        ROLLOUT_PID=$!
        
        # Wait up to 120 seconds
        for ((i=1; i<=120; i++)); do
            if ! kill -0 $ROLLOUT_PID 2>/dev/null; then
                # Process completed successfully
                wait $ROLLOUT_PID
                exit $?
            fi
            sleep 1
        done
        
        # If we get here, timeout occurred
        kill $ROLLOUT_PID 2>/dev/null || true
        exit 1
    ) || {
        log "WARNING" "Deployment status check timed out, checking deployment status manually..."
        kubectl get deployment nodejs-traffic-generator 
        kubectl get pods -l app=nodejs-traffic-generator
    }
    
    log "SUCCESS" "Node.js traffic generator deployed successfully"
}

# Parse arguments
parse_args() {
    SKIP_BUILD=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --help)
                log "INFO" "Usage: $0 [--skip-build]"
                log "INFO" "  --skip-build : Skip building and pushing Docker image"
                log "INFO" "  --help      : Show this help message"
                log "INFO" ""
                log "INFO" "This script deploys a traffic generator for testing the Node.js workflow:"
                log "INFO" "Load Generator -> Order API (Express.js) -> Delivery API (Express.js) -> MySQL RDS"
                log "INFO" ""
                log "INFO" "The traffic generator will create realistic order processing scenarios"
                log "INFO" "and measure end-to-end latency and order processing success rates."
                exit 0
                ;;
            *)
                handle_error "Unknown argument: $1"
                ;;
        esac
    done
}

# Main execution
main() {
    log "INFO" "Starting Node.js traffic generator deployment..."
    
    check_prerequisites
    load_configuration
    
    if [[ "$SKIP_BUILD" != "true" ]]; then
        build_and_push
    else
        log "INFO" "Skipping build phase"
    fi
    
    create_service_configs
    create_k8s_files
    deploy
    
    log "SUCCESS" "Node.js traffic generator setup completed"
    log "INFO" "To view logs: kubectl logs -f deployment/nodejs-traffic-generator"
    log "INFO" "Traffic pattern: Load Generator -> Order API -> Delivery API -> MySQL"
    log "INFO" "Monitor CloudWatch Application Signals for end-to-end traces and metrics"
    log "INFO" "Key metrics: Order processing success rate, end-to-end latency, service communication"
}

# Parse arguments and run main
parse_args "$@"
main