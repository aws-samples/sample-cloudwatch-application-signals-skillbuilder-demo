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

# Inject database connection pool fault
inject_fault() {
    log "INFO" "Injecting database connection pool fault..."
    
    # Set connection pool to minimal values to cause exhaustion
    log "DEBUG" "Setting pool size to 1..."
    aws ssm put-parameter \
        --name "/python-sample-app/mysql/pool-size" \
        --value "1" \
        --type "String" \
        --description "MySQL connection pool size for python-sample-app (FAULT INJECTED)" \
        --overwrite \
        --region ${AWS_REGION}
    
    log "DEBUG" "Setting max overflow to 0..."
    aws ssm put-parameter \
        --name "/python-sample-app/mysql/max-overflow" \
        --value "0" \
        --type "String" \
        --description "MySQL connection pool max overflow for python-sample-app (FAULT INJECTED)" \
        --overwrite \
        --region ${AWS_REGION}
    
    log "SUCCESS" "SSM parameters updated for fault injection:"
    log "SUCCESS" "  Pool Size: 1 (was ${CURRENT_POOL_SIZE})"
    log "SUCCESS" "  Max Overflow: 0 (was ${CURRENT_MAX_OVERFLOW})"
}

# Restart delivery API pods to pick up new configuration
restart_delivery_api() {
    log "INFO" "Restarting delivery API pods to apply fault injection..."
    
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

# Scale up traffic generator for increased load
scale_traffic_generator() {
    log "INFO" "Updating traffic generator for increased load..."
    
    # Check if traffic generator deployment exists
    if ! kubectl get deployment python-traffic-generator &>/dev/null; then
        log "WARNING" "python-traffic-generator deployment not found. Skipping traffic generator scaling."
        return 0
    fi
    
    # Update BATCH_SIZE to 100 (keep replicas at 1)
    log "DEBUG" "Updating BATCH_SIZE to 100..."
    kubectl patch deployment python-traffic-generator -p='{"spec":{"template":{"spec":{"containers":[{"name":"python-traffic-generator","env":[{"name":"BATCH_SIZE","value":"100"}]}]}}}}'
    
    log "INFO" "Waiting for traffic generator update to complete..."
    kubectl rollout status deployment/python-traffic-generator --timeout=300s
    
    log "SUCCESS" "Traffic generator updated successfully:"
    log "SUCCESS" "  Replicas: 1"
    log "SUCCESS" "  Batch Size: 100"
}

# Show fault impact information
show_fault_impact() {
    log "INFO" "\n========================================="
    log "SUCCESS" "Database Connection Pool Fault Injected!"
    log "INFO" "========================================="
    
    log "INFO" "\nFault Details:"
    log "INFO" "  Type: Database Connection Pool Exhaustion"
    log "INFO" "  Pool Size: 1 connection (reduced from ${CURRENT_POOL_SIZE})"
    log "INFO" "  Max Overflow: 0 connections (reduced from ${CURRENT_MAX_OVERFLOW})"
    log "INFO" "  Total Available Connections: 1"
    
    log "INFO" "\nTraffic Generator Configuration:"
    log "INFO" "  Replicas: 1 (unchanged)"
    log "INFO" "  Batch Size: 100 (increased from 3)"
    log "INFO" "  Total Concurrent Requests: ~100"
    
    log "INFO" "\nExpected Impact:"
    log "INFO" "  - Increased latency under concurrent load"
    log "INFO" "  - Connection timeouts when pool is exhausted"
    log "INFO" "  - Cascading failures from Delivery API to Order API"
    log "INFO" "  - Degraded performance visible in CloudWatch Application Signals"
    log "INFO" "  - Higher load amplifies the connection pool bottleneck"
    
    log "INFO" "\nTo test the fault:"
    log "INFO" "  Traffic generator is already running with increased load"
    log "INFO" "  Monitor CloudWatch Application Signals for:"
    log "INFO" "    * Increased response times"
    log "INFO" "    * Error rate increases"
    log "INFO" "    * Database connection issues"
    log "INFO" "    * Resource saturation metrics"
    
    log "INFO" "\nTo restore normal operation:"
    log "INFO" "  Run: ./scripts/7-restore-normal.sh"
    log "INFO" "  Or manually:"
    log "INFO" "    aws ssm put-parameter --name '/python-sample-app/mysql/pool-size' --value '10' --overwrite --region ${AWS_REGION}"
    log "INFO" "    aws ssm put-parameter --name '/python-sample-app/mysql/max-overflow' --value '20' --overwrite --region ${AWS_REGION}"
    log "INFO" "    kubectl rollout restart deployment/python-delivery-api"
    log "INFO" "    kubectl patch deployment python-traffic-generator -p='{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"python-traffic-generator\",\"env\":[{\"name\":\"BATCH_SIZE\",\"value\":\"3\"}]}]}}}}'"
}

# Parse arguments
parse_arguments() {
    if [ "$1" = "--help" ]; then
        log "INFO" "Usage: $0"
        log "INFO" "Injects a database connection pool fault for demonstration purposes."
        log "INFO" "\nThis script will:"
        log "INFO" "  1. Reduce MySQL connection pool size to 1"
        log "INFO" "  2. Set max overflow to 0"
        log "INFO" "  3. Restart delivery API pods"
        log "INFO" "  4. Scale traffic generator with BATCH_SIZE=100"
        log "INFO" "\nPrerequisites:"
        log "INFO" "  - Environment must be created (run 1-create-env.sh first)"
        log "INFO" "  - Application must be deployed (run 2-build-deploy-app.sh first)"
        exit 0
    fi
}

# Main execution
main() {
    log "INFO" "Starting fault injection process..."
    
    parse_arguments "$@"
    load_config
    check_prerequisites
    get_current_values
    inject_fault
    restart_delivery_api
    scale_traffic_generator
    show_fault_impact
}

# Execute main function with arguments
main "$@"