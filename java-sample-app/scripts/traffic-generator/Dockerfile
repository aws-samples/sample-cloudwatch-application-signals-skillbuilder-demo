FROM --platform=linux/amd64 alpine:3.18

# Install required packages
RUN apk add --no-cache \
    bash \
    curl \
    bc \
    util-linux \
    jq \
    procps

# Create app directory and non-root user
RUN adduser -D -u 10000 appuser
WORKDIR /app

# Copy the script
COPY traffic-generator.sh .

# Make script executable and set permissions
RUN chmod +x traffic-generator.sh && \
    chown -R appuser:appuser /app

# Set default environment variables
ENV BATCH_SIZE=5 \
    STATS_INTERVAL=60 \
    METRICS_FILE="/tmp/load_test_metrics.txt" \
    ALB_URL="" \
    API_PATH="/api/orders"

USER appuser

# Add healthcheck to verify the container is still running properly
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ps aux | grep traffic-generator.sh | grep -v grep || exit 1

CMD ["./traffic-generator.sh"]