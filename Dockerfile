# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------
# Stage 1: Build and test the Gradle application
# ---------------------------------------------------------
FROM eclipse-temurin:17-jdk-jammy AS builder

WORKDIR /workspace

# Copy Gradle Wrapper and build configuration first.
# This improves Docker layer caching for dependencies.
COPY gradlew gradlew.bat ./
COPY gradle ./gradle
COPY build.gradle settings.gradle ./

RUN chmod +x gradlew

# Copy application source code.
COPY src ./src

# Build, test, and package the Spring Boot application.
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

# Fixed numeric IDs allow Kubernetes to verify that the
# container is running as a non-root user.
ARG APP_UID=10001
ARG APP_GID=10001

# Create a dedicated non-root runtime account.
RUN groupadd \
      --gid "${APP_GID}" \
      appgroup \
    && useradd \
      --uid "${APP_UID}" \
      --gid "${APP_GID}" \
      --no-create-home \
      --home-dir /nonexistent \
      --shell /usr/sbin/nologin \
      appuser \
    && mkdir -p /opt/app \
    && chown "${APP_UID}:${APP_GID}" /opt/app

WORKDIR /opt/app

# Copy only the executable Spring Boot JAR.
# Numeric ownership remains consistent with the Kubernetes
# runAsUser and runAsGroup configuration.
COPY --from=builder \
    --chown=10001:10001 \
    /workspace/build/libs/application.jar \
    /opt/app/application.jar

# Run using explicit numeric UID and GID.
USER 10001:10001

EXPOSE 8080

ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"

ENTRYPOINT ["sh", "-c", "exec java ${JAVA_OPTS} -jar /opt/app/application.jar"]