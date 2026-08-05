pipeline {
    agent any

    options {
        timestamps()

        /*
         * Prevent two builds of this branch job from running simultaneously.
         * This reduces the risk of two builds trying to update the same
         * Kubernetes Deployment at the same time.
         */
        disableConcurrentBuilds()

        /*
         * Keep Jenkins storage usage under control.
         */
        buildDiscarder(
            logRotator(
                numToKeepStr: '20',
                daysToKeepStr: '30',
                artifactNumToKeepStr: '5'
            )
        )

        /*
         * Docker builds, ECR pushes, Fargate scheduling, and Kubernetes
         * rollouts can take time. Sixty minutes is safer than 45 minutes
         * for this training environment.
         */
        timeout(
            time: 60,
            unit: 'MINUTES'
        )

        /*
         * Checkout is performed explicitly in the Checkout stage.
         */
        skipDefaultCheckout(true)

        /*
         * Prevent Jenkins from automatically resuming this pipeline after
         * an unexpected Jenkins controller restart.
         */
        disableResume()
    }

    environment {
        /*
         * AWS and EKS configuration
         */
        AWS_REGION = 'ca-central-1'
        EKS_CLUSTER_NAME = 'java-mysql-eks'
        ECR_REPOSITORY_NAME = 'java-mysql-app'

        /*
         * Kubernetes application configuration
         */
        K8S_NAMESPACE = 'java-app'
        APP_NAME = 'java-app'
        APP_DEPLOYMENT = 'java-app'
        APP_SERVICE = 'java-app'
        APP_LABEL_SELECTOR = 'app.kubernetes.io/name=java-app'
        EXPECTED_REPLICAS = '3'

        /*
         * Docker Buildx configuration
         */
        BUILDX_BUILDER_NAME = 'jenkins-builder'
        TARGET_PLATFORM = 'linux/amd64'

        /*
         * These values are populated dynamically during main-branch builds.
         */
        AWS_ACCOUNT_ID = ''
        ECR_REGISTRY = ''
        ECR_REPO_URL = ''
        IMAGE_TAG = ''
        FULL_IMAGE_NAME = ''
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm

                sh '''
                    set -eu

                    echo "=========================================="
                    echo "Repository checkout information"
                    echo "=========================================="
                    echo "Branch: ${BRANCH_NAME:-unknown}"
                    echo "Commit: ${GIT_COMMIT:-unknown}"
                    echo "Build number: ${BUILD_NUMBER}"
                    echo

                    git status --short
                    git log -1 --oneline
                '''
            }
        }

        stage('Verify Repository Structure') {
            steps {
                sh '''
                    set -eu

                    echo "Validating required project files..."

                    REQUIRED_FILES="
                    gradlew
                    build.gradle
                    settings.gradle
                    Dockerfile
                    kubernetes/application/configmap.yaml
                    kubernetes/application/deployment.yaml
                    kubernetes/application/service.yaml
                    kubernetes/application/pdb.yaml
                    "

                    for FILE in ${REQUIRED_FILES}; do
                        if [ ! -f "${FILE}" ]; then
                            echo "ERROR: Required file is missing: ${FILE}" >&2
                            exit 1
                        fi

                        echo "PASS: ${FILE}"
                    done

                    if [ ! -d gradle/wrapper ]; then
                        echo "ERROR: Gradle Wrapper directory is missing." >&2
                        exit 1
                    fi

                    if [ ! -f gradle/wrapper/gradle-wrapper.jar ]; then
                        echo "ERROR: gradle-wrapper.jar is missing." >&2
                        exit 1
                    fi

                    if [ ! -f gradle/wrapper/gradle-wrapper.properties ]; then
                        echo "ERROR: gradle-wrapper.properties is missing." >&2
                        exit 1
                    fi

                    chmod +x gradlew

                    echo
                    echo "Repository structure validation passed."
                '''
            }
        }

        stage('Verify Tooling') {
            steps {
                sh '''
                    set -eu

                    echo "=========================================="
                    echo "Git"
                    echo "=========================================="
                    git --version

                    echo
                    echo "=========================================="
                    echo "Java"
                    echo "=========================================="
                    java --version

                    echo
                    echo "=========================================="
                    echo "Gradle Wrapper"
                    echo "=========================================="
                    ./gradlew --version

                    echo
                    echo "=========================================="
                    echo "Docker"
                    echo "=========================================="
                    docker --version
                    docker version \
                      --format 'Client={{.Client.Version}} Server={{.Server.Version}} Architecture={{.Server.Arch}}'

                    echo
                    echo "=========================================="
                    echo "Docker Buildx"
                    echo "=========================================="
                    docker buildx version

                    echo
                    echo "=========================================="
                    echo "AWS CLI"
                    echo "=========================================="
                    aws --version

                    echo
                    echo "=========================================="
                    echo "kubectl"
                    echo "=========================================="
                    kubectl version --client

                    echo
                    echo "=========================================="
                    echo "envsubst"
                    echo "=========================================="
                    envsubst --version

                    echo
                    echo "=========================================="
                    echo "curl"
                    echo "=========================================="
                    curl --version | head -n 1
                '''
            }
        }

        stage('Test Application') {
            steps {
                sh '''
                    set -eu

                    echo "Running Gradle tests..."

                    ./gradlew \
                      clean \
                      test \
                      --no-daemon \
                      --stacktrace

                    echo "Application tests completed successfully."
                '''
            }
        }

        /*
         * Feature branches stop after testing.
         *
         * develop and main also package the executable Spring Boot JAR.
         */
        stage('Package Application') {
            when {
                anyOf {
                    branch 'develop'
                    branch 'main'
                }
            }

            steps {
                sh '''
                    set -eu

                    echo "Creating the executable Spring Boot JAR..."

                    ./gradlew \
                      bootJar \
                      --no-daemon \
                      --stacktrace

                    echo
                    echo "Generated artifacts:"

                    find build/libs \
                      -maxdepth 1 \
                      -type f \
                      -print

                    if [ ! -f build/libs/application.jar ]; then
                        echo "ERROR: build/libs/application.jar was not created." >&2
                        exit 1
                    fi

                    echo
                    echo "Spring Boot package validation passed."
                '''
            }
        }

        /*
         * Validate that the Dockerfile still includes the security controls
         * required by the EKS Deployment.
         */
        stage('Validate Container Configuration') {
            when {
                anyOf {
                    branch 'develop'
                    branch 'main'
                }
            }

            steps {
                sh '''
                    set -eu

                    echo "Validating Dockerfile runtime configuration..."

                    grep -q 'FROM eclipse-temurin:17-jdk-jammy AS builder' \
                      Dockerfile

                    grep -q 'FROM eclipse-temurin:17-jre-jammy AS runtime' \
                      Dockerfile

                    grep -q 'ARG APP_UID=10001' \
                      Dockerfile

                    grep -q 'ARG APP_GID=10001' \
                      Dockerfile

                    grep -q 'USER 10001:10001' \
                      Dockerfile

                    grep -q 'ENTRYPOINT' \
                      Dockerfile

                    echo "Dockerfile validation passed."
                '''
            }
        }

        /*
         * All stages below run only for main.
         */
        stage('Prepare AWS and Image Metadata') {
            when {
                branch 'main'
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'jenkins-aws-access-key-id',
                        variable: 'AWS_ACCESS_KEY_ID'
                    ),
                    string(
                        credentialsId: 'jenkins-aws-secret-access-key',
                        variable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    script {
                        env.AWS_ACCOUNT_ID = sh(
                            script: '''
                                set -eu

                                aws sts get-caller-identity \
                                  --query Account \
                                  --output text
                            ''',
                            returnStdout: true
                        ).trim()

                        if (!env.AWS_ACCOUNT_ID?.trim()) {
                            error('AWS account ID could not be determined.')
                        }

                        env.ECR_REGISTRY =
                            "${env.AWS_ACCOUNT_ID}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"

                        env.ECR_REPO_URL =
                            "${env.ECR_REGISTRY}/${env.ECR_REPOSITORY_NAME}"

                        def shortCommit = env.GIT_COMMIT.take(7)

                        /*
                         * ECR tag immutability requires every build to use
                         * a new tag.
                         */
                        env.IMAGE_TAG =
                            "1.0.${env.BUILD_NUMBER}-${shortCommit}"

                        env.FULL_IMAGE_NAME =
                            "${env.ECR_REPO_URL}:${env.IMAGE_TAG}"

                        echo "AWS account identified successfully."
                        echo "AWS Region: ${env.AWS_REGION}"
                        echo "ECR repository: ${env.ECR_REPO_URL}"
                        echo "Image tag: ${env.IMAGE_TAG}"
                        echo "Target platform: ${env.TARGET_PLATFORM}"
                    }
                }
            }
        }

        stage('Validate AWS Resources') {
            when {
                branch 'main'
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'jenkins-aws-access-key-id',
                        variable: 'AWS_ACCESS_KEY_ID'
                    ),
                    string(
                        credentialsId: 'jenkins-aws-secret-access-key',
                        variable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh '''
                        set -eu

                        echo "Validating restricted Jenkins AWS identity..."

                        aws sts get-caller-identity \
                          --output table

                        echo
                        echo "Validating ECR repository..."

                        aws ecr describe-repositories \
                          --repository-names "${ECR_REPOSITORY_NAME}" \
                          --region "${AWS_REGION}" \
                          --query 'repositories[0].{
                            Name:repositoryName,
                            URI:repositoryUri,
                            TagMutability:imageTagMutability
                          }' \
                          --output table

                        echo
                        echo "Validating EKS cluster..."

                        aws eks describe-cluster \
                          --name "${EKS_CLUSTER_NAME}" \
                          --region "${AWS_REGION}" \
                          --query 'cluster.{
                            Name:name,
                            Status:status,
                            Version:version,
                            Endpoint:endpoint
                          }' \
                          --output table
                    '''
                }
            }
        }

        stage('Authenticate to Amazon ECR') {
            when {
                branch 'main'
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'jenkins-aws-access-key-id',
                        variable: 'AWS_ACCESS_KEY_ID'
                    ),
                    string(
                        credentialsId: 'jenkins-aws-secret-access-key',
                        variable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh '''
                        set -eu

                        echo "Authenticating Docker to Amazon ECR..."

                        aws ecr get-login-password \
                          --region "${AWS_REGION}" \
                        | docker login \
                            --username AWS \
                            --password-stdin \
                            "${ECR_REGISTRY}"

                        echo "Amazon ECR authentication succeeded."
                    '''
                }
            }
        }

        stage('Prepare Docker Buildx Builder') {
            when {
                branch 'main'
            }

            steps {
                sh '''
                    set -eu

                    echo "Preparing Docker Buildx builder..."

                    if docker buildx inspect "${BUILDX_BUILDER_NAME}" \
                      >/dev/null 2>&1
                    then
                        echo "Buildx builder already exists: ${BUILDX_BUILDER_NAME}"
                    else
                        docker buildx create \
                          --name "${BUILDX_BUILDER_NAME}" \
                          --driver docker-container
                    fi

                    docker buildx inspect \
                      "${BUILDX_BUILDER_NAME}" \
                      --bootstrap

                    echo
                    echo "Available Buildx builders:"

                    docker buildx ls
                '''
            }
        }

        stage('Build and Push AMD64 Image') {
            when {
                branch 'main'
            }

            steps {
                sh '''
                    set -eu

                    echo "Building and pushing immutable application image..."
                    echo "Image: ${FULL_IMAGE_NAME}"
                    echo "Platform: ${TARGET_PLATFORM}"

                    docker buildx build \
                      --builder "${BUILDX_BUILDER_NAME}" \
                      --platform "${TARGET_PLATFORM}" \
                      --build-arg APP_UID=10001 \
                      --build-arg APP_GID=10001 \
                      --label \
                        "org.opencontainers.image.revision=${GIT_COMMIT}" \
                      --label \
                        "org.opencontainers.image.version=${IMAGE_TAG}" \
                      --label \
                        "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                      --tag "${FULL_IMAGE_NAME}" \
                      --provenance=true \
                      --push \
                      .

                    echo "Container image build and push completed."
                '''
            }
        }

        stage('Verify Published ECR Image') {
            when {
                branch 'main'
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'jenkins-aws-access-key-id',
                        variable: 'AWS_ACCESS_KEY_ID'
                    ),
                    string(
                        credentialsId: 'jenkins-aws-secret-access-key',
                        variable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh '''
                        set -eu

                        echo "Verifying the published ECR image..."

                        aws ecr describe-images \
                          --repository-name "${ECR_REPOSITORY_NAME}" \
                          --image-ids imageTag="${IMAGE_TAG}" \
                          --region "${AWS_REGION}" \
                          --query 'imageDetails[0].{
                            Digest:imageDigest,
                            Tags:imageTags,
                            Pushed:imagePushedAt,
                            Size:imageSizeInBytes
                          }' \
                          --output table

                        echo
                        echo "Inspecting image platform metadata..."

                        docker buildx imagetools inspect \
                          "${FULL_IMAGE_NAME}"

                        if ! docker buildx imagetools inspect \
                          "${FULL_IMAGE_NAME}" \
                          | grep -q 'Platform:[[:space:]]*linux/amd64'
                        then
                            echo "ERROR: Published image does not contain linux/amd64." >&2
                            exit 1
                        fi

                        echo "Published image contains linux/amd64."
                    '''
                }
            }
        }

        stage('Configure EKS Access') {
            when {
                branch 'main'
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'jenkins-aws-access-key-id',
                        variable: 'AWS_ACCESS_KEY_ID'
                    ),
                    string(
                        credentialsId: 'jenkins-aws-secret-access-key',
                        variable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh '''
                        set -eu

                        echo "Creating a temporary workspace-scoped kubeconfig..."

                        mkdir -p "${WORKSPACE}/.kube"
                        chmod 700 "${WORKSPACE}/.kube"

                        export KUBECONFIG="${WORKSPACE}/.kube/config"

                        aws eks update-kubeconfig \
                          --name "${EKS_CLUSTER_NAME}" \
                          --region "${AWS_REGION}" \
                          --kubeconfig "${KUBECONFIG}" \
                          --alias "${EKS_CLUSTER_NAME}"

                        chmod 600 "${KUBECONFIG}"

                        echo
                        echo "Current Kubernetes context:"

                        kubectl config current-context

                        echo
                        echo "Validating namespace access..."

                        kubectl get namespace "${K8S_NAMESPACE}"

                        kubectl auth can-i get deployments \
                          --namespace "${K8S_NAMESPACE}" \
                          --quiet

                        kubectl auth can-i create deployments \
                          --namespace "${K8S_NAMESPACE}" \
                          --quiet

                        kubectl auth can-i patch deployments \
                          --namespace "${K8S_NAMESPACE}" \
                          --quiet

                        kubectl auth can-i create secrets \
                          --namespace "${K8S_NAMESPACE}" \
                          --quiet

                        kubectl auth can-i update secrets \
                          --namespace "${K8S_NAMESPACE}" \
                          --quiet

                        kubectl auth can-i get pods \
                          --namespace "${K8S_NAMESPACE}" \
                          --quiet

                        echo "EKS authorization checks passed."
                    '''
                }
            }
        }

        stage('Create or Update Application Secret') {
            when {
                branch 'main'
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'jenkins-aws-access-key-id',
                        variable: 'AWS_ACCESS_KEY_ID'
                    ),
                    string(
                        credentialsId: 'jenkins-aws-secret-access-key',
                        variable: 'AWS_SECRET_ACCESS_KEY'
                    ),
                    string(
                        credentialsId: 'java-db-user',
                        variable: 'DB_USER'
                    ),
                    string(
                        credentialsId: 'java-db-password',
                        variable: 'DB_PASSWORD'
                    )
                ]) {
                    sh '''
                        set -eu

                        export KUBECONFIG="${WORKSPACE}/.kube/config"

                        if [ -z "${DB_USER}" ]; then
                            echo "ERROR: DB_USER credential is empty." >&2
                            exit 1
                        fi

                        if [ -z "${DB_PASSWORD}" ]; then
                            echo "ERROR: DB_PASSWORD credential is empty." >&2
                            exit 1
                        fi

                        echo "Creating or updating java-app-secret..."

                        /*
                         * The Java application expects DB_USER and DB_PWD.
                         * The values are read from Jenkins credentials and
                         * are never written into the Git repository.
                         */
                        kubectl create secret generic java-app-secret \
                          --namespace "${K8S_NAMESPACE}" \
                          --from-literal=DB_USER="${DB_USER}" \
                          --from-literal=DB_PWD="${DB_PASSWORD}" \
                          --dry-run=client \
                          --output=yaml \
                        | kubectl apply -f -

                        kubectl get secret java-app-secret \
                          --namespace "${K8S_NAMESPACE}" \
                          --output=name

                        echo "Application Secret is present."
                    '''
                }
            }
        }

        stage('Render Kubernetes Deployment') {
            when {
                branch 'main'
            }

            steps {
                sh '''
                    set -eu

                    rm -rf rendered
                    mkdir -p rendered

                    export ECR_REPOSITORY_URL="${ECR_REPO_URL}"

                    echo "Rendering Kubernetes Deployment..."

                    envsubst \
                      '${ECR_REPOSITORY_URL} ${IMAGE_TAG}' \
                      < kubernetes/application/deployment.yaml \
                      > rendered/java-app-deployment.yaml

                    echo
                    echo "Rendered image reference:"

                    grep -n 'image:' \
                      rendered/java-app-deployment.yaml

                    if grep -nE \
                      'ECR_REPOSITORY_URL|IMAGE_TAG|YOUR_|PLACEHOLDER' \
                      rendered/java-app-deployment.yaml
                    then
                        echo "ERROR: Unresolved placeholders remain in the rendered Deployment." >&2
                        exit 1
                    fi

                    RENDERED_IMAGE="$(
                      grep -E '^[[:space:]]*image:' \
                        rendered/java-app-deployment.yaml \
                      | head -n 1 \
                      | sed -E 's/^[[:space:]]*image:[[:space:]]*"?([^"]+)"?$/\\1/'
                    )"

                    if [ "${RENDERED_IMAGE}" != "${FULL_IMAGE_NAME}" ]; then
                        echo "ERROR: Rendered image does not match expected image." >&2
                        echo "Expected: ${FULL_IMAGE_NAME}" >&2
                        echo "Found: ${RENDERED_IMAGE}" >&2
                        exit 1
                    fi

                    echo "Rendered Deployment validation passed."
                '''
            }
        }

        stage('Validate Kubernetes Manifests') {
            when {
                branch 'main'
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'jenkins-aws-access-key-id',
                        variable: 'AWS_ACCESS_KEY_ID'
                    ),
                    string(
                        credentialsId: 'jenkins-aws-secret-access-key',
                        variable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh '''
                        set -eu

                        export KUBECONFIG="${WORKSPACE}/.kube/config"

                        echo "Running Kubernetes client-side validation..."

                        kubectl apply \
                          --dry-run=client \
                          -f kubernetes/application/configmap.yaml \
                          -f kubernetes/application/service.yaml \
                          -f rendered/java-app-deployment.yaml \
                          -f kubernetes/application/pdb.yaml

                        echo
                        echo "Running Kubernetes server-side validation..."

                        kubectl apply \
                          --dry-run=server \
                          -f kubernetes/application/configmap.yaml \
                          -f kubernetes/application/service.yaml \
                          -f rendered/java-app-deployment.yaml \
                          -f kubernetes/application/pdb.yaml

                        echo "Kubernetes manifest validation passed."
                    '''
                }
            }
        }

        stage('Deploy to Amazon EKS') {
            when {
                branch 'main'
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'jenkins-aws-access-key-id',
                        variable: 'AWS_ACCESS_KEY_ID'
                    ),
                    string(
                        credentialsId: 'jenkins-aws-secret-access-key',
                        variable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh '''
                        set -eu

                        export KUBECONFIG="${WORKSPACE}/.kube/config"

                        echo "Applying application resources to Amazon EKS..."

                        kubectl apply \
                          -f kubernetes/application/configmap.yaml \
                          -f kubernetes/application/service.yaml \
                          -f rendered/java-app-deployment.yaml \
                          -f kubernetes/application/pdb.yaml

                        echo
                        echo "Waiting for Deployment rollout..."

                        kubectl rollout status \
                          "deployment/${APP_DEPLOYMENT}" \
                          --namespace "${K8S_NAMESPACE}" \
                          --timeout=600s

                        echo "Deployment rollout completed successfully."
                    '''
                }
            }
        }

        stage('Validate EKS Deployment') {
            when {
                branch 'main'
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'jenkins-aws-access-key-id',
                        variable: 'AWS_ACCESS_KEY_ID'
                    ),
                    string(
                        credentialsId: 'jenkins-aws-secret-access-key',
                        variable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh '''
                        set -eu

                        export KUBECONFIG="${WORKSPACE}/.kube/config"

                        echo "=========================================="
                        echo "Deployment"
                        echo "=========================================="

                        kubectl get deployment \
                          "${APP_DEPLOYMENT}" \
                          --namespace "${K8S_NAMESPACE}" \
                          -o wide

                        echo
                        echo "=========================================="
                        echo "Pods"
                        echo "=========================================="

                        kubectl get pods \
                          --namespace "${K8S_NAMESPACE}" \
                          --selector "${APP_LABEL_SELECTOR}" \
                          -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,PHASE:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,IMAGE:.spec.containers[0].image,NODE:.spec.nodeName'

                        echo
                        echo "=========================================="
                        echo "Service"
                        echo "=========================================="

                        kubectl get service \
                          "${APP_SERVICE}" \
                          --namespace "${K8S_NAMESPACE}" \
                          -o wide

                        echo
                        echo "=========================================="
                        echo "EndpointSlices"
                        echo "=========================================="

                        kubectl get endpointslice \
                          --namespace "${K8S_NAMESPACE}" \
                          --selector \
                            "kubernetes.io/service-name=${APP_SERVICE}" \
                          -o wide

                        AVAILABLE_REPLICAS="$(
                          kubectl get deployment \
                            "${APP_DEPLOYMENT}" \
                            --namespace "${K8S_NAMESPACE}" \
                            --output=jsonpath='{.status.availableReplicas}'
                        )"

                        UPDATED_REPLICAS="$(
                          kubectl get deployment \
                            "${APP_DEPLOYMENT}" \
                            --namespace "${K8S_NAMESPACE}" \
                            --output=jsonpath='{.status.updatedReplicas}'
                        )"

                        READY_REPLICAS="$(
                          kubectl get deployment \
                            "${APP_DEPLOYMENT}" \
                            --namespace "${K8S_NAMESPACE}" \
                            --output=jsonpath='{.status.readyReplicas}'
                        )"

                        if [ "${AVAILABLE_REPLICAS:-0}" -ne "${EXPECTED_REPLICAS}" ]; then
                            echo "ERROR: Available replica count is incorrect." >&2
                            echo "Expected: ${EXPECTED_REPLICAS}" >&2
                            echo "Found: ${AVAILABLE_REPLICAS:-0}" >&2
                            exit 1
                        fi

                        if [ "${UPDATED_REPLICAS:-0}" -ne "${EXPECTED_REPLICAS}" ]; then
                            echo "ERROR: Updated replica count is incorrect." >&2
                            echo "Expected: ${EXPECTED_REPLICAS}" >&2
                            echo "Found: ${UPDATED_REPLICAS:-0}" >&2
                            exit 1
                        fi

                        if [ "${READY_REPLICAS:-0}" -ne "${EXPECTED_REPLICAS}" ]; then
                            echo "ERROR: Ready replica count is incorrect." >&2
                            echo "Expected: ${EXPECTED_REPLICAS}" >&2
                            echo "Found: ${READY_REPLICAS:-0}" >&2
                            exit 1
                        fi

                        DEPLOYED_IMAGE="$(
                          kubectl get deployment \
                            "${APP_DEPLOYMENT}" \
                            --namespace "${K8S_NAMESPACE}" \
                            --output=jsonpath='{.spec.template.spec.containers[0].image}'
                        )"

                        if [ "${DEPLOYED_IMAGE}" != "${FULL_IMAGE_NAME}" ]; then
                            echo "ERROR: Unexpected image is deployed." >&2
                            echo "Expected: ${FULL_IMAGE_NAME}" >&2
                            echo "Found: ${DEPLOYED_IMAGE}" >&2
                            exit 1
                        fi

                        NON_RUNNING_PODS="$(
                          kubectl get pods \
                            --namespace "${K8S_NAMESPACE}" \
                            --selector "${APP_LABEL_SELECTOR}" \
                            --field-selector=status.phase!=Running \
                            --no-headers 2>/dev/null \
                          | wc -l \
                          | tr -d ' '
                        )"

                        if [ "${NON_RUNNING_PODS}" -ne 0 ]; then
                            echo "ERROR: One or more application pods are not Running." >&2
                            exit 1
                        fi

                        POD_COUNT="$(
                          kubectl get pods \
                            --namespace "${K8S_NAMESPACE}" \
                            --selector "${APP_LABEL_SELECTOR}" \
                            --no-headers \
                          | wc -l \
                          | tr -d ' '
                        )"

                        if [ "${POD_COUNT}" -ne "${EXPECTED_REPLICAS}" ]; then
                            echo "ERROR: Unexpected application pod count." >&2
                            echo "Expected: ${EXPECTED_REPLICAS}" >&2
                            echo "Found: ${POD_COUNT}" >&2
                            exit 1
                        fi

                        echo
                        echo "EKS deployment validation passed."
                        echo "Available replicas: ${AVAILABLE_REPLICAS}"
                        echo "Ready replicas: ${READY_REPLICAS}"
                        echo "Updated replicas: ${UPDATED_REPLICAS}"
                        echo "Deployed image: ${DEPLOYED_IMAGE}"
                    '''
                }
            }
        }

        stage('Test Application Endpoint') {
            when {
                branch 'main'
            }

            steps {
                withCredentials([
                    string(
                        credentialsId: 'jenkins-aws-access-key-id',
                        variable: 'AWS_ACCESS_KEY_ID'
                    ),
                    string(
                        credentialsId: 'jenkins-aws-secret-access-key',
                        variable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh '''
                        set -eu

                        export KUBECONFIG="${WORKSPACE}/.kube/config"

                        APP_HOSTNAME="$(
                          kubectl get service \
                            "${APP_SERVICE}" \
                            --namespace "${K8S_NAMESPACE}" \
                            --output=jsonpath='{.status.loadBalancer.ingress[0].hostname}'
                        )"

                        if [ -z "${APP_HOSTNAME}" ]; then
                            echo "ERROR: LoadBalancer hostname is unavailable." >&2
                            exit 1
                        fi

                        APP_URL="http://${APP_HOSTNAME}/"

                        echo "Testing application endpoint:"
                        echo "${APP_URL}"

                        HTTP_STATUS="$(
                          curl \
                            --silent \
                            --show-error \
                            --location \
                            --output /tmp/java-app-response.html \
                            --write-out '%{http_code}' \
                            --retry 12 \
                            --retry-delay 10 \
                            --retry-all-errors \
                            --connect-timeout 10 \
                            --max-time 30 \
                            "${APP_URL}"
                        )"

                        echo "HTTP status: ${HTTP_STATUS}"

                        case "${HTTP_STATUS}" in
                            200|201|202|204|301|302)
                                echo "Application endpoint validation passed."
                                ;;
                            *)
                                echo "ERROR: Application endpoint returned an unexpected status." >&2
                                echo "Status: ${HTTP_STATUS}" >&2

                                if [ -f /tmp/java-app-response.html ]; then
                                    echo "Response preview:"
                                    head -n 20 /tmp/java-app-response.html || true
                                fi

                                exit 1
                                ;;
                        esac

                        rm -f /tmp/java-app-response.html
                    '''
                }
            }
        }
    }

    post {
        always {
            script {
                sh '''
                    set +e

                    echo "Cleaning temporary pipeline resources..."

                    rm -rf "${WORKSPACE}/.kube"
                    rm -rf "${WORKSPACE}/rendered"
                    rm -f /tmp/java-app-response.html

                    if [ -n "${ECR_REGISTRY:-}" ]; then
                        docker logout "${ECR_REGISTRY}" || true
                    fi

                    echo "Temporary pipeline resources removed."
                '''
            }

            cleanWs(
                deleteDirs: true,
                notFailBuild: true,
                disableDeferredWipeout: true
            )
        }

        success {
            echo '''
Pipeline completed successfully.

Branch behavior:
- feature/*: tests only
- develop: tests and Spring Boot package validation
- main: complete ECR publishing and EKS deployment
'''
        }

        unstable {
            echo '''
Pipeline completed with an unstable result.
Review test results and Jenkins console output.
'''
        }

        failure {
            echo '''
Pipeline failed.

Review:
1. The failed Jenkins stage
2. Jenkins console output
3. Gradle test reports
4. Docker Buildx output
5. ECR authentication and permissions
6. EKS access-entry permissions
7. Kubernetes pod events and logs
'''
        }

        aborted {
            echo 'Pipeline was aborted before completion.'
        }
    }
}