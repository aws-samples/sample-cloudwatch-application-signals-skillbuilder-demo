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
    DYNAMODB_TABLE_NAME=$(jq -r '.resources.dynamodb_table' .cluster-config/cluster-resources.json)
    ORDER_SERVICE_ACCOUNT_NAME=$(jq -r '.resources.order_service_account' .cluster-config/cluster-resources.json)
    DELIVERY_SERVICE_ACCOUNT_NAME=$(jq -r '.resources.delivery_service_account' .cluster-config/cluster-resources.json)
    CW_AGENT_ROLE_NAME=$(jq -r '.resources.cloudwatch_role' .cluster-config/cluster-resources.json)
    ORDER_API_POLICY_NAME=$(jq -r '.resources.order_api_policy.name' .cluster-config/cluster-resources.json)
    DELIVERY_API_POLICY_NAME=$(jq -r '.resources.delivery_api_policy.name' .cluster-config/cluster-resources.json)
}

# Check prerequisites
check_prerequisites() {
    local required_tools="aws kubectl eksctl jq"
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
}

# Delete EKS cluster
delete_eks_cluster() {
    log "INFO" "Deleting EKS cluster ${CLUSTER_NAME}..."
    
    if eksctl get cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} &>/dev/null; then
        eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --wait
        log "SUCCESS" "EKS cluster deleted"
    else
        log "WARNING" "EKS cluster ${CLUSTER_NAME} not found"
    fi
}

# Delete DynamoDB table
delete_dynamodb_table() {
    log "INFO" "Deleting DynamoDB table ${DYNAMODB_TABLE_NAME}..."
    
    if aws dynamodb describe-table --table-name ${DYNAMODB_TABLE_NAME} --region ${AWS_REGION} &>/dev/null; then
        aws dynamodb delete-table --table-name ${DYNAMODB_TABLE_NAME} --region ${AWS_REGION}
        aws dynamodb wait table-not-exists --table-name ${DYNAMODB_TABLE_NAME} --region ${AWS_REGION}
        log "SUCCESS" "DynamoDB table deleted"
    else
        log "WARNING" "DynamoDB table ${DYNAMODB_TABLE_NAME} not found"
    fi
}

# Delete IAM resources
delete_iam_resources() {
    log "INFO" "Deleting IAM resources..."

    # Delete service accounts
    for sa in "${ORDER_SERVICE_ACCOUNT_NAME}" "${DELIVERY_SERVICE_ACCOUNT_NAME}"; do
        log "INFO" "Deleting service account ${sa}..."
        eksctl delete iamserviceaccount \
            --cluster=${CLUSTER_NAME} \
            --namespace=default \
            --name=${sa} \
            --region ${AWS_REGION} || true
    done

    # Delete IAM policies
    for policy_name in "${ORDER_API_POLICY_NAME}" "${DELIVERY_API_POLICY_NAME}"; do
        log "INFO" "Deleting IAM policy ${policy_name}..."
        
        # Delete all non-default versions first
        if aws iam list-policy-versions --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" &>/dev/null; then
            versions=$(aws iam list-policy-versions \
                --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" \
                --query 'Versions[?!IsDefaultVersion].VersionId' \
                --output text)
            
            for version in $versions; do
                aws iam delete-policy-version \
                    --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" \
                    --version-id "$version" || true
            done

            # Delete the policy
            aws iam delete-policy \
                --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" || true
        fi
    done

    # Delete CloudWatch agent role
    log "INFO" "Deleting CloudWatch agent role..."
    aws iam delete-role --role-name "${CW_AGENT_ROLE_NAME}" || true
}

# Delete CloudWatch resources
delete_cloudwatch_resources() {
    log "INFO" "Removing CloudWatch resources..."

    # Delete CloudWatch addon
    if aws eks describe-addon \
        --cluster-name ${CLUSTER_NAME} \
        --addon-name amazon-cloudwatch-observability \
        --region ${AWS_REGION} &>/dev/null; then
        
        aws eks delete-addon \
            --cluster-name ${CLUSTER_NAME} \
            --addon-name amazon-cloudwatch-observability \
            --region ${AWS_REGION}
    fi

    # Delete CloudWatch namespace
    kubectl delete namespace amazon-cloudwatch --ignore-not-found || true
}

# Clean up local files
cleanup_local_files() {
    log "INFO" "Cleaning up local files..."
    
    rm -f cluster.yaml
    rm -rf .cluster-config
    rm -f kubeconfig
    
    log "SUCCESS" "Local files cleaned up"
}

# Parse arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --region)
                AWS_REGION="$2"
                shift
                shift
                ;;
            --help)
                log "INFO" "Usage: $0 [--region <aws-region>]"
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                log "INFO" "Usage: $0 [--region <aws-region>]"
                exit 1
                ;;
        esac
    done
}

# Confirm cleanup
confirm_cleanup() {
    log "WARNING" "WARNING: This will delete all resources created by 1-create-env.sh"
    log "WARNING" "This action cannot be undone!"
    log "WARNING" "Are you sure you want to continue? (y/N)"
    
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "INFO" "Cleanup cancelled"
        exit 0
    fi
}

# Print summary
print_cleanup_summary() {
    log "SUCCESS" "\n====================================="
    log "SUCCESS" "Cleanup completed successfully!"
    log "SUCCESS" "====================================="
    log "INFO" "\nThe following resources were removed:"
    log "INFO" "  - EKS Cluster: ${CLUSTER_NAME}"
    log "INFO" "  - DynamoDB Table: ${DYNAMODB_TABLE_NAME}"
    log "INFO" "  - IAM Policies and Service Accounts"
    log "INFO" "  - CloudWatch Resources"
    log "INFO" "  - Local Configuration Files"
}

# Main execution
main() {
    log "INFO" "Starting cleanup process..."
    
    parse_arguments "$@"
    check_prerequisites
    load_configuration
    confirm_cleanup
    
    delete_cloudwatch_resources
    delete_iam_resources
    delete_dynamodb_table
    delete_eks_cluster
    cleanup_local_files
    
    print_cleanup_summary
}

# Execute main function with arguments
main "$@"
