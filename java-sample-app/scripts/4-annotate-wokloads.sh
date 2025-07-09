#!/usr/bin/env bash
set -eo pipefail

# Log levels and colors
ERROR_COLOR='\033[0;31m'
SUCCESS_COLOR='\033[0;32m'
WARNING_COLOR='\033[1;33m'
INFO_COLOR='\033[0;34m'
NO_COLOR='\033[0m'

# Logging function
log() {
    local level=$(echo "${1}" | tr '[:lower:]' '[:upper:]')
    local message="$2"
    local color
    
    case $level in
        ERROR)   color=$ERROR_COLOR ;;
        SUCCESS) color=$SUCCESS_COLOR ;;
        WARNING) color=$WARNING_COLOR ;;
        INFO)    color=$INFO_COLOR ;;
        *)       color=$INFO_COLOR ;;
    esac
    
    echo -e "${color}${level}: ${message}${NO_COLOR}" >&2
}

# Process each deployment file
process_file() {
    local file="$1"
    local temp_file="${file}.tmp"
    
    log "INFO" "Processing: $file"
    
    # Create temporary file
    awk '
    /template:/ { in_template = 1 }
    /metadata:/ && in_template {
        print $0
        print "      annotations:"
        print "        instrumentation.opentelemetry.io/inject-java: \"true\""
        in_template = 0
        next
    }
    { print }' "$file" > "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$file"
    log "SUCCESS" "Updated $file"
}

main() {
    cd kubernetes
    
    for file in order-api-deployment.yaml delivery-api-deployment.yaml; do
        if [[ -f "$file" ]]; then
            process_file "$file"
        else
            log "ERROR" "File not found: $file"
        fi
    done
    
    log "INFO" "Annotation process complete"
}

main