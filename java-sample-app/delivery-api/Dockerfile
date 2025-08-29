# Build stage
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21 AS build

# Install Maven 3.9.6
RUN yum install -y wget tar gzip && \
    wget https://archive.apache.org/dist/maven/maven-3/3.9.6/binaries/apache-maven-3.9.6-bin.tar.gz -P /tmp && \
    tar xf /tmp/apache-maven-3.9.6-bin.tar.gz -C /opt && \
    ln -s /opt/apache-maven-3.9.6/bin/mvn /usr/bin/mvn && \
    rm /tmp/apache-maven-3.9.6-bin.tar.gz && \
    yum clean all

WORKDIR /workspace

# Copy the parent pom.xml and source code
COPY pom.xml .
COPY delivery-api/pom.xml delivery-api/
COPY delivery-api/src delivery-api/src

# Build the application
RUN mvn -f delivery-api/pom.xml package -DskipTests

# Run stage
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21

# Install curl for health check
RUN yum install -y curl && yum clean all

# Create non-root user
RUN yum install -y shadow-utils && \
    useradd -r -u 1000 -m appuser && \
    yum clean all

WORKDIR /app
COPY --from=build /workspace/delivery-api/target/*.jar delivery-api.jar

# Set ownership of the app directory
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:8080/actuator/health || exit 1

ENTRYPOINT ["java","-jar","/app/delivery-api.jar"]