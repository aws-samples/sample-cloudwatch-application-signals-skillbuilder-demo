#!/usr/bin/env bash
set -eo pipefail

# Log levels and colors
ERROR_COLOR='\033[0;31m'
SUCCESS_COLOR='\033[0;32m'
WARNING_COLOR='\033[1;33m'
INFO_COLOR='\033[0;34m'
NO_COLOR='\033[0m'

# Logging function
log() {
    local level=$(echo "${1}" | tr '[:lower:]' '[:upper:]')
    local message="$2"
    local color
    
    case $level in
        ERROR)   color=$ERROR_COLOR ;;
        SUCCESS) color=$SUCCESS_COLOR ;;
        WARNING) color=$WARNING_COLOR ;;
        INFO)    color=$INFO_COLOR ;;
        *)       color=$INFO_COLOR ;;
    esac
    
    echo -e "${color}${level}: ${message}${NO_COLOR}" >&2
}

# Check if kubernetes directory exists
check_kubernetes_directory() {
    if [[ ! -d "kubernetes" ]]; then
        log "ERROR" "Kubernetes directory not found. Please run 2-build-deploy-app.sh first."
        exit 1
    fi
    log "INFO" "Kubernetes directory found"
}

# Process each deployment file for Node.js auto-instrumentation
process_file() {
    local file="$1"
    local temp_file="${file}.tmp"
    
    log "INFO" "Processing: $file"
    
    # Check if annotations already exist
    if grep -q "instrumentation.opentelemetry.io/inject-nodejs" "$file"; then
        log "INFO" "Node.js auto-instrumentation annotations already exist in $file"
        return 0
    fi
    
    # Create temporary file with Node.js OpenTelemetry auto-instrumentation annotations
    awk '
    /template:/ { in_template = 1 }
    /metadata:/ && in_template && !annotations_added {
        print $0
        # Check if annotations section already exists
        getline next_line
        if (next_line ~ /annotations:/) {
            print next_line
            print "        instrumentation.opentelemetry.io/inject-nodejs: \"true\""
        } else {
            print "      annotations:"
            print "        instrumentation.opentelemetry.io/inject-nodejs: \"true\""
            print next_line
        }
        annotations_added = 1
        in_template = 0
        next
    }
    { print }' "$file" > "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$file"
    log "SUCCESS" "Updated $file with Node.js auto-instrumentation annotations"
}

# Apply updated deployments
apply_deployments() {
    log "INFO" "Applying updated deployments to Kubernetes..."
    
    # Determine which manifest directory to use
    MANIFEST_DIR="kubernetes"
    if [[ -d "kubernetes/generated" ]]; then
        MANIFEST_DIR="kubernetes/generated"
        log "INFO" "Using generated manifests from ${MANIFEST_DIR}"
    fi
    
    for file in ${MANIFEST_DIR}/nodejs-order-api-deployment.yaml ${MANIFEST_DIR}/nodejs-delivery-api-deployment.yaml; do
        if [[ -f "$file" ]]; then
            log "INFO" "Applying $file"
            kubectl apply -f "$file"
        else
            log "WARNING" "File not found: $file"
        fi
    done
    
    log "INFO" "Waiting for deployments to restart with new annotations..."
    
    # Wait for rollout to complete
    if kubectl get deployment nodejs-order-api &>/dev/null; then
        kubectl rollout restart deployment/nodejs-order-api
        kubectl rollout status deployment/nodejs-order-api --timeout=300s
        log "SUCCESS" "Node.js Order API deployment restarted successfully"
    fi
    
    if kubectl get deployment nodejs-delivery-api &>/dev/null; then
        kubectl rollout restart deployment/nodejs-delivery-api
        kubectl rollout status deployment/nodejs-delivery-api --timeout=300s
        log "SUCCESS" "Node.js Delivery API deployment restarted successfully"
    fi
}

# Verify instrumentation
verify_instrumentation() {
    log "INFO" "Verifying Node.js auto-instrumentation..."
    
    # Check if pods have the instrumentation annotations
    local order_pods=$(kubectl get pods -l app=nodejs-order-api -o jsonpath='{.items[*].metadata.annotations}' 2>/dev/null || echo "")
    local delivery_pods=$(kubectl get pods -l app=nodejs-delivery-api -o jsonpath='{.items[*].metadata.annotations}' 2>/dev/null || echo "")
    
    if [[ $order_pods == *"instrumentation.opentelemetry.io/inject-nodejs"* ]]; then
        log "SUCCESS" "Node.js Order API pods have instrumentation annotations"
    else
        log "WARNING" "Node.js Order API pods may not have instrumentation annotations"
    fi
    
    if [[ $delivery_pods == *"instrumentation.opentelemetry.io/inject-nodejs"* ]]; then
        log "SUCCESS" "Node.js Delivery API pods have instrumentation annotations"
    else
        log "WARNING" "Node.js Delivery API pods may not have instrumentation annotations"
    fi
    
    # Check pod status
    log "INFO" "Checking pod status..."
    kubectl get pods -l 'app in (nodejs-order-api,nodejs-delivery-api)' -o wide
}

main() {
    log "INFO" "Starting Node.js workload annotation process..."
    
    check_kubernetes_directory
    
    # Determine which manifest directory to use
    MANIFEST_DIR="kubernetes"
    if [[ -d "kubernetes/generated" ]]; then
        MANIFEST_DIR="kubernetes/generated"
        log "INFO" "Processing generated manifests from ${MANIFEST_DIR}"
    else
        log "INFO" "Processing template manifests from ${MANIFEST_DIR}"
    fi
    
    cd "$MANIFEST_DIR"
    
    # Process Node.js deployment files
    for file in nodejs-order-api-deployment.yaml nodejs-delivery-api-deployment.yaml; do
        if [[ -f "$file" ]]; then
            process_file "$file"
        else
            log "ERROR" "File not found: $file"
            exit 1
        fi
    done
    
    cd ..
    apply_deployments
    verify_instrumentation
    
    log "SUCCESS" "\n========================================="
    log "SUCCESS" "Node.js workload annotation completed!"
    log "SUCCESS" "========================================="
    log "INFO" "\nNode.js applications are now configured with:"
    log "INFO" "- OpenTelemetry auto-instrumentation annotations"
    log "INFO" "- CloudWatch Application Signals integration"
    log "INFO" "- Automatic trace and metrics collection for HTTP client calls and RDS"
    log "INFO" "- Automatic instrumentation for Express.js, HTTP, and MySQL frameworks"
    log "INFO" "- Direct REST API communication architecture"
    log "INFO" "\nNext Steps:"
    log "INFO" "- Run 5-generate-load.sh to generate traffic and test observability"
    log "INFO" "- Check CloudWatch Application Signals in AWS Console"
}

main