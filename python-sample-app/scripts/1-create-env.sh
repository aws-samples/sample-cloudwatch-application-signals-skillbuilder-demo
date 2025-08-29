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
    echo "Environment=Dev,Project=PythonAppSignals,ClusterName=${CLUSTER_NAME}"
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
    
    # RDS resource names
    RDS_INSTANCE_ID="${ID}-orders-mysql"
    RDS_DB_NAME="orders_db"
    RDS_USERNAME="admin"
    RDS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    
    # IAM resource names
    PYTHON_ORDER_API_POLICY_NAME="${ID}-python-order-policy"
    PYTHON_DELIVERY_API_POLICY_NAME="${ID}-python-delivery-policy"
    PYTHON_ORDER_SERVICE_ACCOUNT_NAME="${ID}-python-order-sa"
    PYTHON_DELIVERY_SERVICE_ACCOUNT_NAME="${ID}-python-delivery-sa"
    SERVICE_ACCOUNT_NAME="${ID}-python-sa"
    
    log "DEBUG" "Resource names configured successfully"
}

# Get cluster name from user
get_cluster_name() {
    local DEFAULT_CLUSTER_NAME="python-eks-${ID}"
    
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
    Project: PythonAppSignals
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



# Create RDS MySQL instance
create_rds_instance() {
    log "INFO" "Creating RDS MySQL instance..."
    local common_tags=$(get_common_tags)

    # Check if RDS instance already exists
    if aws rds describe-db-instances --db-instance-identifier ${RDS_INSTANCE_ID} --region ${AWS_REGION} &>/dev/null; then
        log "WARNING" "RDS instance ${RDS_INSTANCE_ID} already exists"
        RDS_ENDPOINT=$(aws rds describe-db-instances \
            --db-instance-identifier ${RDS_INSTANCE_ID} \
            --region ${AWS_REGION} \
            --query 'DBInstances[0].Endpoint.Address' --output text)
        return 0
    fi

    # Get VPC ID from EKS cluster
    VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.vpcId' --output text)
    if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ] || [ "$VPC_ID" = "null" ]; then
        log "ERROR" "Failed to get VPC ID from EKS cluster ${CLUSTER_NAME}"
        exit 1
    fi
    log "DEBUG" "VPC ID: ${VPC_ID}"
    
    # Get subnets from EKS cluster
    SUBNET_IDS=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.subnetIds' --output text)
    if [ -z "$SUBNET_IDS" ] || [ "$SUBNET_IDS" = "None" ] || [ "$SUBNET_IDS" = "null" ]; then
        log "ERROR" "Failed to get subnet IDs from EKS cluster ${CLUSTER_NAME}"
        exit 1
    fi
    log "DEBUG" "Subnet IDs: ${SUBNET_IDS}"
    
    # Create DB subnet group
    DB_SUBNET_GROUP_NAME="${ID}-db-subnet-group"
    if ! aws rds describe-db-subnet-groups --db-subnet-group-name ${DB_SUBNET_GROUP_NAME} --region ${AWS_REGION} &>/dev/null; then
        log "INFO" "Creating DB subnet group..."
        aws rds create-db-subnet-group \
            --db-subnet-group-name ${DB_SUBNET_GROUP_NAME} \
            --db-subnet-group-description "Subnet group for Python app RDS instance" \
            --subnet-ids ${SUBNET_IDS} \
            --tags "Key=Environment,Value=Dev" "Key=Project,Value=PythonAppSignals" "Key=ClusterName,Value=${CLUSTER_NAME}" \
            --region ${AWS_REGION}
    fi

    # Create security group for RDS
    RDS_SECURITY_GROUP_NAME="${ID}-rds-sg"
    if ! aws ec2 describe-security-groups --filters "Name=group-name,Values=${RDS_SECURITY_GROUP_NAME}" --region ${AWS_REGION} &>/dev/null; then
        log "INFO" "Creating RDS security group..."
        RDS_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
            --group-name ${RDS_SECURITY_GROUP_NAME} \
            --description "Security group for Python app RDS MySQL instance" \
            --vpc-id ${VPC_ID} \
            --region ${AWS_REGION} \
            --query 'GroupId' --output text)
        
        if [ -z "$RDS_SECURITY_GROUP_ID" ] || [ "$RDS_SECURITY_GROUP_ID" = "None" ] || [ "$RDS_SECURITY_GROUP_ID" = "null" ]; then
            log "ERROR" "Failed to create RDS security group"
            exit 1
        fi
        log "DEBUG" "Created RDS Security Group ID: ${RDS_SECURITY_GROUP_ID}"
        
        # Get EKS cluster security group
        EKS_SECURITY_GROUP_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
        if [ -z "$EKS_SECURITY_GROUP_ID" ] || [ "$EKS_SECURITY_GROUP_ID" = "None" ] || [ "$EKS_SECURITY_GROUP_ID" = "null" ]; then
            log "WARNING" "Failed to get EKS cluster security group ID, trying alternative approach..."
            # Try to get security groups from the cluster's additional security groups
            EKS_SECURITY_GROUP_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.securityGroupIds[0]' --output text)
            if [ -z "$EKS_SECURITY_GROUP_ID" ] || [ "$EKS_SECURITY_GROUP_ID" = "None" ] || [ "$EKS_SECURITY_GROUP_ID" = "null" ]; then
                log "WARNING" "Could not get EKS security group, allowing access from VPC CIDR instead"
                # Get VPC CIDR block as fallback
                VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids ${VPC_ID} --region ${AWS_REGION} --query 'Vpcs[0].CidrBlock' --output text)
                if [ -z "$VPC_CIDR" ] || [ "$VPC_CIDR" = "None" ] || [ "$VPC_CIDR" = "null" ]; then
                    log "ERROR" "Failed to get VPC CIDR block"
                    exit 1
                fi
                log "DEBUG" "Using VPC CIDR: ${VPC_CIDR}"
                # Allow MySQL access from VPC CIDR
                aws ec2 authorize-security-group-ingress \
                    --group-id ${RDS_SECURITY_GROUP_ID} \
                    --protocol tcp \
                    --port 3306 \
                    --cidr ${VPC_CIDR} \
                    --region ${AWS_REGION}
            else
                log "DEBUG" "EKS Security Group ID (alternative): ${EKS_SECURITY_GROUP_ID}"
                # Allow MySQL access from EKS cluster
                aws ec2 authorize-security-group-ingress \
                    --group-id ${RDS_SECURITY_GROUP_ID} \
                    --protocol tcp \
                    --port 3306 \
                    --source-group ${EKS_SECURITY_GROUP_ID} \
                    --region ${AWS_REGION}
            fi
        else
            log "DEBUG" "EKS Security Group ID: ${EKS_SECURITY_GROUP_ID}"
            # Allow MySQL access from EKS cluster
            aws ec2 authorize-security-group-ingress \
                --group-id ${RDS_SECURITY_GROUP_ID} \
                --protocol tcp \
                --port 3306 \
                --source-group ${EKS_SECURITY_GROUP_ID} \
                --region ${AWS_REGION}
        fi

        
        # Tag the security group
        aws ec2 create-tags \
            --resources ${RDS_SECURITY_GROUP_ID} \
            --tags "Key=Environment,Value=Dev" "Key=Project,Value=PythonAppSignals" "Key=ClusterName,Value=${CLUSTER_NAME}" \
            --region ${AWS_REGION}
    else
        log "INFO" "RDS security group already exists, retrieving ID..."
        # First check if any security groups match the filter
        SG_COUNT=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${RDS_SECURITY_GROUP_NAME}" \
            --region ${AWS_REGION} \
            --query 'length(SecurityGroups)' --output text)
        
        if [ "$SG_COUNT" = "0" ]; then
            log "WARNING" "Security group ${RDS_SECURITY_GROUP_NAME} not found, creating new one..."
            # Create the security group since it doesn't exist
            RDS_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
                --group-name ${RDS_SECURITY_GROUP_NAME} \
                --description "Security group for Python app RDS MySQL instance" \
                --vpc-id ${VPC_ID} \
                --region ${AWS_REGION} \
                --query 'GroupId' --output text)
            
            if [ -z "$RDS_SECURITY_GROUP_ID" ] || [ "$RDS_SECURITY_GROUP_ID" = "None" ] || [ "$RDS_SECURITY_GROUP_ID" = "null" ]; then
                log "ERROR" "Failed to create RDS security group"
                exit 1
            fi
            log "DEBUG" "Created RDS Security Group ID: ${RDS_SECURITY_GROUP_ID}"
            
            # Add ingress rules for the newly created security group
            # Get EKS cluster security group
            EKS_SECURITY_GROUP_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
            if [ -z "$EKS_SECURITY_GROUP_ID" ] || [ "$EKS_SECURITY_GROUP_ID" = "None" ] || [ "$EKS_SECURITY_GROUP_ID" = "null" ]; then
                log "WARNING" "Failed to get EKS cluster security group ID, trying alternative approach..."
                # Try to get security groups from the cluster's additional security groups
                EKS_SECURITY_GROUP_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.securityGroupIds[0]' --output text)
                if [ -z "$EKS_SECURITY_GROUP_ID" ] || [ "$EKS_SECURITY_GROUP_ID" = "None" ] || [ "$EKS_SECURITY_GROUP_ID" = "null" ]; then
                    log "WARNING" "Could not get EKS security group, allowing access from VPC CIDR instead"
                    # Get VPC CIDR block as fallback
                    VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids ${VPC_ID} --region ${AWS_REGION} --query 'Vpcs[0].CidrBlock' --output text)
                    if [ -z "$VPC_CIDR" ] || [ "$VPC_CIDR" = "None" ] || [ "$VPC_CIDR" = "null" ]; then
                        log "ERROR" "Failed to get VPC CIDR block"
                        exit 1
                    fi
                    log "DEBUG" "Using VPC CIDR: ${VPC_CIDR}"
                    # Allow MySQL access from VPC CIDR
                    aws ec2 authorize-security-group-ingress \
                        --group-id ${RDS_SECURITY_GROUP_ID} \
                        --protocol tcp \
                        --port 3306 \
                        --cidr ${VPC_CIDR} \
                        --region ${AWS_REGION}
                else
                    log "DEBUG" "EKS Security Group ID (alternative): ${EKS_SECURITY_GROUP_ID}"
                    # Allow MySQL access from EKS cluster
                    aws ec2 authorize-security-group-ingress \
                        --group-id ${RDS_SECURITY_GROUP_ID} \
                        --protocol tcp \
                        --port 3306 \
                        --source-group ${EKS_SECURITY_GROUP_ID} \
                        --region ${AWS_REGION}
                fi
            else
                log "DEBUG" "EKS Security Group ID: ${EKS_SECURITY_GROUP_ID}"
                # Allow MySQL access from EKS cluster
                aws ec2 authorize-security-group-ingress \
                    --group-id ${RDS_SECURITY_GROUP_ID} \
                    --protocol tcp \
                    --port 3306 \
                    --source-group ${EKS_SECURITY_GROUP_ID} \
                    --region ${AWS_REGION}
            fi
            
            # Tag the security group
            aws ec2 create-tags \
                --resources ${RDS_SECURITY_GROUP_ID} \
                --tags "Key=Environment,Value=Dev" "Key=Project,Value=PythonAppSignals" "Key=ClusterName,Value=${CLUSTER_NAME}" \
                --region ${AWS_REGION}
        else
            # Get the existing security group ID
            RDS_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
                --filters "Name=group-name,Values=${RDS_SECURITY_GROUP_NAME}" \
                --region ${AWS_REGION} \
                --query 'SecurityGroups[0].GroupId' --output text)
            
            if [ -z "$RDS_SECURITY_GROUP_ID" ] || [ "$RDS_SECURITY_GROUP_ID" = "None" ] || [ "$RDS_SECURITY_GROUP_ID" = "null" ]; then
                log "ERROR" "Failed to get existing RDS security group ID despite finding ${SG_COUNT} security groups"
                exit 1
            fi
            log "DEBUG" "Using existing RDS Security Group ID: ${RDS_SECURITY_GROUP_ID}"
        fi
    fi

    # Validate security group ID before creating RDS instance
    if [ -z "$RDS_SECURITY_GROUP_ID" ] || [ "$RDS_SECURITY_GROUP_ID" = "None" ] || [ "$RDS_SECURITY_GROUP_ID" = "null" ]; then
        log "ERROR" "RDS Security Group ID is empty or invalid: '${RDS_SECURITY_GROUP_ID}'"
        exit 1
    fi

    # Create RDS instance
    log "INFO" "Creating RDS MySQL instance ${RDS_INSTANCE_ID}..."
    log "DEBUG" "Using Security Group ID: ${RDS_SECURITY_GROUP_ID}"
    log "DEBUG" "Using DB Subnet Group: ${DB_SUBNET_GROUP_NAME}"
    
    aws rds create-db-instance \
        --db-instance-identifier ${RDS_INSTANCE_ID} \
        --db-instance-class db.t3.micro \
        --engine mysql \
        --engine-version 8.4.6 \
        --master-username ${RDS_USERNAME} \
        --master-user-password ${RDS_PASSWORD} \
        --allocated-storage 20 \
        --storage-type gp2 \
        --db-name ${RDS_DB_NAME} \
        --vpc-security-group-ids ${RDS_SECURITY_GROUP_ID} \
        --db-subnet-group-name ${DB_SUBNET_GROUP_NAME} \
        --backup-retention-period 7 \
        --storage-encrypted \
        --tags "Key=Environment,Value=Dev" "Key=Project,Value=PythonAppSignals" "Key=ClusterName,Value=${CLUSTER_NAME}" \
        --region ${AWS_REGION}

    log "INFO" "Waiting for RDS instance to become available..."
    aws rds wait db-instance-available --db-instance-identifier ${RDS_INSTANCE_ID} --region ${AWS_REGION}
    
    # Get RDS endpoint
    RDS_ENDPOINT=$(aws rds describe-db-instances \
        --db-instance-identifier ${RDS_INSTANCE_ID} \
        --region ${AWS_REGION} \
        --query 'DBInstances[0].Endpoint.Address' --output text)

    log "SUCCESS" "RDS MySQL instance created successfully"
    log "INFO" "RDS Endpoint: ${RDS_ENDPOINT}"
}

# Create SSM parameters for database configuration
create_ssm_parameters() {
    log "INFO" "Creating SSM parameters for database configuration..."
    
    # Create SSM parameter for MySQL pool size with default value
    log "DEBUG" "Creating SSM parameter for MySQL pool size..."
    if aws ssm get-parameter --name "/python-sample-app/mysql/pool-size" --region ${AWS_REGION} &>/dev/null; then
        log "WARNING" "SSM parameter /python-sample-app/mysql/pool-size already exists, updating..."
        aws ssm put-parameter \
            --name "/python-sample-app/mysql/pool-size" \
            --value "10" \
            --type "String" \
            --description "MySQL connection pool size for python-sample-app" \
            --overwrite \
            --tags "Key=Environment,Value=Dev" "Key=Project,Value=PythonAppSignals" "Key=ClusterName,Value=${CLUSTER_NAME}" \
            --region ${AWS_REGION}
    else
        log "INFO" "Creating new SSM parameter /python-sample-app/mysql/pool-size..."
        aws ssm put-parameter \
            --name "/python-sample-app/mysql/pool-size" \
            --value "10" \
            --type "String" \
            --description "MySQL connection pool size for python-sample-app" \
            --tags "Key=Environment,Value=Dev" "Key=Project,Value=PythonAppSignals" "Key=ClusterName,Value=${CLUSTER_NAME}" \
            --region ${AWS_REGION}
    fi
    
    # Create SSM parameter for MySQL max overflow with default value
    log "DEBUG" "Creating SSM parameter for MySQL max overflow..."
    if aws ssm get-parameter --name "/python-sample-app/mysql/max-overflow" --region ${AWS_REGION} &>/dev/null; then
        log "WARNING" "SSM parameter /python-sample-app/mysql/max-overflow already exists, updating..."
        aws ssm put-parameter \
            --name "/python-sample-app/mysql/max-overflow" \
            --value "20" \
            --type "String" \
            --description "MySQL connection pool max overflow for python-sample-app" \
            --overwrite \
            --tags "Key=Environment,Value=Dev" "Key=Project,Value=PythonAppSignals" "Key=ClusterName,Value=${CLUSTER_NAME}" \
            --region ${AWS_REGION}
    else
        log "INFO" "Creating new SSM parameter /python-sample-app/mysql/max-overflow..."
        aws ssm put-parameter \
            --name "/python-sample-app/mysql/max-overflow" \
            --value "20" \
            --type "String" \
            --description "MySQL connection pool max overflow for python-sample-app" \
            --tags "Key=Environment,Value=Dev" "Key=Project,Value=PythonAppSignals" "Key=ClusterName,Value=${CLUSTER_NAME}" \
            --region ${AWS_REGION}
    fi
    
    # Create SSM parameter for fault injection with default value (disabled)
    log "DEBUG" "Creating SSM parameter for fault injection..."
    if aws ssm get-parameter --name "/python-sample-app/mysql/fault-injection" --region ${AWS_REGION} &>/dev/null; then
        log "WARNING" "SSM parameter /python-sample-app/mysql/fault-injection already exists, updating..."
        aws ssm put-parameter \
            --name "/python-sample-app/mysql/fault-injection" \
            --value "false" \
            --type "String" \
            --description "Database fault injection flag for python-sample-app (10s delay per query when enabled)" \
            --overwrite \
            --tags "Key=Environment,Value=Dev" "Key=Project,Value=PythonAppSignals" "Key=ClusterName,Value=${CLUSTER_NAME}" \
            --region ${AWS_REGION}
    else
        log "INFO" "Creating new SSM parameter /python-sample-app/mysql/fault-injection..."
        aws ssm put-parameter \
            --name "/python-sample-app/mysql/fault-injection" \
            --value "false" \
            --type "String" \
            --description "Database fault injection flag for python-sample-app (10s delay per query when enabled)" \
            --tags "Key=Environment,Value=Dev" "Key=Project,Value=PythonAppSignals" "Key=ClusterName,Value=${CLUSTER_NAME}" \
            --region ${AWS_REGION}
    fi
    
    log "SUCCESS" "SSM parameters created successfully"
    log "INFO" "  - /python-sample-app/mysql/pool-size: 10"
    log "INFO" "  - /python-sample-app/mysql/max-overflow: 20"
    log "INFO" "  - /python-sample-app/mysql/fault-injection: false"
}

# Create IAM policies and service accounts
create_iam_resources() {
    log "INFO" "Creating IAM resources..."
    local common_tags=$(get_common_tags)

    # Create Python Order API policy (minimal permissions for direct workflow)
    log "DEBUG" "Creating Python Order API policy document..."
    cat > python-order-api-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "rds:DescribeDBInstances",
                "rds:DescribeDBClusters"
            ],
            "Resource": "*"
        }
    ]
}
EOF

    # Create Python Delivery API policy for RDS and SSM access
    log "DEBUG" "Creating Python Delivery API policy document with SSM permissions..."
    cat > python-delivery-api-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "rds:DescribeDBInstances",
                "rds:DescribeDBClusters"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter",
                "ssm:GetParameters"
            ],
            "Resource": [
                "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter/python-sample-app/mysql/pool-size",
                "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter/python-sample-app/mysql/max-overflow",
                "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter/python-sample-app/mysql/fault-injection"
            ]
        }
    ]
}
EOF

    # Create or update Python Order API policy
    if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${PYTHON_ORDER_API_POLICY_NAME}" 2>/dev/null; then
        log "INFO" "Updating existing policy ${PYTHON_ORDER_API_POLICY_NAME}"
        POLICY_VERSION=$(aws iam create-policy-version \
            --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${PYTHON_ORDER_API_POLICY_NAME}" \
            --policy-document file://python-order-api-policy.json \
            --set-as-default \
            --query 'PolicyVersion.VersionId' \
            --output text)
        PYTHON_ORDER_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${PYTHON_ORDER_API_POLICY_NAME}"
    else
        log "INFO" "Creating new policy ${PYTHON_ORDER_API_POLICY_NAME}"
        PYTHON_ORDER_POLICY_ARN=$(aws iam create-policy \
            --policy-name "${PYTHON_ORDER_API_POLICY_NAME}" \
            --policy-document file://python-order-api-policy.json \
            --tags "Key=Environment,Value=Dev" "Key=Project,Value=PythonAppSignals" "Key=ClusterName,Value=${CLUSTER_NAME}" \
            --query 'Policy.Arn' \
            --output text)
    fi

    # Create or update Python Delivery API policy
    if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${PYTHON_DELIVERY_API_POLICY_NAME}" 2>/dev/null; then
        log "INFO" "Updating existing policy ${PYTHON_DELIVERY_API_POLICY_NAME}"
        POLICY_VERSION=$(aws iam create-policy-version \
            --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${PYTHON_DELIVERY_API_POLICY_NAME}" \
            --policy-document file://python-delivery-api-policy.json \
            --set-as-default \
            --query 'PolicyVersion.VersionId' \
            --output text)
        PYTHON_DELIVERY_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${PYTHON_DELIVERY_API_POLICY_NAME}"
    else
        log "INFO" "Creating new policy ${PYTHON_DELIVERY_API_POLICY_NAME}"
        PYTHON_DELIVERY_POLICY_ARN=$(aws iam create-policy \
            --policy-name "${PYTHON_DELIVERY_API_POLICY_NAME}" \
            --policy-document file://python-delivery-api-policy.json \
            --tags "Key=Environment,Value=Dev" "Key=Project,Value=PythonAppSignals" "Key=ClusterName,Value=${CLUSTER_NAME}" \
            --query 'Policy.Arn' \
            --output text)
    fi

    log "SUCCESS" "Python Order API Policy ARN: $PYTHON_ORDER_POLICY_ARN"
    log "SUCCESS" "Python Delivery API Policy ARN: $PYTHON_DELIVERY_POLICY_ARN"

    # Create service accounts
    log "INFO" "Creating service accounts..."
    
    # Python Order API service account
    log "INFO" "Creating service account ${PYTHON_ORDER_SERVICE_ACCOUNT_NAME}"
    kubectl delete serviceaccount ${PYTHON_ORDER_SERVICE_ACCOUNT_NAME} --ignore-not-found --namespace default
    
    eksctl create iamserviceaccount \
        --cluster=${CLUSTER_NAME} \
        --namespace=default \
        --name=${PYTHON_ORDER_SERVICE_ACCOUNT_NAME} \
        --attach-policy-arn=${PYTHON_ORDER_POLICY_ARN} \
        --override-existing-serviceaccounts \
        --approve \
        --region ${AWS_REGION}

    # Verify Python Order API service account
    if ! kubectl get serviceaccount ${PYTHON_ORDER_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        log "ERROR" "Python Order API service account creation failed"
        exit 1
    fi
    log "SUCCESS" "Python Order API service account created successfully"

    # Python Delivery API service account
    log "INFO" "Creating service account ${PYTHON_DELIVERY_SERVICE_ACCOUNT_NAME}"
    kubectl delete serviceaccount ${PYTHON_DELIVERY_SERVICE_ACCOUNT_NAME} --ignore-not-found --namespace default
    
    eksctl create iamserviceaccount \
        --cluster=${CLUSTER_NAME} \
        --namespace=default \
        --name=${PYTHON_DELIVERY_SERVICE_ACCOUNT_NAME} \
        --attach-policy-arn=${PYTHON_DELIVERY_POLICY_ARN} \
        --override-existing-serviceaccounts \
        --approve \
        --region ${AWS_REGION}

    # Verify Python Delivery API service account
    if ! kubectl get serviceaccount ${PYTHON_DELIVERY_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        log "ERROR" "Python Delivery API service account creation failed"
        exit 1
    fi
    log "SUCCESS" "Python Delivery API service account created successfully"

    rm -f python-order-api-policy.json python-delivery-api-policy.json
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
        "rds_instance": {
            "id": "${RDS_INSTANCE_ID}",
            "endpoint": "${RDS_ENDPOINT}",
            "database": "${RDS_DB_NAME}",
            "username": "${RDS_USERNAME}",
            "password": "${RDS_PASSWORD}"
        },
        "service_account": "${SERVICE_ACCOUNT_NAME}",
        "python_order_service_account": "${PYTHON_ORDER_SERVICE_ACCOUNT_NAME}",
        "python_delivery_service_account": "${PYTHON_DELIVERY_SERVICE_ACCOUNT_NAME}",
        "python_order_api_policy": {
            "name": "${PYTHON_ORDER_API_POLICY_NAME}",
            "arn": "${PYTHON_ORDER_POLICY_ARN}"
        },
        "python_delivery_api_policy": {
            "name": "${PYTHON_DELIVERY_API_POLICY_NAME}",
            "arn": "${PYTHON_DELIVERY_POLICY_ARN}"
        },
        "rds_security_group": "${RDS_SECURITY_GROUP_ID}",
        "db_subnet_group": "${DB_SUBNET_GROUP_NAME}",
        "ssm_parameters": {
            "mysql_pool_size": "/python-sample-app/mysql/pool-size",
            "mysql_max_overflow": "/python-sample-app/mysql/max-overflow"
        }
    },
    "tags": {
        "Environment": "Dev",
        "Project": "PythonAppSignals",
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
    if ! kubectl get serviceaccount ${PYTHON_ORDER_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        log "ERROR" "Python Order service account verification failed"
        exit 1
    fi
    log "SUCCESS" "Python Order service account verified"

    if ! kubectl get serviceaccount ${PYTHON_DELIVERY_SERVICE_ACCOUNT_NAME} --namespace default &>/dev/null; then
        log "ERROR" "Python Delivery service account verification failed"
        exit 1
    fi
    log "SUCCESS" "Python Delivery service account verified"

    # Check RDS instance
    if ! aws rds describe-db-instances \
        --db-instance-identifier ${RDS_INSTANCE_ID} \
        --region ${AWS_REGION} \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text &>/dev/null; then
        log "ERROR" "RDS instance verification failed"
        exit 1
    fi
    log "SUCCESS" "RDS instance verified"

    # Check SSM parameters
    if ! aws ssm get-parameter --name "/python-sample-app/mysql/pool-size" --region ${AWS_REGION} &>/dev/null; then
        log "ERROR" "SSM parameter /python-sample-app/mysql/pool-size verification failed"
        exit 1
    fi
    if ! aws ssm get-parameter --name "/python-sample-app/mysql/max-overflow" --region ${AWS_REGION} &>/dev/null; then
        log "ERROR" "SSM parameter /python-sample-app/mysql/max-overflow verification failed"
        exit 1
    fi
    log "SUCCESS" "SSM parameters verified"
    
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
    log "SUCCESS" "Environment setup completed!"
    log "SUCCESS" "========================================="
    
    log "INFO" "\nCluster: ${CLUSTER_NAME} (${AWS_REGION})"
    log "INFO" "Database: Ready for connections"
    
    log "INFO" "\nNext step: Run ./scripts/2-build-deploy-app.sh"
}

# Main execution
main() {
    log "INFO" "Starting Python environment setup..."
    
    parse_arguments "$@"  
    get_aws_details     
    check_prerequisites
    setup_resource_names
    get_cluster_name
    
    log "INFO" "\nCreating resources..."
    create_eks_cluster
    create_rds_instance
    create_ssm_parameters
    create_iam_resources
    
    log "INFO" "\nFinalizing setup..."
    verify_setup
    save_config
    print_summary
}

# Execute main function with arguments
main "$@"