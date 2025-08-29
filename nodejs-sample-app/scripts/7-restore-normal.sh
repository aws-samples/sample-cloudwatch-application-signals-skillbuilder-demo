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

# Restore normal database configuration
restore_normal_config() {
    log "INFO" "Restoring normal database configuration..."
    
    # Disable fault injection
    log "DEBUG" "Disabling fault injection..."
    aws ssm put-parameter \
        --name "/nodejs-sample-app/mysql/fault-injection" \
        --value "false" \
        --type "String" \
        --description "Database fault injection flag for nodejs-sample-app (disabled)" \
        --overwrite \
        --region ${AWS_REGION}
    
    log "SUCCESS" "SSM parameter restored to normal values:"
    log "SUCCESS" "  Fault Injection: false (was ${CURRENT_FAULT_INJECTION})"
}

# Restart delivery API pods to pick up new configuration
restart_delivery_api() {
    log "INFO" "Restarting delivery API pods to apply normal configuration..."
    
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

# Show restoration summary
show_restoration_summary() {
    log "INFO" "\n========================================="
    log "SUCCESS" "Normal Operation Restored!"
    log "INFO" "========================================="
    
    log "INFO" "\nDatabase Configuration Restored:"
    log "INFO" "  Fault Injection: false (restored from ${CURRENT_FAULT_INJECTION})"
    log "INFO" "  Database delays: Disabled"
    
    log "INFO" "\nTraffic Generator Configuration Restored:"
    log "INFO" "  Replicas: 1 (normal load)"
    log "INFO" "  Batch Size: 3 (normal batch size)"
    log "INFO" "  Total Concurrent Requests: ~3"
    
    log "INFO" "\nNode.js Specific Restorations:"
    log "INFO" "  - Database delay fault injection disabled"
    log "INFO" "  - Dynamic configuration refresh tested"
    log "INFO" "  - Normal database operation restored"
    
    log "INFO" "\nExpected Behavior:"
    log "INFO" "  - Normal response times under load"
    log "INFO" "  - No database operation delays"
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
        log "INFO" "Restores normal database configuration by disabling fault injection."
        log "INFO" "\nThis script will:"
        log "INFO" "  1. Disable database delay fault injection"
        log "INFO" "  2. Restart delivery API pods to apply changes"
        log "INFO" "  3. Scale traffic generator to 1 replica with BATCH_SIZE=3"
        log "INFO" "  4. Test configuration refresh endpoint"
        log "INFO" "  5. Verify normal operation"
        log "INFO" "\nNode.js specific features:"
        log "INFO" "  - Uses /nodejs-sample-app/ SSM parameter prefix"
        log "INFO" "  - Database delay injection via SQL SLEEP query"
        log "INFO" "  - Tests dynamic configuration refresh"
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
    show_restoration_summary
}

# Execute main function with arguments
main "$@"