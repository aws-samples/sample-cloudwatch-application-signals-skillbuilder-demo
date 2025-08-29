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
        log "ERROR" "Cluster configuration not found. Please run create-env.sh first."
        exit 1
    fi

    log "INFO" "Loading configuration..."
    
    AWS_REGION=$(jq -r '.cluster.region' .cluster-config/cluster-resources.json)
    AWS_ACCOUNT_ID=$(jq -r '.cluster.account_id' .cluster-config/cluster-resources.json)
}

# Remove Kubernetes resources
remove_k8s_resources() {
    log "INFO" "Removing Python Kubernetes resources..."
    
    if [ "$TRAFFIC_ONLY" != "true" ]; then
        kubectl delete -f kubernetes/python-services.yaml --ignore-not-found
        kubectl delete -f kubernetes/python-order-api-deployment.yaml --ignore-not-found
        kubectl delete -f kubernetes/python-delivery-api-deployment.yaml --ignore-not-found
        kubectl delete configmap python-otel-config --ignore-not-found
    fi
    
    # Delete Python traffic generator deployment
    log "INFO" "Removing Python traffic generator deployment..."
    kubectl delete deployment python-traffic-generator --ignore-not-found
    kubectl delete configmap python-alb-config --ignore-not-found
    kubectl delete configmap python-mysql-config --ignore-not-found
    
    log "SUCCESS" "Python Kubernetes resources removed"
}

# Remove ECR repositories
remove_ecr_repos() {
    log "INFO" "Removing Python ECR repositories..."
    
    for repo in "python-order-api" "python-delivery-api" "python-traffic-generator"; do
        if aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" &>/dev/null; then
            aws ecr delete-repository --repository-name "$repo" --region "$AWS_REGION" --force
            log "SUCCESS" "Removed ECR repository: $repo"
        else
            log "INFO" "ECR repository not found: $repo"
        fi
    done
    
    log "SUCCESS" "Python ECR repositories removed"
}

# Remove local Docker images
remove_local_images() {
    log "INFO" "Removing local Python Docker images..."
    
    docker rmi "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/python-order-api:latest" --force 2>/dev/null || true
    docker rmi "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/python-delivery-api:latest" --force 2>/dev/null || true
    docker rmi "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/python-traffic-generator:latest" --force 2>/dev/null || true
    docker rmi "python-traffic-generator:latest" --force 2>/dev/null || true
    
    log "SUCCESS" "Local Python Docker images removed"
}

# Clean up local files
cleanup_local_files() {
    log "INFO" "Cleaning up local files..."
    
    rm -rf kubernetes
    rm -rf scripts/traffic-generator/kubernetes
    
    log "SUCCESS" "Local files cleaned up"
}

# Parse arguments
parse_arguments() {
    TRAFFIC_ONLY=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --traffic-only)
                TRAFFIC_ONLY=true
                shift
                ;;
            --help)
                log "INFO" "Usage: $0 [--traffic-only]"
                log "INFO" "Options:"
                log "INFO" "  --traffic-only    Only remove Python traffic generator deployment"
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                log "INFO" "Usage: $0 [--traffic-only]"
                exit 1
                ;;
        esac
    done
}

# Main execution
main() {
    log "INFO" "Starting Python cleanup process..."
    
    parse_arguments "$@"
    load_configuration
    remove_k8s_resources
    
    if [ "$TRAFFIC_ONLY" != "true" ]; then
        remove_ecr_repos
        remove_local_images
        cleanup_local_files
        
        log "SUCCESS" "Python cleanup completed successfully"
        log "INFO" "You can now delete the cluster using the following script:"
        log "INFO" "./scripts/9-cleanup-env.sh"
    else
        log "SUCCESS" "Python traffic generator cleanup completed successfully"
    fi
}

# Run main function
main "$@"