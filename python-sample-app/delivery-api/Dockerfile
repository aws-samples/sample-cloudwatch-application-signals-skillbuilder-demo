# Build stage
FROM python:3.12-slim AS build

# Install build dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        curl \
        default-libmysqlclient-dev \
        pkg-config && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /workspace

# Copy requirements first for better caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Copy application source code
COPY . .

# Run stage
FROM python:3.12-slim

# Install runtime dependencies including MySQL client libraries
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        default-mysql-client \
        libmariadb3 && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -r -u 1000 -m appuser

# Set working directory
WORKDIR /app

# Copy Python dependencies from build stage
COPY --from=build /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=build /usr/local/bin /usr/local/bin

# Copy application code
COPY --chown=appuser:appuser . .

# Set ownership of the app directory
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Environment variables for service configuration
ENV SERVICE_NAME=python-delivery-api
ENV SERVICE_VERSION=1.0.0

# Environment variables for database configuration (to be overridden at runtime)
ENV DATABASE_URL=""
ENV AWS_REGION=us-east-1

# Expose port
EXPOSE 5000

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:5000/api/delivery/health || exit 1

# Set entrypoint to run Flask app with gunicorn
ENTRYPOINT ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--timeout", "60", "app:create_app()"]