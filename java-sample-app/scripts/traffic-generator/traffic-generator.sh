#!/bin/bash

# Load Test Configuration Guide
# ---------------------------
# Environment variables that control the load test:
#
# 1. BATCH_SIZE: Number of concurrent requests per batch (default: 3)
# 2. STATS_INTERVAL: How often to print statistics in seconds (default: 60)
# 3. ALB_URL: The URL of the ALB (required)
# 4. API_PATH: The API path to test (default: /api/orders)

# Colors for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Print colorized message
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Initialize global variables
BATCH_SIZE=${BATCH_SIZE:-3}
STATS_INTERVAL=${STATS_INTERVAL:-60}
METRICS_FILE=${METRICS_FILE:-"/tmp/load_test_metrics.txt"}
API_PATH=${API_PATH:-"/api/orders"}

# Print configuration details
print_config() {
    print_message $GREEN "Configuration:"
    print_message $GREEN "ALB URL: $ALB_URL"
    print_message $GREEN "API Path: $API_PATH"
    print_message $GREEN "Batch size: $BATCH_SIZE requests"
    print_message $GREEN "Stats interval: $STATS_INTERVAL seconds"
}

# Validate required environment variables
if [ -z "$ALB_URL" ]; then
    print_message $RED "ALB_URL environment variable is required"
    exit 1
fi

# Initial configuration display
print_config

# Clear metrics file
> "$METRICS_FILE"

# Function to generate a random name
generate_random_name() {
    local first_names=("John" "Jane" "Mike" "Emily" "David" "Sarah" "Chris" "Emma" "Alex" "Olivia")
    local last_names=("Smith" "Johnson" "Williams" "Brown" "Jones" "Garcia" "Miller" "Davis" "Rodriguez" "Martinez")
    local first=${first_names[$RANDOM % ${#first_names[@]}]}
    local last=${last_names[$RANDOM % ${#last_names[@]}]}
    echo "$first $last"
}

# Generate a random UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# Send HTTP request
send_request() {
    local id=$1
    local start_time=$(date +%s.%N)
    
    # Generate order ID and product ID
    local order_id=$(generate_uuid)
    local product_id=$(generate_uuid)
    
    # Generate a unique customer name
    local customer_name=$(generate_random_name)
    
    # Create request payload
    local data="{
        \"orderId\": \"$order_id\",
        \"customerName\": \"$customer_name\",
        \"items\": [{
            \"productId\": \"$product_id\",
            \"quantity\": 2,
            \"price\": 29.99
        }],
        \"totalAmount\": 59.98,
        \"shippingAddress\": \"123 Test St, Test City, TS 12345\"
    }"
    
    # Send POST request
    local response=$(curl -s -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "http://${ALB_URL}${API_PATH}" 2>/dev/null)
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed \$d)
    
    # Track metrics
    if [[ $http_code == 2* ]]; then
        echo "$id,$duration,$(date +%s),$http_code,$customer_name" >> "$METRICS_FILE"
        print_message $GREEN "Request $id successful: $http_code (Customer: $customer_name)"
    else
        print_message $RED "Request $id failed with status $http_code: $body (Customer: $customer_name)"
    fi
}

# Print statistics
print_statistics() {
    local current_time=$(date +%s)
    local window_start=$((current_time - STATS_INTERVAL))
    local window_requests=0
    local window_total_time=0
    local successful_requests=0
    local failed_requests=0
    
    # Check if metrics file exists and is not empty
    if [ -s "$METRICS_FILE" ]; then
        while IFS=, read -r id duration timestamp status customer_name; do
            if [ "$timestamp" -ge "$window_start" ]; then
                ((window_requests++))
                window_total_time=$(echo "$window_total_time + $duration" | bc)
                if [[ $status == 2* ]]; then
                    ((successful_requests++))
                else
                    ((failed_requests++))
                fi
            fi
        done < "$METRICS_FILE"
    fi
    
    if [ "$window_requests" -gt 0 ]; then
        local avg_response_time=$(echo "scale=3; $window_total_time / $window_requests" | bc)
        local requests_per_second=$(echo "scale=2; $window_requests / $STATS_INTERVAL" | bc)
        local success_rate=$(echo "scale=2; $successful_requests * 100 / $window_requests" | bc)
        
        print_message $GREEN "\nLast ${STATS_INTERVAL} seconds statistics:"
        print_message $GREEN "Total Requests: $window_requests"
        print_message $GREEN "Successful Requests: $successful_requests"
        print_message $GREEN "Failed Requests: $failed_requests"
        print_message $GREEN "Success Rate: ${success_rate}%"
        print_message $GREEN "Requests/second: $requests_per_second"
        print_message $GREEN "Average Response Time: ${avg_response_time}s"
    else
        print_message $YELLOW "\nNo requests processed in the last ${STATS_INTERVAL} seconds"
    fi
    
    # Clean up old entries
    if [ -f "$METRICS_FILE" ]; then
        tmp_file=$(mktemp)
        while IFS=, read -r id duration timestamp status customer_name; do
            if [ "$timestamp" -ge "$window_start" ]; then
                echo "$id,$duration,$timestamp,$status,$customer_name" >> "$tmp_file"
            fi
        done < "$METRICS_FILE"
        mv "$tmp_file" "$METRICS_FILE"
    fi
}

# Log message with timestamp
log() {
    local level=$1
    local message=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# High load function with burst pattern to trigger throttling
high_load() {
    log "INFO" "Switching to high load burst mode (${BATCH_SIZE}x50 requests in bursts)"
    local end_time=$((SECONDS + 60))  # Run for 60 seconds
    
    while [ $SECONDS -lt $end_time ]; do
        # Create a burst by sending many requests in a very short time
        for j in $(seq 1 5); do  # 5 rapid bursts
            for i in $(seq 1 $((BATCH_SIZE * 10))); do  # Send BATCH_SIZE*10 requests in parallel
                send_request $request_id &
                ((request_id++))
            done
            # Don't wait between sub-bursts to create higher concurrency
        done
        
        # Now wait for all requests to complete
        wait
        
        # Brief pause between major bursts
        sleep 0.5
        
        # Check if it's time to print statistics
        current_time=$SECONDS
        if ((current_time - last_stats_time >= STATS_INTERVAL)); then
            print_statistics
            last_stats_time=$current_time
        fi
    done
}

# Normal load function (BATCH_SIZE requests per second)
normal_load() {
    log "INFO" "Switching to normal load mode (${BATCH_SIZE} requests/second)"
    local end_time=$((SECONDS + 60))  # Run for 60 seconds
    
    while [ $SECONDS -lt $end_time ]; do
        for i in $(seq 1 $BATCH_SIZE); do  # Send BATCH_SIZE requests in parallel
            send_request $request_id &
            ((request_id++))
        done
        wait  # Wait for all requests to complete
        sleep 1
        
        # Check if it's time to print statistics
        current_time=$SECONDS
        if ((current_time - last_stats_time >= STATS_INTERVAL)); then
            print_statistics
            last_stats_time=$current_time
        fi
    done
}

# Main execution
main() {
    print_message $YELLOW "Starting load generator..."
    log "INFO" "ALB URL: $ALB_URL"
    log "INFO" "API Path: $API_PATH"

    # Initialize counters
    request_id=0
    last_stats_time=$SECONDS
    config_print_counter=0

    while true; do
        high_load   # Run high load for 1 minute
        normal_load # Run normal load for 1 minute
        
        # Print configuration after each cycle
        print_config
    done
}

# Run main function
main