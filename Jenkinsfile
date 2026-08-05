#!/usr/bin/env groovy

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 60, unit: 'MINUTES')
        buildDiscarder(
            logRotator(
                numToKeepStr: '20'
            )
        )
        skipDefaultCheckout(true)
    }

    environment {
        /*
         * AWS configuration
         */
        AWS_REGION = 'ca-central-1'
        EKS_CLUSTER_NAME = 'java-mysql-eks'
        ECR_REPOSITORY_NAME = 'java-mysql-app'

        /*
         * Kubernetes application configuration
         */
        APP_NAME = 'java-app'
        APP_NAMESPACE = 'java-app'
        APP_DEPLOYMENT = 'java-app'
        EXPECTED_REPLICAS = '3'

        /*
         * Docker configuration
         */
        DOCKER_BUILDER = 'jenkins-builder'
        TARGET_PLATFORM = 'linux/amd64'

        /*
         * Populated during the pipeline
         */
        AWS_ACCOUNT_ID = ''
        ECR_REGISTRY = ''
        IMAGE_REPOSITORY = ''
        IMAGE_TAG = ''
        FULL_IMAGE_NAME = ''
    }

    stages {
        stage('Checkout') {
            steps {
                script {
                    def checkoutDetails = checkout scm

                    env.GIT_COMMIT = checkoutDetails.GIT_COMMIT ?: sh(
                        script: 'git rev-parse HEAD',
                        returnStdout: true
                    ).trim()
                }

                sh '''
                    set -eu

                    echo "=========================================="
                    echo "Repository Information"
                    echo "=========================================="
                    echo "Branch: ${BRANCH_NAME}"
                    echo "Commit: ${GIT_COMMIT}"
                    echo "Build number: ${BUILD_NUMBER}"

                    git status --short
                    git log -1 --oneline

                    chmod +x gradlew
                '''
            }
        }

        stage('Verify Required Files') {
            steps {
                sh '''
                    set -eu

                    REQUIRED_FILES="
                    gradlew
                    gradle/wrapper/gradle-wrapper.jar
                    gradle/wrapper/gradle-wrapper.properties
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
                            echo "ERROR: Missing required file: ${FILE}" >&2
                            exit 1
                        fi

                        echo "PASS: ${FILE}"
                    done
                '''
            }
        }

        stage('Verify Tools') {
            steps {
                sh '''
                    set -eu

                    git --version
                    docker --version
                    docker buildx version
                    aws --version
                    kubectl version --client
                    envsubst --version
                '''
            }
        }

        /*
         * Run the Gradle build inside the same Java 17 builder image used
         * by the application Dockerfile.
         *
         * This avoids depending on the Java version installed in the
         * Jenkins controller container.
         */
        stage('Test Application') {
            steps {
                sh '''
                    set -eu

                    echo "Running Gradle tests with Java 17..."

                    echo "Jenkins workspace:"
                    echo "${WORKSPACE}"

                    test -f "${WORKSPACE}/gradlew"
                    test -f "${WORKSPACE}/gradle/wrapper/gradle-wrapper.jar"

                    docker run \
                      --rm \
                      --volumes-from jenkins \
                      --user "$(id -u):$(id -g)" \
                      --workdir "${WORKSPACE}" \
                      --env GRADLE_USER_HOME=/tmp/gradle-cache \
                      eclipse-temurin:17-jdk-jammy \
                      ./gradlew \
                        clean \
                        test \
                        --no-daemon \
                        --stacktrace
                '''
            }
        }

        /*
         * Feature and develop branches stop after validation.
         * Only main publishes and deploys.
         */
        stage('Prepare AWS Metadata') {
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

                        env.ECR_REGISTRY =
                            "${env.AWS_ACCOUNT_ID}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"

                        env.IMAGE_REPOSITORY =
                            "${env.ECR_REGISTRY}/${env.ECR_REPOSITORY_NAME}"

                        def shortCommit = env.GIT_COMMIT.take(7)

                        /*
                         * ECR image tags are immutable, so every Jenkins
                         * build receives a unique version.
                         */
                        env.IMAGE_TAG =
                            "1.0.${env.BUILD_NUMBER}-${shortCommit}"

                        env.FULL_IMAGE_NAME =
                            "${env.IMAGE_REPOSITORY}:${env.IMAGE_TAG}"

                        echo "AWS account: ${env.AWS_ACCOUNT_ID}"
                        echo "ECR repository: ${env.IMAGE_REPOSITORY}"
                        echo "Image tag: ${env.IMAGE_TAG}"
                    }
                }
            }
        }

        stage('Authenticate to ECR') {
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

                        aws ecr get-login-password \
                          --region "${AWS_REGION}" \
                        | docker login \
                            --username AWS \
                            --password-stdin \
                            "${ECR_REGISTRY}"
                    '''
                }
            }
        }

        stage('Build and Push Image') {
            when {
                branch 'main'
            }

            steps {
                sh '''
                    set -eu

                    if ! docker buildx inspect "${DOCKER_BUILDER}" \
                      >/dev/null 2>&1
                    then
                        docker buildx create \
                          --name "${DOCKER_BUILDER}" \
                          --driver docker-container
                    fi

                    docker buildx inspect \
                      "${DOCKER_BUILDER}" \
                      --bootstrap

                    echo "Building image: ${FULL_IMAGE_NAME}"

                    docker buildx build \
                      --builder "${DOCKER_BUILDER}" \
                      --platform "${TARGET_PLATFORM}" \
                      --build-arg APP_UID=10001 \
                      --build-arg APP_GID=10001 \
                      --tag "${FULL_IMAGE_NAME}" \
                      --push \
                      .
                '''
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

                        mkdir -p "${WORKSPACE}/.kube"
                        chmod 700 "${WORKSPACE}/.kube"

                        export KUBECONFIG="${WORKSPACE}/.kube/config"

                        aws eks update-kubeconfig \
                          --name "${EKS_CLUSTER_NAME}" \
                          --region "${AWS_REGION}" \
                          --kubeconfig "${KUBECONFIG}"

                        chmod 600 "${KUBECONFIG}"

                        kubectl get namespace "${APP_NAMESPACE}"

                        kubectl auth can-i get deployments \
                          --namespace "${APP_NAMESPACE}" \
                          --quiet

                        kubectl auth can-i patch deployments \
                          --namespace "${APP_NAMESPACE}" \
                          --quiet

                        kubectl auth can-i create secrets \
                          --namespace "${APP_NAMESPACE}" \
                          --quiet
                    '''
                }
            }
        }

        stage('Create Application Secret') {
            when {
                branch 'main'
            }

            environment {
                DB_USER_SECRET = credentials('java-db-user')
                DB_PASSWORD_SECRET = credentials('java-db-password')
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

                        /*
                         * Do not manually Base64-encode these values.
                         * kubectl create secret performs the encoding.
                         */
                        kubectl create secret generic java-app-secret \
                          --namespace "${APP_NAMESPACE}" \
                          --from-literal=DB_USER="${DB_USER_SECRET}" \
                          --from-literal=DB_PWD="${DB_PASSWORD_SECRET}" \
                          --dry-run=client \
                          --output=yaml \
                        | kubectl apply -f -
                    '''
                }
            }
        }

        stage('Render Deployment') {
            when {
                branch 'main'
            }

            steps {
                sh '''
                    set -eu

                    rm -rf rendered
                    mkdir -p rendered

                    export ECR_REPOSITORY_URL="${IMAGE_REPOSITORY}"

                    envsubst \
                      '${ECR_REPOSITORY_URL} ${IMAGE_TAG}' \
                      < kubernetes/application/deployment.yaml \
                      > rendered/java-app-deployment.yaml

                    if grep -nE \
                      'ECR_REPOSITORY_URL|IMAGE_TAG|YOUR_|PLACEHOLDER' \
                      rendered/java-app-deployment.yaml
                    then
                        echo "ERROR: Unresolved manifest placeholders remain." >&2
                        exit 1
                    fi

                    grep -n 'image:' \
                      rendered/java-app-deployment.yaml
                '''
            }
        }

        stage('Validate Manifests') {
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

                        kubectl apply \
                          --dry-run=server \
                          -f kubernetes/application/configmap.yaml \
                          -f kubernetes/application/service.yaml \
                          -f rendered/java-app-deployment.yaml \
                          -f kubernetes/application/pdb.yaml
                    '''
                }
            }
        }

        stage('Deploy to EKS') {
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

                        kubectl apply \
                          -f kubernetes/application/configmap.yaml \
                          -f kubernetes/application/service.yaml \
                          -f rendered/java-app-deployment.yaml \
                          -f kubernetes/application/pdb.yaml

                        kubectl rollout status \
                          "deployment/${APP_DEPLOYMENT}" \
                          --namespace "${APP_NAMESPACE}" \
                          --timeout=600s
                    '''
                }
            }
        }

        stage('Verify Deployment') {
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

                        kubectl get deployment \
                          "${APP_DEPLOYMENT}" \
                          --namespace "${APP_NAMESPACE}"

                        kubectl get pods \
                          --namespace "${APP_NAMESPACE}" \
                          --selector app.kubernetes.io/name="${APP_NAME}" \
                          -o wide

                        AVAILABLE_REPLICAS="$(
                          kubectl get deployment \
                            "${APP_DEPLOYMENT}" \
                            --namespace "${APP_NAMESPACE}" \
                            --output=jsonpath='{.status.availableReplicas}'
                        )"

                        if [ "${AVAILABLE_REPLICAS:-0}" -ne "${EXPECTED_REPLICAS}" ]; then
                            echo "ERROR: Expected ${EXPECTED_REPLICAS} replicas." >&2
                            echo "Available: ${AVAILABLE_REPLICAS:-0}" >&2
                            exit 1
                        fi

                        DEPLOYED_IMAGE="$(
                          kubectl get deployment \
                            "${APP_DEPLOYMENT}" \
                            --namespace "${APP_NAMESPACE}" \
                            --output=jsonpath='{.spec.template.spec.containers[0].image}'
                        )"

                        if [ "${DEPLOYED_IMAGE}" != "${FULL_IMAGE_NAME}" ]; then
                            echo "ERROR: Wrong image was deployed." >&2
                            echo "Expected: ${FULL_IMAGE_NAME}" >&2
                            echo "Found: ${DEPLOYED_IMAGE}" >&2
                            exit 1
                        fi

                        echo "Deployment verification passed."
                        echo "Replicas: ${AVAILABLE_REPLICAS}"
                        echo "Image: ${DEPLOYED_IMAGE}"
                    '''
                }
            }
        }
    }

    post {
        always {
            sh '''
                set +e

                rm -rf "${WORKSPACE}/.kube"
                rm -rf "${WORKSPACE}/rendered"

                if [ -n "${ECR_REGISTRY:-}" ]; then
                    docker logout "${ECR_REGISTRY}" || true
                fi
            '''

            cleanWs(
                deleteDirs: true,
                notFailBuild: true
            )
        }

        success {
            echo 'Java MySQL EKS CI/CD pipeline completed successfully.'
        }

        failure {
            echo 'Pipeline failed. Review the failed stage and Jenkins console output.'
        }
    }
}