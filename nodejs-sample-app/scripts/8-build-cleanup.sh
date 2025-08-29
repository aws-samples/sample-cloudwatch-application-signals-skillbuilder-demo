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
        log "ERROR" "Configuration file not found. Nothing to clean up."
        exit 1
    fi

    log "INFO" "Loading configuration..."
    
    CLUSTER_NAME=$(jq -r '.cluster.name' .cluster-config/cluster-resources.json)
    AWS_REGION=$(jq -r '.cluster.region' .cluster-config/cluster-resources.json)
    AWS_ACCOUNT_ID=$(jq -r '.cluster.account_id' .cluster-config/cluster-resources.json)

    if [ "$CLUSTER_NAME" = "null" ] || [ "$AWS_REGION" = "null" ] || [ "$AWS_ACCOUNT_ID" = "null" ]; then
        log "ERROR" "Invalid configuration file"
        exit 1
    fi

    log "SUCCESS" "Configuration loaded successfully"
    log "INFO" "Cluster: ${CLUSTER_NAME}"
    log "INFO" "Region: ${AWS_REGION}"
}

remove_local_images() {
    log "INFO" "Removing local Python Docker images..."
    
    docker rmi "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/python-order-api:latest" --force 2>/dev/null || true
    docker rmi "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/python-delivery-api:latest" --force 2>/dev/null || true
    docker rmi "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/python-traffic-generator:latest" --force 2>/dev/null || true
    docker rmi "python-traffic-generator:latest" --force 2>/dev/null || true
    
    log "SUCCESS" "Local Python Docker images removed"
}

# Delete Kubernetes deployments and services
delete_k8s_resources() {
    log "INFO" "Deleting Node.js Kubernetes resources..."
    
    # Delete traffic generator
    if kubectl get deployment nodejs-traffic-generator &>/dev/null; then
        kubectl delete deployment nodejs-traffic-generator
        log "SUCCESS" "Deleted traffic generator deployment"
    else
        log "INFO" "Traffic generator deployment not found"
    fi
    
    # Delete Node.js applications
    if kubectl get deployment nodejs-order-api &>/dev/null; then
        kubectl delete deployment nodejs-order-api
        log "SUCCESS" "Deleted Node.js Order API deployment"
    else
        log "INFO" "Node.js Order API deployment not found"
    fi
    
    if kubectl get deployment nodejs-delivery-api &>/dev/null; then
        kubectl delete deployment nodejs-delivery-api
        log "SUCCESS" "Deleted Node.js Delivery API deployment"
    else
        log "INFO" "Node.js Delivery API deployment not found"
    fi
    
    # Delete services
    if kubectl get service nodejs-order-api &>/dev/null; then
        kubectl delete service nodejs-order-api
        log "SUCCESS" "Deleted Node.js Order API service"
    else
        log "INFO" "Node.js Order API service not found"
    fi
    
    if kubectl get service nodejs-delivery-api-service &>/dev/null; then
        kubectl delete service nodejs-delivery-api-service
        log "SUCCESS" "Deleted Node.js Delivery API service"
    else
        log "INFO" "Node.js Delivery API service not found"
    fi
    
    # Delete ConfigMaps
    if kubectl get configmap nodejs-alb-config &>/dev/null; then
        kubectl delete configmap nodejs-alb-config
        log "SUCCESS" "Deleted Node.js ALB ConfigMap"
    else
        log "INFO" "Node.js ALB ConfigMap not found"
    fi
}

# Clean up generated Kubernetes manifests
cleanup_generated_manifests() {
    log "INFO" "Cleaning up generated Kubernetes manifests..."
    
    if [ -d "kubernetes/generated" ]; then
        rm -rf kubernetes/generated
        log "SUCCESS" "Deleted generated Kubernetes manifests"
    else
        log "INFO" "Generated manifests directory not found"
    fi
}

# Parse arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                log "INFO" "Usage: $0"
                log "INFO" "Removes Node.js application deployments while preserving infrastructure."
                log "INFO" ""
                log "INFO" "This script will:"
                log "INFO" "  1. Delete Node.js Kubernetes deployments and services"
                log "INFO" "  2. Delete Node.js ECR repositories"
                log "INFO" "  3. Clean up generated Kubernetes manifests"
                log "INFO" "  4. Reset SSM parameters to default values"
                log "INFO" ""
                log "INFO" "Infrastructure preserved:"
                log "INFO" "  - EKS cluster"
                log "INFO" "  - RDS instance"
                log "INFO" "  - VPC and networking"
                log "INFO" "  - IAM roles and policies"
                log "INFO" "  - CloudWatch configuration"
                log "INFO" ""
                log "INFO" "Prerequisites:"
                log "INFO" "  - Environment must be created (run 1-create-env.sh first)"
                log "INFO" "  - AWS CLI and kubectl must be configured"
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                log "INFO" "Usage: $0 [--help]"
                exit 1
                ;;
        esac
    done
}

# Main execution
main() {
    log "INFO" "Starting Node.js application cleanup (preserving infrastructure)..."
    
    parse_arguments "$@"
    load_configuration
    delete_k8s_resources
    cleanup_generated_manifests
    remove_local_images
    
    log "SUCCESS" "\n========================================="
    log "SUCCESS" "Node.js Application Cleanup Complete"
    log "SUCCESS" "========================================="
    log "INFO" "Application resources have been removed successfully"
    log "INFO" "Infrastructure resources are preserved and ready for redeployment"
    log "INFO" ""
    log "INFO" "To remove all infrastructure:"
    log "INFO" "  ./scripts/9-cleanup-env.sh --region ${AWS_REGION}"
}

# Execute main function with arguments
main "$@"