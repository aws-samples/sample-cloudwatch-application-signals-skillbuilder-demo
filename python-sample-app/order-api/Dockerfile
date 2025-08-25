# Build stage
FROM python:3.12-slim AS build

# Install build dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        curl && \
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

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl && \
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
ENV SERVICE_NAME=order-api
ENV SERVICE_VERSION=1.0.0

# Expose port
EXPOSE 8080

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/api/orders/health || exit 1

# Set entrypoint to run FastAPI with uvicorn
ENTRYPOINT ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]