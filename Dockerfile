# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------
# Stage 1: Build and test the Gradle application
# ---------------------------------------------------------
FROM eclipse-temurin:17-jdk-jammy AS builder

WORKDIR /workspace

# Copy Gradle Wrapper and build configuration first.
# This allows Docker to cache dependency-related layers.
COPY gradlew gradlew.bat ./
COPY gradle ./gradle
COPY build.gradle settings.gradle ./

RUN chmod +x gradlew

# Copy application source code.
COPY src ./src

# Build and test the Spring Boot application.
RUN ./gradlew clean test bootJar \
    --no-daemon \
    --stacktrace

# ---------------------------------------------------------
# Stage 2: Run the application
# ---------------------------------------------------------
FROM eclipse-temurin:17-jre-jammy AS runtime

LABEL org.opencontainers.image.title="Java MySQL EKS Application"
LABEL org.opencontainers.image.description="Spring Boot application deployed to Amazon EKS"
LABEL org.opencontainers.image.source="https://github.com/younghadiz/java-mysql-eks-platform"

# Create a dedicated, non-root service account.
RUN groupadd \
      --system \
      appgroup \
    && useradd \
      --system \
      --gid appgroup \
      --home-dir /opt/app \
      --shell /usr/sbin/nologin \
      appuser \
    && mkdir -p /opt/app \
    && chown -R appuser:appgroup /opt/app

WORKDIR /opt/app

# Copy only the executable Spring Boot JAR.
COPY --from=builder \
    --chown=appuser:appgroup \
    /workspace/build/libs/application.jar \
    /opt/app/application.jar

USER appuser

EXPOSE 8080

ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"

ENTRYPOINT ["sh", "-c", "exec java ${JAVA_OPTS} -jar /opt/app/application.jar"]