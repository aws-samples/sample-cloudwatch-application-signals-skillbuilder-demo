# Multi-stage build for Python traffic generator
FROM python:3.13-slim as builder

# Set working directory
WORKDIR /app

# Install system dependencies for building
RUN apt-get update && apt-get install -y \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Production stage
FROM python:3.13-slim

# Set working directory
WORKDIR /app

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    curl \
    bc \
    && rm -rf /var/lib/apt/lists/*

# Copy Python packages from builder stage to system location
COPY --from=builder /usr/local/lib/python3.13/site-packages /usr/local/lib/python3.13/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy application files
COPY traffic-generator.py .
COPY traffic-generator.sh .

# Make scripts executable
RUN chmod +x traffic-generator.py traffic-generator.sh

# Create non-root user for security
RUN groupadd -r appuser && useradd -r -g appuser appuser
RUN chown -R appuser:appuser /app
USER appuser

# Default environment variables
ENV BATCH_SIZE=3
ENV STATS_INTERVAL=60
ENV API_PATH=/api/orders
ENV METRICS_FILE=/tmp/load_test_metrics.txt

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python3 -c "import aiohttp, aiofiles; print('Dependencies OK')" || exit 1

# Default command
CMD ["./traffic-generator.sh"]