# Build stage
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21 AS build

# Install Maven
RUN yum install -y maven && yum clean all

WORKDIR /workspace

# Copy the parent pom.xml and source code
COPY pom.xml .
COPY order-api/pom.xml order-api/
COPY order-api/src order-api/src

# Build the application
RUN mvn -f order-api/pom.xml package -DskipTests

# Run stage
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21

# Install curl for health check
RUN yum install -y curl && yum clean all

# Create non-root user
RUN yum install -y shadow-utils && \
    useradd -r -u 1000 -m appuser && \
    yum clean all

WORKDIR /app
COPY --from=build /workspace/order-api/target/*.jar order-api.jar

# Set ownership of the app directory
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:8080/actuator/health || exit 1

ENTRYPOINT ["java","-jar","/app/order-api.jar"]
