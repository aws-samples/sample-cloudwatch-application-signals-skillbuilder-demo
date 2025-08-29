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

# Generate common tags
get_common_tags() {
    echo "Key=Environment,Value=Dev Key=Project,Value=JavaAppSignals Key=ClusterName,Value=${CLUSTER_NAME}"
}

# Generate unique ID
generate_unique_id() {
    echo "id-$(date +%s)-${RANDOM}"
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

    if ! aws sts get-caller-identity &>/dev/null; then
        log "ERROR" "AWS CLI is not configured"
        exit 1
    fi

    log "SUCCESS" "Prerequisites check passed"
}

# Get AWS account details
get_aws_details() {
    if [ -z "$AWS_REGION" ]; then
        log "ERROR" "AWS region must be specified using --region parameter"
        exit 1
    fi

    # Verify AWS CLI configuration
    if ! aws sts get-caller-identity &>/dev/null; then
        log "ERROR" "AWS CLI is not configured or credentials are invalid"
        exit 1
    fi

    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    log "INFO" "AWS Account ID: ${AWS_ACCOUNT_ID}"
}

# Setup resource names
setup_resource_names() {
    ID=$(generate_unique_id)
    log "INFO" "Generated ID: $ID"
    
    DYNAMODB_TABLE_NAME="orders-catalog"
    ORDER_API_POLICY_NAME="${ID}-order-policy"
    ORDER_SERVICE_ACCOUNT_NAME="${ID}-order-sa"
    DELIVERY_SERVICE_ACCOUNT_NAME="${ID}-delivery-sa"
    SERVICE_ACCOUNT_NAME="${ID}-sa"
    
    log "DEBUG" "Resource names configured successfully"
}

# Get cluster name from user
get_cluster_name() {
    local DEFAULT_CLUSTER_NAME="eks-${ID}"
    
    read -p "Enter cluster name [$DEFAULT_CLUSTER_NAME]: " CLUSTER_NAME
    CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}
    
    if ! [[ $CLUSTER_NAME =~ ^[a-zA-Z][a-zA-Z0-9-]*[a-zA-Z0-9]$ && ${#CLUSTER_NAME} -le 100 ]]; then
        log "ERROR" "Invalid cluster name format"
        exit 1
    fi
    
    log "INFO" "Using cluster name: $CLUSTER_NAME"
}

# Create EKS cluster
create_eks_cluster() {
    if aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} &>/dev/null; then
        log "WARNING" "Cluster ${CLUSTER_NAME} already exists"
        return 0
    fi
    
    log "INFO" "Creating EKS cluster ${CLUSTER_NAME}..."
    
    cat > cluster.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "1.33"
  tags: &tags
    Environment: Dev
    Project: JavaAppSignals
    ClusterName: ${CLUSTER_NAME}

iam:
  withOIDC: true
  
# Enable RBAC access control
accessConfig:
  bootstrapClusterCreatorAdminPermissions: true

managedNodeGroups:
  - name: ng-1
    instanceType: t3.large
    desiredCapacity: 2
    minSize: 1
    maxSize: 3
    tags: *tags
    iam:
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
addons:
  - name: vpc-cni
    version: latest
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
EOF

    eksctl create cluster -f cluster.yaml
    aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}
    log "SUCCESS" "EKS cluster created successfully"
}

# Create DynamoDB table
create_dynamodb_table() {
    if aws dynamodb describe-table --table-name ${DYNAMODB_TABLE_NAME} --region ${AWS_REGION} &>/dev/null; then
        log "WARNING" "DynamoDB table ${DYNAMODB_TABLE_NAME} already exists"
        return 0
    fi

    log "INFO" "Creating DynamoDB table ${DYNAMODB_TABLE_NAME}..."
    local common_tags=$(get_common_tags)

    aws dynamodb create-table \
        --table-name ${DYNAMODB_TABLE_NAME} \
        --attribute-definitions AttributeName=Id,AttributeType=S \
        --key-schema AttributeName=Id,KeyType=HASH \
        --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1 \
        --tags $common_tags \
        --region ${AWS_REGION}

    aws dynamodb wait table-exists --table-name ${DYNAMODB_TABLE_NAME} --region ${AWS_REGION}
    log "SUCCESS" "DynamoDB table created successfully"
}

# Create IAM policies and service accounts
create_iam_resources() {
    log "INFO" "Creating IAM resources..."
    local common_tags=$(get_common_tags)

    # Create Order API DynamoDB policy
    log "DEBUG" "Creating Order API policy document..."
    cat > order-api-dynamodb-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:PutItem",
                "dynamodb:GetItem",
                "dynamodb:UpdateItem",
                "dynamodb:DeleteItem",
                "dynamodb:Scan",
                "dynamodb:Query",
                "dynamodb:DescribeTable"
            ],
            "Resource": "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/${DYNAMODB_TABLE_NAME}"
        }
    ]
}
EOF

    # Create Delivery API policy
    log "DEBUG" "Creating Delivery API policy document..."
    cat > delivery-api-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:PutItem",
                "dynamodb:GetItem",
                "dynamodb:DescribeTable",
                "dynamodb:UpdateItem",
                "dynamodb:DeleteItem",
                "dynamodb:Scan",
                "dynamodb:Query"
            ],
            "Resource": "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/${DYNAMODB_TABLE_NAME}"
        }
    ]
}
EOF

    # Create or update Order API policy
    if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${ORDER_API_POLICY_NAME}" 2>/dev/null; then
        log "INFO" "Updating existing policy ${ORDER_API_POLICY_NAME}"
        POLICY_VERSION=$(aws iam create-policy-version \
            --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${ORDER_API_POLICY_NAME}" \
            --policy-document file://order-api-dynamodb-policy.json \
            --set-as-default \
            --query 'PolicyVersion.VersionId' \
            --output text)
        ORDER_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${ORDER_API_POLICY_NAME}"
    else
        log "INFO" "Creating new policy ${ORDER_API_POLICY_NAME}"
        ORDER_POLICY_ARN=$(aws iam create-policy \
            --policy-name "${ORDER_API_POLICY_NAME}" \
            --policy-document file://order-api-dynamodb-policy.json \
            --tags $common_tags \
            --query 'Policy.Arn' \
            --output text)
    fi

    # Create or update Delivery API policy
    DELIVERY_API_POLICY_NAME="${ID}-delivery-policy"
    if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${DELIVERY_API_POLICY_NAME}" 2>/dev/null; then
        log "INFO" "Updating existing policy ${DELIVERY_API_POLICY_NAME}"
        POLICY_VERSION=$(aws iam create-policy-version \
            --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${DELIVERY_API_POLICY_NAME}" \
            --policy-document file://delivery-api-policy.json \
            --set-as-default \
            --query 'PolicyVersion.VersionId' \
            --output text)
        DELIVERY_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${DELIVERY_API_POLICY_NAME}"
    else
        log "INFO" "Creating new policy ${DELIVERY_API_POLICY_NAME}"
        DELIVERY_POLICY_ARN=$(aws iam create-policy \
            --policy-name "${DELIVERY_API_POLICY_NAME}" \
            --policy-document file://delivery-api-policy.json \
            --tags $common_tags \
            --query 'Policy.Arn' \
            --output text)
    fi

    log "SUCCESS" "Order API Policy ARN: $ORDER_POLICY_ARN"
    log "SUCCESS" "Delivery API Policy ARN: $DELIVERY_POLICY_ARN"

    # Create service accounts
    log "INFO" "Creating service accounts..."
    
    # Order API service account
    log "INFO" "Creating service account ${ORDER_SERVICE_ACCOUNT_NAME}"
    kubectl delete serviceaccount ${ORDER_SERVICE_ACCOUNT_NAME} --ignore-not-found --namespace default
    
    eksctl create iamserviceaccount \
        --cluster=${CLUSTER_NAME} \
        --namespace=default \
        --name=${ORDER_SERVICE_ACCOUNT_NAME} \
        --attach-policy-arn=${ORDER_POLICY_ARN} \
        --override-existing-serviceaccounts \
        --approve \
        --region ${AWS_REGION}

    # Verify Order API service account
    if ! kubectl get serviceaccount ${ORDER_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        log "ERROR" "Order API service account creation failed"
        exit 1
    fi
    log "SUCCESS" "Order API service account created successfully"

    # Delivery API service account
    log "INFO" "Creating service account ${DELIVERY_SERVICE_ACCOUNT_NAME}"
    kubectl delete serviceaccount ${DELIVERY_SERVICE_ACCOUNT_NAME} --ignore-not-found --namespace default
    
    eksctl create iamserviceaccount \
        --cluster=${CLUSTER_NAME} \
        --namespace=default \
        --name=${DELIVERY_SERVICE_ACCOUNT_NAME} \
        --attach-policy-arn=${DELIVERY_POLICY_ARN} \
        --override-existing-serviceaccounts \
        --approve \
        --region ${AWS_REGION}

    # Verify Delivery API service account
    if ! kubectl get serviceaccount ${DELIVERY_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        log "ERROR" "Delivery API service account creation failed"
        exit 1
    fi
    log "SUCCESS" "Delivery API service account created successfully"

    rm -f order-api-dynamodb-policy.json delivery-api-policy.json
    log "DEBUG" "Cleaned up policy JSON files"
}

# Save configuration
save_config() {
    log "INFO" "Saving configuration..."
    mkdir -p .cluster-config
    
    cat > .cluster-config/cluster-resources.json <<EOF
{
    "id": "${ID}",
    "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "cluster": {
        "name": "${CLUSTER_NAME}",
        "region": "${AWS_REGION}",
        "account_id": "${AWS_ACCOUNT_ID}"
    },
    "resources": {
        "dynamodb_table": "${DYNAMODB_TABLE_NAME}",
        "service_account": "${SERVICE_ACCOUNT_NAME}",
        "order_service_account": "${ORDER_SERVICE_ACCOUNT_NAME}",
        "delivery_service_account": "${DELIVERY_SERVICE_ACCOUNT_NAME}",
        "iam_policy": {
            "name": "${ORDER_API_POLICY_NAME}",
            "arn": "${ORDER_POLICY_ARN}"
        }
    },
    "tags": {
        "Environment": "Dev",
        "Project": "JavaAppSignals",
        "ClusterName": "${CLUSTER_NAME}"
    }
}
EOF

    if ! jq '.' .cluster-config/cluster-resources.json >/dev/null 2>&1; then
        log "ERROR" "Invalid JSON configuration"
        exit 1
    fi

    log "SUCCESS" "Configuration saved successfully"
}

# Verify setup
verify_setup() {
    log "INFO" "Verifying setup..."
    
    # Check nodes
    if ! kubectl get nodes &>/dev/null; then
        log "ERROR" "Failed to get cluster nodes"
        exit 1
    fi
    log "SUCCESS" "Cluster nodes verified"

    # Check service accounts
    if ! kubectl get serviceaccount ${ORDER_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        log "ERROR" "Order service account verification failed"
        exit 1
    fi
    log "SUCCESS" "Order service account verified"

    if ! kubectl get serviceaccount ${DELIVERY_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        log "ERROR" "Delivery service account verification failed"
        exit 1
    fi
    log "SUCCESS" "Delivery service account verified"

    # Check DynamoDB
    if ! aws dynamodb describe-table \
        --table-name ${DYNAMODB_TABLE_NAME} \
        --region ${AWS_REGION} \
        --query 'Table.TableStatus' \
        --output text &>/dev/null; then
        log "ERROR" "DynamoDB table verification failed"
        exit 1
    fi
    log "SUCCESS" "All components verified successfully"
}

# Parse arguments
parse_arguments() {
    if [ "$1" = "--help" ]; then
        log "INFO" "Usage: $0 --region <aws-region>"
        log "INFO" "Example: $0 --region us-east-1"
        log "INFO" "\nAvailable regions:"
        aws ec2 describe-regions --query 'Regions[].RegionName' --output table
        exit 0
    fi

    if [ "$1" != "--region" ] || [ -z "$2" ]; then
        log "ERROR" "Region parameter is required"
        log "INFO" "Usage: $0 --region <aws-region>"
        log "INFO" "Run '$0 --help' to see available regions"
        exit 1
    fi

    AWS_REGION="$2"

    # Validate if the provided region exists
    if ! aws ec2 describe-regions --query "Regions[?RegionName=='${AWS_REGION}'].RegionName" --output text | grep -q "${AWS_REGION}"; then
        log "ERROR" "Invalid AWS region: ${AWS_REGION}"
        log "INFO" "Run '$0 --help' to see available regions"
        exit 1
    fi

    log "INFO" "Using AWS Region: ${AWS_REGION}"
}

# Print summary 
print_summary() {
    log "SUCCESS" "\n========================================="
    log "SUCCESS" "Environment setup completed successfully!"
    log "SUCCESS" "========================================="
    
    log "INFO" "\nCluster Details:"
    log "INFO" "  Name: ${CLUSTER_NAME}"
    log "INFO" "  Region: ${AWS_REGION}"
    log "INFO" "  Resource ID: ${ID}"
    
    log "INFO" "\nResources Created:"
    log "INFO" "  - EKS Cluster"
    log "INFO" "  - DynamoDB Table: ${DYNAMODB_TABLE_NAME}"
    log "INFO" "  - IAM Policy: ${ORDER_API_POLICY_NAME}"
    log "INFO" "  - Order Service Account: ${ORDER_SERVICE_ACCOUNT_NAME}"
    log "INFO" "  - Delivery Service Account: ${DELIVERY_SERVICE_ACCOUNT_NAME}"
    
    log "INFO" "\nConfiguration saved to:"
    log "INFO" "  .cluster-config/cluster-resources.json"

}

# Main execution
main() {
    log "INFO" "Starting environment setup..."
    
    parse_arguments "$@"  
    get_aws_details     
    check_prerequisites
    setup_resource_names
    get_cluster_name
    
    log "INFO" "\nCreating resources..."
    create_eks_cluster
    create_dynamodb_table
    create_iam_resources
    
    log "INFO" "\nFinalizing setup..."
    verify_setup
    save_config
    print_summary
}

# Execute main function with arguments
main "$@"
