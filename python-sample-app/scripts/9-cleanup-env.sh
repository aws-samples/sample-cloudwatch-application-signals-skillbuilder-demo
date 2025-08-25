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

    RDS_INSTANCE_ID=$(jq -r '.resources.rds_instance.id' .cluster-config/cluster-resources.json)
    RDS_SECURITY_GROUP_ID=$(jq -r '.resources.rds_security_group' .cluster-config/cluster-resources.json)
    DB_SUBNET_GROUP_NAME=$(jq -r '.resources.db_subnet_group' .cluster-config/cluster-resources.json)
    PYTHON_ORDER_SERVICE_ACCOUNT_NAME=$(jq -r '.resources.python_order_service_account' .cluster-config/cluster-resources.json)
    PYTHON_DELIVERY_SERVICE_ACCOUNT_NAME=$(jq -r '.resources.python_delivery_service_account' .cluster-config/cluster-resources.json)
    PYTHON_ORDER_API_POLICY_NAME=$(jq -r '.resources.python_order_api_policy.name' .cluster-config/cluster-resources.json)
    PYTHON_DELIVERY_API_POLICY_NAME=$(jq -r '.resources.python_delivery_api_policy.name' .cluster-config/cluster-resources.json)
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
        eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_REGION}
        log "SUCCESS" "EKS cluster deletion initiated"
    else
        log "WARNING" "EKS cluster ${CLUSTER_NAME} not found"
    fi
}

# Wait for RDS instance deletion
wait_for_rds_deletion() {
    local instance_id=$1
    local max_wait=600   # 10 minutes
    local wait_time=0
    
    log "INFO" "Waiting for RDS instance ${instance_id} to be deleted..."
    
    while [ $wait_time -lt $max_wait ]; do
        if ! aws rds describe-db-instances --db-instance-identifier ${instance_id} --region ${AWS_REGION} &>/dev/null; then
            log "SUCCESS" "RDS instance ${instance_id} has been deleted"
            return 0
        fi
        
        log "INFO" "RDS instance still exists, waiting... (${wait_time}s elapsed)"
        sleep 30
        wait_time=$((wait_time + 30))
    done
    
    log "WARNING" "Timeout waiting for RDS instance deletion, proceeding anyway"
    return 1
}

# Initeate RDS instance deletion
initeate_rds_deletion() {
    log "INFO" "Deleting RDS resources..."
    
    # Delete RDS instance first
    if [ -n "$RDS_INSTANCE_ID" ] && [ "$RDS_INSTANCE_ID" != "null" ]; then
        if aws rds describe-db-instances --db-instance-identifier ${RDS_INSTANCE_ID} --region ${AWS_REGION} &>/dev/null; then
            log "INFO" "Deleting RDS instance ${RDS_INSTANCE_ID}..."
            aws rds delete-db-instance \
                --db-instance-identifier ${RDS_INSTANCE_ID} \
                --skip-final-snapshot \
                --delete-automated-backups \
                --region ${AWS_REGION}
            
            log "SUCCESS" "RDS instance deletion initiated"
            
            # Wait for RDS instance to be fully deleted before proceeding
            wait_for_rds_deletion ${RDS_INSTANCE_ID}
        else
            log "WARNING" "RDS instance ${RDS_INSTANCE_ID} not found"
        fi
    fi
    
}

# Delete IAM resources
delete_iam_resources() {
    log "INFO" "Deleting Python IAM resources..."

    # Delete Python service accounts
    for sa in "${PYTHON_ORDER_SERVICE_ACCOUNT_NAME}" "${PYTHON_DELIVERY_SERVICE_ACCOUNT_NAME}"; do
        log "INFO" "Deleting service account ${sa}..."
        eksctl delete iamserviceaccount \
            --cluster=${CLUSTER_NAME} \
            --namespace=default \
            --name=${sa} \
            --region ${AWS_REGION} || true
    done

    # Delete Python IAM policies
    for policy_name in "${PYTHON_ORDER_API_POLICY_NAME}" "${PYTHON_DELIVERY_API_POLICY_NAME}"; do
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

    log "SUCCESS" "Python IAM resources deleted"
}

# Delete SSM parameters
delete_ssm_parameters() {
    log "INFO" "Deleting SSM parameters..."
    
    # Delete MySQL pool size parameter
    if aws ssm get-parameter --name "/python-sample-app/mysql/pool-size" --region ${AWS_REGION} &>/dev/null; then
        log "DEBUG" "Deleting SSM parameter /python-sample-app/mysql/pool-size..."
        aws ssm delete-parameter \
            --name "/python-sample-app/mysql/pool-size" \
            --region ${AWS_REGION} || true
        log "SUCCESS" "SSM parameter /python-sample-app/mysql/pool-size deleted"
    else
        log "WARNING" "SSM parameter /python-sample-app/mysql/pool-size not found"
    fi
    
    # Delete MySQL max overflow parameter
    if aws ssm get-parameter --name "/python-sample-app/mysql/max-overflow" --region ${AWS_REGION} &>/dev/null; then
        log "DEBUG" "Deleting SSM parameter /python-sample-app/mysql/max-overflow..."
        aws ssm delete-parameter \
            --name "/python-sample-app/mysql/max-overflow" \
            --region ${AWS_REGION} || true
        log "SUCCESS" "SSM parameter /python-sample-app/mysql/max-overflow deleted"
    else
        log "WARNING" "SSM parameter /python-sample-app/mysql/max-overflow not found"
    fi
    
    log "SUCCESS" "SSM parameters cleanup completed"
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
    
    # Delete Python-specific ConfigMaps
    kubectl delete configmap python-otel-config --ignore-not-found || true
    kubectl delete configmap python-alb-config --ignore-not-found || true

    kubectl delete configmap python-mysql-config --ignore-not-found || true
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

# Delete RDS instance related resources
delete_rds_resources() {
    log "INFO" "Deleting RDS related resources..."
    
    # Delete DB subnet group
    if [ -n "$DB_SUBNET_GROUP_NAME" ] && [ "$DB_SUBNET_GROUP_NAME" != "null" ]; then
        if aws rds describe-db-subnet-groups --db-subnet-group-name ${DB_SUBNET_GROUP_NAME} --region ${AWS_REGION} &>/dev/null; then
            log "INFO" "Deleting DB subnet group ${DB_SUBNET_GROUP_NAME}..."
            aws rds delete-db-subnet-group --db-subnet-group-name ${DB_SUBNET_GROUP_NAME} --region ${AWS_REGION} || true
            log "SUCCESS" "DB subnet group deleted"
        else
            log "WARNING" "DB subnet group ${DB_SUBNET_GROUP_NAME} not found"
        fi
    fi
    
    # Delete RDS security group
    if [ -n "$RDS_SECURITY_GROUP_ID" ] && [ "$RDS_SECURITY_GROUP_ID" != "null" ]; then
        if aws ec2 describe-security-groups --group-ids ${RDS_SECURITY_GROUP_ID} --region ${AWS_REGION} &>/dev/null; then
            log "INFO" "Deleting RDS security group ${RDS_SECURITY_GROUP_ID}..."
            aws ec2 delete-security-group --group-id ${RDS_SECURITY_GROUP_ID} --region ${AWS_REGION} || true
            log "SUCCESS" "RDS security group deleted"
        else
            log "WARNING" "RDS security group ${RDS_SECURITY_GROUP_ID} not found"
        fi
    fi
}

# Confirm cleanup
confirm_cleanup() {
    log "WARNING" "WARNING: This will delete all Python resources created by 1-create-env.sh"
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
    log "SUCCESS" "\n======================================="
    log "SUCCESS" "Python cleanup initiated successfully!"
    log "SUCCESS" "======================================="
    log "INFO" "\nThe following resource deletions were triggered:"
    log "INFO" "  - EKS Cluster: ${CLUSTER_NAME}"

    log "INFO" "  - RDS MySQL Instance: ${RDS_INSTANCE_ID}"
    log "INFO" "  - RDS Security Group and Subnet Group"
    log "INFO" "  - SSM Parameters: /python-sample-app/mysql/*"
    log "INFO" "  - Python IAM Policies and Service Accounts"
    log "INFO" "  - CloudWatch Resources"
    log "INFO" "  - Local Configuration Files"
    log "WARNING" "\nNote: Resource deletions are running in the background."
    log "WARNING" "Check AWS Console to monitor deletion progress."
}

# Main execution
main() {
    log "INFO" "Starting Python cleanup process..."
    
    parse_arguments "$@"
    check_prerequisites
    load_configuration
    confirm_cleanup
    
    delete_cloudwatch_resources
    delete_iam_resources
    delete_ssm_parameters
    initeate_rds_deletion
    delete_eks_cluster
    delete_rds_resources
    cleanup_local_files
    
    print_cleanup_summary
}

# Execute main function with arguments
main "$@"