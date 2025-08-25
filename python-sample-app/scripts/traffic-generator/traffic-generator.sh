#!/bin/bash

# Python Traffic Generator Shell Script
# This script provides a wrapper around the Python traffic generator
# with the same interface as the Java version for consistency.

# Load Test Configuration Guide
# ---------------------------
# Environment variables that control the load test:
#
# 1. BATCH_SIZE: Number of concurrent requests per batch (default: 3)
# 2. STATS_INTERVAL: How often to print statistics in seconds (default: 60)
# 3. ALB_URL: The URL of the ALB (required)
# 4. API_PATH: The API path to test (default: /api/orders)
# 5. METRICS_FILE: File to store metrics (default: /tmp/load_test_metrics.txt)

# Colors for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Print colorized message
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Log message with timestamp
log() {
    local level=$1
    local message=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# Help function
show_help() {
    print_message $GREEN "Python Traffic Generator for CloudWatch Application Signals"
    print_message $GREEN ""
    print_message $GREEN "Usage: ALB_URL=your-alb-url.com ./traffic-generator.sh"
    print_message $GREEN ""
    print_message $GREEN "Required Environment Variables:"
    print_message $GREEN "  ALB_URL          - The URL of the Application Load Balancer"
    print_message $GREEN ""
    print_message $GREEN "Optional Environment Variables:"
    print_message $GREEN "  BATCH_SIZE       - Number of concurrent requests per batch (default: 3)"
    print_message $GREEN "  STATS_INTERVAL   - Statistics reporting interval in seconds (default: 60)"
    print_message $GREEN "  API_PATH         - API endpoint path (default: /api/orders)"
    print_message $GREEN "  METRICS_FILE     - Metrics output file (default: /tmp/load_test_metrics.txt)"
    print_message $GREEN ""
    print_message $GREEN "Examples:"
    print_message $GREEN "  # Basic usage"
    print_message $GREEN "  ALB_URL=my-alb-123456789.us-west-2.elb.amazonaws.com ./traffic-generator.sh"
    print_message $GREEN ""
    print_message $GREEN "  # Custom configuration"
    print_message $GREEN "  ALB_URL=my-alb.com BATCH_SIZE=5 STATS_INTERVAL=30 ./traffic-generator.sh"
}

# Initialize configuration with defaults
BATCH_SIZE=${BATCH_SIZE:-3}
STATS_INTERVAL=${STATS_INTERVAL:-60}
METRICS_FILE=${METRICS_FILE:-"/tmp/load_test_metrics.txt"}
API_PATH=${API_PATH:-"/api/orders"}

# Check for help flag first
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

# Validate required environment variables
if [ -z "$ALB_URL" ]; then
    print_message $RED "ALB_URL environment variable is required"
    print_message $YELLOW "Usage: ALB_URL=your-alb-url.com ./traffic-generator.sh"
    print_message $YELLOW "Optional environment variables:"
    print_message $YELLOW "  BATCH_SIZE=3 (number of concurrent requests per batch)"
    print_message $YELLOW "  STATS_INTERVAL=60 (statistics reporting interval in seconds)"
    print_message $YELLOW "  API_PATH=/api/orders (API endpoint path)"
    print_message $YELLOW "  METRICS_FILE=/tmp/load_test_metrics.txt (metrics output file)"
    exit 1
fi

# Print configuration details
print_config() {
    print_message $GREEN "Python Traffic Generator Configuration:"
    print_message $GREEN "ALB URL: $ALB_URL"
    print_message $GREEN "API Path: $API_PATH"
    print_message $GREEN "Batch size: $BATCH_SIZE requests"
    print_message $GREEN "Stats interval: $STATS_INTERVAL seconds"
    print_message $GREEN "Metrics file: $METRICS_FILE"
    print_message $GREEN "Python version: $(python3 --version 2>/dev/null || echo 'Not found')"
}

# Check Python dependencies
check_dependencies() {
    log "INFO" "Checking Python dependencies..."
    
    # Check if Python 3 is available
    if ! command -v python3 &> /dev/null; then
        print_message $RED "Python 3 is not installed or not in PATH"
        exit 1
    fi
    
    # Check if required packages are installed
    python3 -c "import aiohttp, aiofiles" 2>/dev/null
    if [ $? -ne 0 ]; then
        print_message $RED "Required Python packages are not installed"
        print_message $RED "This should not happen in a properly built container"
        print_message $YELLOW "Required packages: aiohttp, aiofiles"
        exit 1
    fi
    
    log "INFO" "Dependencies check completed successfully"
}

# Signal handler for graceful shutdown
cleanup() {
    log "INFO" "Received shutdown signal, stopping traffic generator..."
    if [ ! -z "$PYTHON_PID" ]; then
        kill -TERM "$PYTHON_PID" 2>/dev/null
        wait "$PYTHON_PID" 2>/dev/null
    fi
    print_message $GREEN "Traffic generator stopped"
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Validate ALB connectivity
test_connectivity() {
    log "INFO" "Testing connectivity to ALB..."
    
    # Test basic connectivity
    if command -v curl &> /dev/null; then
        response=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://${ALB_URL}/health" 2>/dev/null)
        if [ "$response" = "000" ]; then
            print_message $YELLOW "Warning: Could not connect to ALB health endpoint"
            print_message $YELLOW "This might be normal if health endpoint is not available"
        else
            log "INFO" "ALB connectivity test completed (HTTP $response)"
        fi
    else
        print_message $YELLOW "curl not available, skipping connectivity test"
    fi
}

# Main execution
main() {
    print_message $YELLOW "Starting Python Traffic Generator..."
    
    # Print initial configuration
    print_config
    
    # Check dependencies
    check_dependencies
    
    # Test connectivity
    test_connectivity
    
    # Export environment variables for Python script
    export BATCH_SIZE
    export STATS_INTERVAL
    export ALB_URL
    export API_PATH
    export METRICS_FILE
    
    log "INFO" "Starting Python traffic generator process..."
    
    # Start the Python traffic generator
    python3 traffic-generator.py &
    PYTHON_PID=$!
    
    # Wait for the Python process to complete
    wait "$PYTHON_PID"
    exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log "INFO" "Traffic generator completed successfully"
    else
        log "ERROR" "Traffic generator exited with code $exit_code"
    fi
    
    exit $exit_code
}

# Run main function
main