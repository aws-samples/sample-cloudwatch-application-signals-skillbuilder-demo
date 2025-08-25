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
load_config() {
    if [ ! -f ".cluster-config/cluster-resources.json" ]; then
        log "ERROR" "Configuration file not found. Please run 1-create-env.sh first."
        exit 1
    fi

    AWS_REGION=$(jq -r '.cluster.region' .cluster-config/cluster-resources.json)
    CLUSTER_NAME=$(jq -r '.cluster.name' .cluster-config/cluster-resources.json)
    
    if [ "$AWS_REGION" = "null" ] || [ "$CLUSTER_NAME" = "null" ]; then
        log "ERROR" "Invalid configuration file"
        exit 1
    fi

    log "INFO" "Loaded configuration:"
    log "INFO" "  Cluster: ${CLUSTER_NAME}"
    log "INFO" "  Region: ${AWS_REGION}"
}

# Check prerequisites
check_prerequisites() {
    local required_tools="aws kubectl jq"
    local missing_tools=()

    for tool in $required_tools; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log "ERROR" "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi

    if ! aws sts get-caller-identity &>/dev/null; then
        log "ERROR" "AWS CLI is not configured"
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log "ERROR" "kubectl is not configured or cluster is not accessible"
        exit 1
    fi

    log "SUCCESS" "Prerequisites check passed"
}

# Get current SSM parameter values
get_current_values() {
    log "INFO" "Getting current SSM parameter values..."
    
    CURRENT_POOL_SIZE=$(aws ssm get-parameter --name "/python-sample-app/mysql/pool-size" --region ${AWS_REGION} --query 'Parameter.Value' --output text 2>/dev/null || echo "not found")
    CURRENT_MAX_OVERFLOW=$(aws ssm get-parameter --name "/python-sample-app/mysql/max-overflow" --region ${AWS_REGION} --query 'Parameter.Value' --output text 2>/dev/null || echo "not found")
    
    log "INFO" "Current values:"
    log "INFO" "  Pool Size: ${CURRENT_POOL_SIZE}"
    log "INFO" "  Max Overflow: ${CURRENT_MAX_OVERFLOW}"
}

# Restore normal database connection pool configuration
restore_normal_config() {
    log "INFO" "Restoring normal database connection pool configuration..."
    
    # Set connection pool back to healthy defaults
    log "DEBUG" "Setting pool size to 10..."
    aws ssm put-parameter \
        --name "/python-sample-app/mysql/pool-size" \
        --value "10" \
        --type "String" \
        --description "MySQL connection pool size for python-sample-app" \
        --overwrite \
        --region ${AWS_REGION}
    
    log "DEBUG" "Setting max overflow to 20..."
    aws ssm put-parameter \
        --name "/python-sample-app/mysql/max-overflow" \
        --value "20" \
        --type "String" \
        --description "MySQL connection pool max overflow for python-sample-app" \
        --overwrite \
        --region ${AWS_REGION}
    
    log "SUCCESS" "SSM parameters restored to normal values:"
    log "SUCCESS" "  Pool Size: 10 (was ${CURRENT_POOL_SIZE})"
    log "SUCCESS" "  Max Overflow: 20 (was ${CURRENT_MAX_OVERFLOW})"
}

# Restart delivery API pods to pick up new configuration
restart_delivery_api() {
    log "INFO" "Restarting delivery API pods to apply normal configuration..."
    
    # Check if deployment exists
    if ! kubectl get deployment python-delivery-api &>/dev/null; then
        log "ERROR" "python-delivery-api deployment not found. Please deploy the application first."
        exit 1
    fi
    
    # Restart the deployment
    kubectl rollout restart deployment/python-delivery-api
    
    log "INFO" "Waiting for deployment to complete..."
    kubectl rollout status deployment/python-delivery-api --timeout=300s
    
    log "SUCCESS" "Delivery API pods restarted successfully"
}

# Restore traffic generator to normal configuration
restore_traffic_generator() {
    log "INFO" "Restoring traffic generator to normal configuration..."
    
    # Check if traffic generator deployment exists
    if ! kubectl get deployment python-traffic-generator &>/dev/null; then
        log "WARNING" "python-traffic-generator deployment not found. Skipping traffic generator restoration."
        return 0
    fi
    
    # Update BATCH_SIZE back to 3 (replicas already at 1)
    log "DEBUG" "Updating BATCH_SIZE to 3..."
    kubectl patch deployment python-traffic-generator -p='{"spec":{"template":{"spec":{"containers":[{"name":"python-traffic-generator","env":[{"name":"BATCH_SIZE","value":"3"}]}]}}}}'
    
    log "INFO" "Waiting for traffic generator restoration to complete..."
    kubectl rollout status deployment/python-traffic-generator --timeout=300s
    
    log "SUCCESS" "Traffic generator restored successfully:"
    log "SUCCESS" "  Replicas: 1"
    log "SUCCESS" "  Batch Size: 3"
}

# Show restoration summary
show_restoration_summary() {
    log "INFO" "\n========================================="
    log "SUCCESS" "Normal Operation Restored!"
    log "INFO" "========================================="
    
    log "INFO" "\nDatabase Configuration Restored:"
    log "INFO" "  Pool Size: 10 connections (restored from ${CURRENT_POOL_SIZE})"
    log "INFO" "  Max Overflow: 20 connections (restored from ${CURRENT_MAX_OVERFLOW})"
    log "INFO" "  Total Available Connections: 30"
    
    log "INFO" "\nTraffic Generator Configuration Restored:"
    log "INFO" "  Replicas: 1 (normal load)"
    log "INFO" "  Batch Size: 3 (normal batch size)"
    log "INFO" "  Total Concurrent Requests: ~3"
    
    log "INFO" "\nExpected Behavior:"
    log "INFO" "  - Normal response times under load"
    log "INFO" "  - No connection pool exhaustion"
    log "INFO" "  - Healthy performance metrics in CloudWatch Application Signals"
    log "INFO" "  - Baseline traffic load for normal operations"
    
    log "INFO" "\nTo inject faults again:"
    log "INFO" "  Run: ./scripts/6-introduce-fault.sh"
    
    log "INFO" "\nTo generate load and test:"
    log "INFO" "  Run: ./scripts/5-generate-load.sh"
}

# Parse arguments
parse_arguments() {
    if [ "$1" = "--help" ]; then
        log "INFO" "Usage: $0"
        log "INFO" "Restores normal database connection pool and traffic generator configuration."
        log "INFO" "\nThis script will:"
        log "INFO" "  1. Set MySQL connection pool size to 10"
        log "INFO" "  2. Set max overflow to 20"
        log "INFO" "  3. Restart delivery API pods"
        log "INFO" "  4. Scale traffic generator to 1 replica with BATCH_SIZE=3"
        log "INFO" "  5. Verify normal operation"
        log "INFO" "\nPrerequisites:"
        log "INFO" "  - Environment must be created (run 1-create-env.sh first)"
        log "INFO" "  - Application must be deployed (run 2-build-deploy-app.sh first)"
        exit 0
    fi
}

# Main execution
main() {
    log "INFO" "Starting normal operation restoration..."
    
    parse_arguments "$@"
    load_config
    check_prerequisites
    get_current_values
    restore_normal_config
    restart_delivery_api
    restore_traffic_generator
    show_restoration_summary
}

# Execute main function with arguments
main "$@"