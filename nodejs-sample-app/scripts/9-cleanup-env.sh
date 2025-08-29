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
    NODEJS_ORDER_SERVICE_ACCOUNT_NAME=$(jq -r '.resources.nodejs_order_service_account' .cluster-config/cluster-resources.json)
    NODEJS_DELIVERY_SERVICE_ACCOUNT_NAME=$(jq -r '.resources.nodejs_delivery_service_account' .cluster-config/cluster-resources.json)
    NODEJS_ORDER_API_POLICY_NAME=$(jq -r '.resources.nodejs_order_api_policy.name' .cluster-config/cluster-resources.json)
    NODEJS_DELIVERY_API_POLICY_NAME=$(jq -r '.resources.nodejs_delivery_api_policy.name' .cluster-config/cluster-resources.json)
    REUSED_EXISTING_RESOURCES=$(jq -r '.resources.reused_existing_resources' .cluster-config/cluster-resources.json)
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

# Delete ECR repositories
delete_ecr_repositories() {
    log "INFO" "Deleting ECR repositories..."
    
    for repo in "nodejs-order-api" "nodejs-delivery-api" "nodejs-traffic-generator"; do
        if aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" &>/dev/null; then
            aws ecr delete-repository --repository-name "$repo" --force --region "$AWS_REGION"
            log "SUCCESS" "Deleted ECR repository: $repo"
        else
            log "INFO" "ECR repository $repo not found"
        fi
    done
}

# Delete IAM resources
delete_iam_resources() {
    log "INFO" "Deleting IAM resources..."
    
    # Delete service accounts
    if kubectl get serviceaccount ${NODEJS_ORDER_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        eksctl delete iamserviceaccount \
            --cluster=${CLUSTER_NAME} \
            --namespace=default \
            --name=${NODEJS_ORDER_SERVICE_ACCOUNT_NAME} \
            --region ${AWS_REGION}
        log "SUCCESS" "Deleted Node.js Order service account"
    fi
    
    if kubectl get serviceaccount ${NODEJS_DELIVERY_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        eksctl delete iamserviceaccount \
            --cluster=${CLUSTER_NAME} \
            --namespace=default \
            --name=${NODEJS_DELIVERY_SERVICE_ACCOUNT_NAME} \
            --region ${AWS_REGION}
        log "SUCCESS" "Deleted Node.js Delivery service account"
    fi
    
    # Delete IAM policies
    if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${NODEJS_ORDER_API_POLICY_NAME}" &>/dev/null; then
        aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${NODEJS_ORDER_API_POLICY_NAME}"
        log "SUCCESS" "Deleted Node.js Order API policy"
    fi
    
    if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${NODEJS_DELIVERY_API_POLICY_NAME}" &>/dev/null; then
        aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${NODEJS_DELIVERY_API_POLICY_NAME}"
        log "SUCCESS" "Deleted Node.js Delivery API policy"
    fi
}

# Delete SSM parameters
delete_ssm_parameters() {
    log "INFO" "Deleting SSM parameters..."
    
    for param in "/nodejs-sample-app/mysql/pool-size" "/nodejs-sample-app/mysql/max-overflow" "/nodejs-sample-app/mysql/fault-injection"; do
        if aws ssm get-parameter --name "$param" --region ${AWS_REGION} &>/dev/null; then
            aws ssm delete-parameter --name "$param" --region ${AWS_REGION}
            log "SUCCESS" "Deleted SSM parameter: $param"
        else
            log "INFO" "SSM parameter $param not found"
        fi
    done
}

# Delete RDS instance (only if not reused)
delete_rds_instance() {
    if [ "$REUSED_EXISTING_RESOURCES" = "true" ]; then
        log "INFO" "Skipping RDS deletion - resources were reused from existing setup"
        return 0
    fi
    
    log "INFO" "Deleting RDS instance ${RDS_INSTANCE_ID}..."
    
    if aws rds describe-db-instances --db-instance-identifier ${RDS_INSTANCE_ID} --region ${AWS_REGION} &>/dev/null; then
        aws rds delete-db-instance \
            --db-instance-identifier ${RDS_INSTANCE_ID} \
            --skip-final-snapshot \
            --region ${AWS_REGION}
        log "SUCCESS" "RDS instance deletion initiated"
        
        # Wait for deletion
        log "INFO" "Waiting for RDS instance to be deleted..."
        aws rds wait db-instance-deleted --db-instance-identifier ${RDS_INSTANCE_ID} --region ${AWS_REGION}
        log "SUCCESS" "RDS instance deleted"
    else
        log "WARNING" "RDS instance ${RDS_INSTANCE_ID} not found"
    fi
    
    # Delete DB subnet group
    if aws rds describe-db-subnet-groups --db-subnet-group-name ${DB_SUBNET_GROUP_NAME} --region ${AWS_REGION} &>/dev/null; then
        aws rds delete-db-subnet-group --db-subnet-group-name ${DB_SUBNET_GROUP_NAME} --region ${AWS_REGION}
        log "SUCCESS" "Deleted DB subnet group"
    fi
    
    # Delete RDS security group
    if [ -n "$RDS_SECURITY_GROUP_ID" ] && [ "$RDS_SECURITY_GROUP_ID" != "null" ]; then
        if aws ec2 describe-security-groups --group-ids ${RDS_SECURITY_GROUP_ID} --region ${AWS_REGION} &>/dev/null; then
            aws ec2 delete-security-group --group-id ${RDS_SECURITY_GROUP_ID} --region ${AWS_REGION}
            log "SUCCESS" "Deleted RDS security group"
        fi
    fi
}

# Delete EKS cluster (only if not reused)
delete_eks_cluster() {
    if [ "$REUSED_EXISTING_RESOURCES" = "true" ]; then
        log "INFO" "Skipping EKS cluster deletion - cluster was reused from existing setup"
        return 0
    fi
    
    log "INFO" "Deleting EKS cluster ${CLUSTER_NAME}..."
    
    if eksctl get cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} &>/dev/null; then
        eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_REGION}
        log "SUCCESS" "EKS cluster deletion initiated"
    else
        log "WARNING" "EKS cluster ${CLUSTER_NAME} not found"
    fi
}

# Clean up local files
cleanup_local_files() {
    log "INFO" "Cleaning up local files..."
    
    rm -f cluster.yaml
    rm -rf .cluster-config
    rm -f kubeconfig
    
    log "SUCCESS" "Local files cleaned up"
}


# Confirmation prompt
confirm_deletion() {
    log "WARNING" "This will delete the following Node.js resources:"
    log "WARNING" "- Node.js Kubernetes deployments and services"
    log "WARNING" "- Node.js ECR repositories"
    log "WARNING" "- Node.js IAM policies and service accounts"
    log "WARNING" "- Node.js SSM parameters"
    
    if [ "$REUSED_EXISTING_RESOURCES" != "true" ]; then
        log "WARNING" "- EKS cluster: ${CLUSTER_NAME}"
        log "WARNING" "- RDS instance: ${RDS_INSTANCE_ID}"
        log "WARNING" "- Associated networking resources"
    else
        log "INFO" "EKS cluster and RDS instance will be preserved (were reused from existing setup)"
    fi
    
    echo ""
    read -p "Are you sure you want to proceed? (yes/no): " confirmation
    
    if [[ $confirmation != "yes" ]]; then
        log "INFO" "Cleanup cancelled"
        exit 0
    fi
}

# Main execution
main() {
    log "INFO" "Starting Node.js environment cleanup..."
    
    check_prerequisites
    load_configuration
    confirm_deletion
    
    delete_ecr_repositories
    delete_iam_resources
    delete_ssm_parameters
    delete_rds_instance
    delete_eks_cluster
    cleanup_local_files
    
    log "SUCCESS" "\n========================================="
    log "SUCCESS" "Node.js Environment Cleanup Complete"
    log "SUCCESS" "========================================="
    log "INFO" "All Node.js resources have been cleaned up successfully"
    
    if [ "$REUSED_EXISTING_RESOURCES" = "true" ]; then
        log "INFO" "Note: Shared infrastructure (EKS cluster and RDS) was preserved"
    fi
}

# Execute main function
main "$@"