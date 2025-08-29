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

# Process each deployment file for Python auto-instrumentation
process_file() {
    local file="$1"
    local temp_file="${file}.tmp"
    
    log "INFO" "Processing: $file"
    
    # Create temporary file with Python OpenTelemetry auto-instrumentation annotations
    awk '
    /template:/ { in_template = 1 }
    /metadata:/ && in_template {
        print $0
        print "      annotations:"
        print "        instrumentation.opentelemetry.io/inject-python: \"true\""
        in_template = 0
        next
    }
    { print }' "$file" > "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$file"
    log "SUCCESS" "Updated $file with Python auto-instrumentation annotations"
}

# Apply updated deployments
apply_deployments() {
    log "INFO" "Applying updated deployments to Kubernetes..."
    
    for file in kubernetes/python-order-api-deployment.yaml kubernetes/python-delivery-api-deployment.yaml; do
        if [[ -f "$file" ]]; then
            log "INFO" "Applying $file"
            kubectl apply -f "$file"
        else
            log "WARNING" "File not found: $file"
        fi
    done
    
    log "INFO" "Waiting for deployments to restart with new annotations..."
    
    # Wait for rollout to complete
    if kubectl get deployment python-order-api &>/dev/null; then
        kubectl rollout restart deployment/python-order-api
        kubectl rollout status deployment/python-order-api --timeout=300s
        log "SUCCESS" "Python Order API deployment restarted successfully"
    fi
    
    if kubectl get deployment python-delivery-api &>/dev/null; then
        kubectl rollout restart deployment/python-delivery-api
        kubectl rollout status deployment/python-delivery-api --timeout=300s
        log "SUCCESS" "Python Delivery API deployment restarted successfully"
    fi
}

# Verify instrumentation
verify_instrumentation() {
    log "INFO" "Verifying Python auto-instrumentation..."
    
    # Check if pods have the instrumentation annotations
    local order_pods=$(kubectl get pods -l app=python-order-api -o jsonpath='{.items[*].metadata.annotations}' 2>/dev/null || echo "")
    local delivery_pods=$(kubectl get pods -l app=python-delivery-api -o jsonpath='{.items[*].metadata.annotations}' 2>/dev/null || echo "")
    
    if [[ $order_pods == *"instrumentation.opentelemetry.io/inject-python"* ]]; then
        log "SUCCESS" "Python Order API pods have instrumentation annotations"
    else
        log "WARNING" "Python Order API pods may not have instrumentation annotations"
    fi
    
    if [[ $delivery_pods == *"instrumentation.opentelemetry.io/inject-python"* ]]; then
        log "SUCCESS" "Python Delivery API pods have instrumentation annotations"
    else
        log "WARNING" "Python Delivery API pods may not have instrumentation annotations"
    fi
    
    # Check pod status
    log "INFO" "Checking pod status..."
    kubectl get pods -l 'app in (python-order-api,python-delivery-api)' -o wide
}

main() {
    log "INFO" "Starting Python workload annotation process..."
    
    check_kubernetes_directory
    cd kubernetes
    
    # Process Python deployment files
    for file in python-order-api-deployment.yaml python-delivery-api-deployment.yaml; do
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
    log "SUCCESS" "Workload annotations applied!"
    log "SUCCESS" "========================================="
    log "INFO" "\nApplications are now ready for monitoring"
    log "INFO" "\nNext step: Run ./scripts/5-generate-load.sh"
}

main