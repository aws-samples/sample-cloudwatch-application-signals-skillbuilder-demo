#!/bin/bash
set -eo pipefail

# Colors and logging
ERROR_COLOR='\033[0;31m'
SUCCESS_COLOR='\033[0;32m'
WARNING_COLOR='\033[1;33m'
INFO_COLOR='\033[0;34m'
DEBUG_COLOR='\033[0;37m'
NO_COLOR='\033[0m'

log() {
    local level=$1
    local message="$2"
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
trap 'log ERROR "Error occurred on line $LINENO"' ERR

# Read cluster config
read_cluster_config() {
    local config_file=".cluster-config/cluster-resources.json"
    if [[ ! -f $config_file ]]; then
        log ERROR "Cluster configuration file not found. Run create-env script first."
        exit 1
    fi
    CLUSTER_NAME=$(jq -r '.cluster.name' "$config_file")
    AWS_REGION=$(jq -r '.cluster.region' "$config_file")
    if [[ -z $CLUSTER_NAME || -z $AWS_REGION ]]; then
        log ERROR "Failed to read cluster name or region from config."
        exit 1
    fi
    log INFO "Using Cluster: $CLUSTER_NAME, Region: $AWS_REGION"
}

# Verify cluster context
verify_cluster_context() {
    local kub_config=$(kubectl config current-context)
    if [[ $kub_config != *"$CLUSTER_NAME"* || $kub_config != *"$AWS_REGION"* ]]; then
        log ERROR "Incorrect cluster context. Switch to $CLUSTER_NAME $AWS_REGION."
        exit 1
    fi
    log SUCCESS "Cluster context verified"
}

setup_service_linked_role() {
    log INFO "Creating service-linked role for CloudWatch Application Signals..."
    aws iam create-service-linked-role --aws-service-name application-signals.cloudwatch.amazonaws.com 2>/dev/null || true
}

setup_cloudwatch_service_account() {
    log INFO "Setting up CloudWatch service account..."
    eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --approve
    eksctl create iamserviceaccount \
        --name cloudwatch-agent \
        --namespace amazon-cloudwatch \
        --cluster "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --attach-policy-arn arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess \
        --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
        --approve \
        --override-existing-serviceaccounts
    log SUCCESS "Service account setup completed"
}

setup_cloudwatch_addon() {
    log INFO "Setting up Amazon CloudWatch Observability EKS add-on..."
    local addon_name="amazon-cloudwatch-observability"
    local addon_status=$(aws eks describe-addon --addon-name "$addon_name" --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'addon.status' --output text 2>/dev/null || echo "NOT_FOUND")

    if [[ "$addon_status" == "NOT_FOUND" ]]; then
        aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon_name" --region "$AWS_REGION"
        wait_for_addon_status "$addon_name" "ACTIVE" "CREATE_FAILED"
    else
        local update_available=$(aws eks describe-addon-versions --addon-name "$addon_name" --kubernetes-version $(kubectl version | grep 'Server Version:' | cut -d ' ' -f3) --query 'addons[0].addonVersions[0].compatibilities[0].defaultVersion' --output text)
        if [[ "$update_available" == "True" ]]; then
            log INFO "Update available for Amazon CloudWatch Observability EKS add-on"
            read -p "Update addon to latest version? (yes/no): " choice
            if [[ "$choice" == "yes" ]]; then
                aws eks update-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon_name" --region "$AWS_REGION"
                wait_for_addon_status "$addon_name" "ACTIVE" "UPDATE_FAILED"
                log SUCCESS "Amazon CloudWatch Observability EKS add-on updated"
            else
                log INFO "Skipped addon update"
            fi
        else
            log INFO "Amazon CloudWatch Observability EKS add-on is up to date"
        fi
    fi
    log SUCCESS "Amazon CloudWatch Observability EKS add-on setup completed"
}

wait_for_addon_status() {
    local addon_name=$1
    local desired_status=$2
    local failure_status=$3
    while true; do
        local status=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon_name" --region "$AWS_REGION" --query 'addon.status' --output text)
        log INFO "Current status: $status"
        if [[ "$status" == "$desired_status" ]]; then
            break
        elif [[ "$status" == "$failure_status" ]]; then
            log ERROR "Failed to setup Amazon CloudWatch Observability EKS add-on"
            exit 1
        fi
        log INFO "Waiting for addon to become $desired_status..."
        sleep 20
    done
}

main() {
    log INFO "Starting CloudWatch setup"
    read_cluster_config
    verify_cluster_context
    setup_service_linked_role
    setup_cloudwatch_service_account
    setup_cloudwatch_addon
#    log SUCCESS "\n========================================="
#    log SUCCESS "CloudWatch setup completed successfully!"
#    log SUCCESS "========================================="
    log INFO "\nSetup includes:\n- Service-linked role for Application Signals\n- CloudWatch service account with IAM roles\n- Amazon CloudWatch Observability EKS add-on"
    log INFO "\nFeatures enabled:\n- 1.Enhanced Container Insights\n- 2.CloudWatch Application Signals\n- 3.Container logs via Fluent Bit"
}

main
