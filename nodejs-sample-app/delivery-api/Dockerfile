# Multi-stage build for Delivery API
# Stage 1: Build dependencies
FROM --platform=linux/amd64 node:18-alpine AS builder

# Set working directory
WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies (production only)
RUN npm ci --omit=dev && npm cache clean --force

# Stage 2: Runtime image
FROM --platform=linux/amd64 node:18-alpine AS runtime

# Install curl for health checks
RUN apk add --no-cache curl

# Create non-root user for security
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001 -G nodejs

# Set working directory
WORKDIR /app

# Copy node_modules from builder stage
COPY --from=builder /app/node_modules ./node_modules

# Copy application code with proper ownership
COPY --chown=nodejs:nodejs . .

# Switch to non-root user
USER nodejs

# Expose port
EXPOSE 5000

# Add health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:5000/api/delivery/health || exit 1

# Start the application with OpenTelemetry auto-instrumentation
CMD ["node", "--require", "@aws/aws-distro-opentelemetry-node-autoinstrumentation/register", "src/app.js"]