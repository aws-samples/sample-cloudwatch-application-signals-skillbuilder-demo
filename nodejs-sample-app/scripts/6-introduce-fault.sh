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
    
    CURRENT_FAULT_INJECTION=$(aws ssm get-parameter --name "/nodejs-sample-app/mysql/fault-injection" --region ${AWS_REGION} --query 'Parameter.Value' --output text 2>/dev/null || echo "not found")
    
    log "INFO" "Current values:"
    log "INFO" "  Fault Injection: ${CURRENT_FAULT_INJECTION}"
}

# Inject database delay fault
inject_fault() {
    log "INFO" "Injecting database delay fault..."
    
    # Enable fault injection to introduce 10-second database delays
    log "DEBUG" "Enabling fault injection..."
    aws ssm put-parameter \
        --name "/nodejs-sample-app/mysql/fault-injection" \
        --value "true" \
        --type "String" \
        --description "Database fault injection flag for nodejs-sample-app (10s delay per query)" \
        --overwrite \
        --region ${AWS_REGION}
    
    log "SUCCESS" "SSM parameter updated for fault injection:"
    log "SUCCESS" "  Fault Injection: true (was ${CURRENT_FAULT_INJECTION})"
}

# Restart delivery API pods to pick up new configuration
restart_delivery_api() {
    log "INFO" "Restarting delivery API pods to apply fault injection..."
    
    # Check if deployment exists
    if ! kubectl get deployment nodejs-delivery-api &>/dev/null; then
        log "ERROR" "nodejs-delivery-api deployment not found. Please deploy the application first."
        exit 1
    fi
    
    # Restart the deployment
    kubectl rollout restart deployment/nodejs-delivery-api
    
    log "INFO" "Waiting for deployment to complete..."
    kubectl rollout status deployment/nodejs-delivery-api --timeout=300s
    
    log "SUCCESS" "Delivery API pods restarted successfully"
}

# Show fault impact information
show_fault_impact() {
    log "INFO" "\n========================================="
    log "SUCCESS" "Database Delay Fault Injected!"
    log "INFO" "========================================="
    
    log "INFO" "\nFault Details:"
    log "INFO" "  Type: Database Query Delay"
    log "INFO" "  Delay: 10 seconds per database operation"
    log "INFO" "  Target: storeOrder method in delivery-api"
    log "INFO" "  Previous State: ${CURRENT_FAULT_INJECTION}"
    
    log "INFO" "\nTo restore normal operation:"
    log "INFO" "  Run: ./scripts/7-restore-normal.sh"
    log "INFO" "  Or manually:"
    log "INFO" "    aws ssm put-parameter --name '/nodejs-sample-app/mysql/fault-injection' --value 'false' --overwrite --region ${AWS_REGION}"
    log "INFO" "    kubectl rollout restart deployment/nodejs-delivery-api"
    log "INFO" "    kubectl patch deployment nodejs-traffic-generator -p='{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"nodejs-traffic-generator\",\"env\":[{\"name\":\"BATCH_SIZE\",\"value\":\"3\"}]}]}}}}'"
}

# Parse arguments
parse_arguments() {
    if [ "$1" = "--help" ]; then
        log "INFO" "Usage: $0"
        log "INFO" "Injects a database delay fault for demonstration purposes."
        log "INFO" "\nThis script will:"
        log "INFO" "  1. Enable database delay fault injection (10s per query)"
        log "INFO" "  2. Restart delivery API pods to apply changes"
        log "INFO" "  3. Scale traffic generator with BATCH_SIZE=100"
        log "INFO" "  4. Test configuration refresh endpoint"
        log "INFO" "\nNode.js specific features:"
        log "INFO" "  - Uses /nodejs-sample-app/ SSM parameter prefix"
        log "INFO" "  - Supports dynamic configuration refresh"
        log "INFO" "  - Database delay injection via SQL SLEEP query"
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
    show_fault_impact
}

# Execute main function with arguments
main "$@"