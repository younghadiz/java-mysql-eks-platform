#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================================
# Java Application Deployment Script
# ==========================================================
#
# This script deploys the Java Spring Boot application to
# Amazon EKS using an immutable image stored in Amazon ECR.
#
# Required:
#   - AWS CLI
#   - kubectl
#   - envsubst
#   - jq
#   - valid AWS credentials
#   - valid kubectl access to the EKS cluster
#
# Optional environment variables:
#   AWS_PROFILE
#   AWS_REGION
#   CLUSTER_NAME
#   ECR_REPOSITORY
#   IMAGE_TAG
#   APP_NAMESPACE
#   APP_DEPLOYMENT
#   APP_SERVICE
#   EXPECTED_REPLICAS
#   SKIP_ENDPOINT_TEST
#
# Example:
#
#   AWS_PROFILE=eks-admin \
#   IMAGE_TAG=1.0.12-8145ba5 \
#   ./scripts/deploy-java-app.sh
#
# ==========================================================

# ----------------------------------------------------------
# Default configuration
# ----------------------------------------------------------

AWS_PROFILE="${AWS_PROFILE:-eks-admin}"
AWS_REGION="${AWS_REGION:-ca-central-1}"
CLUSTER_NAME="${CLUSTER_NAME:-java-mysql-eks}"

ECR_REPOSITORY="${ECR_REPOSITORY:-java-mysql-app}"

APP_NAMESPACE="${APP_NAMESPACE:-java-app}"
APP_DEPLOYMENT="${APP_DEPLOYMENT:-java-app}"
APP_SERVICE="${APP_SERVICE:-java-app}"
EXPECTED_REPLICAS="${EXPECTED_REPLICAS:-3}"

SKIP_ENDPOINT_TEST="${SKIP_ENDPOINT_TEST:-false}"

PROJECT_ROOT="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd
)"

KUBERNETES_APPLICATION_DIR="${PROJECT_ROOT}/kubernetes/application"
RENDERED_DIR="${PROJECT_ROOT}/rendered"
RENDERED_DEPLOYMENT="${RENDERED_DIR}/java-app-deployment.yaml"

CONFIGMAP_MANIFEST="${KUBERNETES_APPLICATION_DIR}/configmap.yaml"
DEPLOYMENT_TEMPLATE="${KUBERNETES_APPLICATION_DIR}/deployment.yaml"
SERVICE_MANIFEST="${KUBERNETES_APPLICATION_DIR}/service.yaml"
PDB_MANIFEST="${KUBERNETES_APPLICATION_DIR}/pdb.yaml"

# ----------------------------------------------------------
# Output helpers
# ----------------------------------------------------------

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

success() {
  printf '[%s] SUCCESS: %s\n' "$(timestamp)" "$*"
}

warning() {
  printf '[%s] WARNING: %s\n' "$(timestamp)" "$*" >&2
}

fail() {
  printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >&2
  exit 1
}

cleanup() {
  if [[ -f "${RENDERED_DEPLOYMENT}" ]]; then
    log "Rendered Deployment retained at:"
    log "${RENDERED_DEPLOYMENT}"
  fi
}

trap cleanup EXIT

# ----------------------------------------------------------
# Command validation
# ----------------------------------------------------------

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    fail "Required command is not installed: ${command_name}"
  fi
}

require_file() {
  local file_path="$1"

  if [[ ! -f "${file_path}" ]]; then
    fail "Required file does not exist: ${file_path}"
  fi
}

log "Validating required command-line tools..."

for required_command in \
  aws \
  kubectl \
  envsubst \
  jq \
  grep \
  sed \
  curl
do
  require_command "${required_command}"
done

success "Required command-line tools are available."

# ----------------------------------------------------------
# Repository file validation
# ----------------------------------------------------------

log "Validating required Kubernetes manifests..."

for required_file in \
  "${CONFIGMAP_MANIFEST}" \
  "${DEPLOYMENT_TEMPLATE}" \
  "${SERVICE_MANIFEST}" \
  "${PDB_MANIFEST}"
do
  require_file "${required_file}"
done

success "Required Kubernetes manifests are available."

# ----------------------------------------------------------
# Input validation
# ----------------------------------------------------------

if [[ -z "${IMAGE_TAG:-}" ]]; then
  fail "IMAGE_TAG is required.

Example:

  IMAGE_TAG=1.0.12-8145ba5 \\
  ./scripts/deploy-java-app.sh"
fi

if [[ ! "${IMAGE_TAG}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  fail "IMAGE_TAG contains unsupported characters: ${IMAGE_TAG}"
fi

log "Deployment configuration:"
printf '  AWS profile:       %s\n' "${AWS_PROFILE}"
printf '  AWS region:        %s\n' "${AWS_REGION}"
printf '  EKS cluster:       %s\n' "${CLUSTER_NAME}"
printf '  ECR repository:    %s\n' "${ECR_REPOSITORY}"
printf '  Image tag:         %s\n' "${IMAGE_TAG}"
printf '  Namespace:         %s\n' "${APP_NAMESPACE}"
printf '  Deployment:        %s\n' "${APP_DEPLOYMENT}"
printf '  Expected replicas: %s\n' "${EXPECTED_REPLICAS}"

# ----------------------------------------------------------
# AWS identity validation
# ----------------------------------------------------------

log "Validating AWS identity..."

AWS_CALLER_IDENTITY="$(
  aws sts get-caller-identity \
    --profile "${AWS_PROFILE}" \
    --output json
)" || fail "Unable to retrieve AWS caller identity."

AWS_ACCOUNT_ID="$(
  jq -r '.Account' <<<"${AWS_CALLER_IDENTITY}"
)"

AWS_CALLER_ARN="$(
  jq -r '.Arn' <<<"${AWS_CALLER_IDENTITY}"
)"

if [[ -z "${AWS_ACCOUNT_ID}" || "${AWS_ACCOUNT_ID}" == "null" ]]; then
  fail "AWS account ID could not be determined."
fi

printf '  AWS account: %s\n' "${AWS_ACCOUNT_ID}"
printf '  AWS caller:  %s\n' "${AWS_CALLER_ARN}"

success "AWS identity validation passed."

# ----------------------------------------------------------
# EKS cluster validation
# ----------------------------------------------------------

log "Validating EKS cluster status..."

CLUSTER_STATUS="$(
  aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE}" \
    --query 'cluster.status' \
    --output text
)" || fail "Unable to describe EKS cluster ${CLUSTER_NAME}."

if [[ "${CLUSTER_STATUS}" != "ACTIVE" ]]; then
  fail "EKS cluster status is ${CLUSTER_STATUS}; expected ACTIVE."
fi

success "EKS cluster is ACTIVE."

# ----------------------------------------------------------
# Configure kubeconfig
# ----------------------------------------------------------

log "Updating kubeconfig for the target EKS cluster..."

aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --alias "${CLUSTER_NAME}" \
  >/dev/null

CURRENT_CONTEXT="$(
  kubectl config current-context
)"

printf '  kubectl context: %s\n' "${CURRENT_CONTEXT}"

success "kubeconfig was updated."

# ----------------------------------------------------------
# Kubernetes access validation
# ----------------------------------------------------------

log "Validating Kubernetes API access..."

kubectl get namespace "${APP_NAMESPACE}" \
  >/dev/null 2>&1 \
  || fail "Namespace ${APP_NAMESPACE} does not exist or is inaccessible."

for action in get create patch update
do
  if ! kubectl auth can-i "${action}" deployments \
    --namespace "${APP_NAMESPACE}" \
    | grep -qx "yes"
  then
    fail "Current Kubernetes identity cannot ${action} Deployments in ${APP_NAMESPACE}."
  fi
done

if ! kubectl auth can-i get secrets \
  --namespace "${APP_NAMESPACE}" \
  | grep -qx "yes"
then
  fail "Current Kubernetes identity cannot read Secret metadata in ${APP_NAMESPACE}."
fi

success "Kubernetes access validation passed."

# ----------------------------------------------------------
# Validate application Secret
# ----------------------------------------------------------

log "Checking application database Secret..."

if ! kubectl get secret java-app-secret \
  --namespace "${APP_NAMESPACE}" \
  >/dev/null 2>&1
then
  fail "Secret java-app-secret does not exist in namespace ${APP_NAMESPACE}.

Create it first:

  kubectl create secret generic java-app-secret \\
    --namespace ${APP_NAMESPACE} \\
    --from-literal=DB_USER=\"\${DB_USER}\" \\
    --from-literal=DB_PWD=\"\${DB_PASSWORD}\" \\
    --dry-run=client \\
    --output=yaml \\
  | kubectl apply -f -"
fi

SECRET_KEYS="$(
  kubectl get secret java-app-secret \
    --namespace "${APP_NAMESPACE}" \
    --output json \
  | jq -r '.data | keys[]'
)"

if ! grep -qx "DB_USER" <<<"${SECRET_KEYS}"; then
  fail "Secret java-app-secret does not contain DB_USER."
fi

if ! grep -qx "DB_PWD" <<<"${SECRET_KEYS}"; then
  fail "Secret java-app-secret does not contain DB_PWD."
fi

success "Application Secret exists with the required keys."

# ----------------------------------------------------------
# Locate ECR repository
# ----------------------------------------------------------

log "Resolving the Amazon ECR repository URI..."

ECR_REPOSITORY_URL="$(
  aws ecr describe-repositories \
    --repository-names "${ECR_REPOSITORY}" \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE}" \
    --query 'repositories[0].repositoryUri' \
    --output text
)" || fail "Unable to find ECR repository ${ECR_REPOSITORY}."

if [[ -z "${ECR_REPOSITORY_URL}" || "${ECR_REPOSITORY_URL}" == "None" ]]; then
  fail "ECR repository URI could not be determined."
fi

FULL_IMAGE_NAME="${ECR_REPOSITORY_URL}:${IMAGE_TAG}"

printf '  ECR repository URI: %s\n' "${ECR_REPOSITORY_URL}"
printf '  Full image name:    %s\n' "${FULL_IMAGE_NAME}"

# ----------------------------------------------------------
# Validate requested ECR image
# ----------------------------------------------------------

log "Confirming that the requested image exists in Amazon ECR..."

IMAGE_DIGEST="$(
  aws ecr describe-images \
    --repository-name "${ECR_REPOSITORY}" \
    --image-ids imageTag="${IMAGE_TAG}" \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE}" \
    --query 'imageDetails[0].imageDigest' \
    --output text
)" || fail "Image ${FULL_IMAGE_NAME} does not exist in ECR."

if [[ -z "${IMAGE_DIGEST}" || "${IMAGE_DIGEST}" == "None" ]]; then
  fail "No ECR image digest was returned for ${FULL_IMAGE_NAME}."
fi

printf '  Image digest: %s\n' "${IMAGE_DIGEST}"

success "Requested ECR image exists."

# ----------------------------------------------------------
# Render Deployment manifest
# ----------------------------------------------------------

log "Rendering the Kubernetes Deployment manifest..."

mkdir -p "${RENDERED_DIR}"

export ECR_REPOSITORY_URL
export IMAGE_TAG

envsubst \
  '${ECR_REPOSITORY_URL} ${IMAGE_TAG}' \
  < "${DEPLOYMENT_TEMPLATE}" \
  > "${RENDERED_DEPLOYMENT}"

# Ensure the rendered YAML ends with exactly one newline.
python3 - "${RENDERED_DEPLOYMENT}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text()
path.write_text(content.rstrip("\n") + "\n")
PY

if grep -nE \
  'ECR_REPOSITORY_URL|IMAGE_TAG|YOUR_|PLACEHOLDER' \
  "${RENDERED_DEPLOYMENT}"
then
  fail "Unresolved placeholders remain in ${RENDERED_DEPLOYMENT}."
fi

RENDERED_IMAGE="$(
  grep -E '^[[:space:]]*image:' "${RENDERED_DEPLOYMENT}" \
  | head -1 \
  | sed -E 's/^[[:space:]]*image:[[:space:]]*"?([^"]+)"?$/\1/'
)"

if [[ "${RENDERED_IMAGE}" != "${FULL_IMAGE_NAME}" ]]; then
  fail "Rendered image does not match the expected image.

Expected:
  ${FULL_IMAGE_NAME}

Rendered:
  ${RENDERED_IMAGE}"
fi

printf '  Rendered manifest: %s\n' "${RENDERED_DEPLOYMENT}"
printf '  Rendered image:    %s\n' "${RENDERED_IMAGE}"

success "Deployment manifest rendered successfully."

# ----------------------------------------------------------
# Client-side validation
# ----------------------------------------------------------

log "Running client-side Kubernetes manifest validation..."

kubectl apply \
  --dry-run=client \
  -f "${CONFIGMAP_MANIFEST}" \
  -f "${SERVICE_MANIFEST}" \
  -f "${RENDERED_DEPLOYMENT}" \
  -f "${PDB_MANIFEST}" \
  >/dev/null

success "Client-side validation passed."

# ----------------------------------------------------------
# Server-side validation
# ----------------------------------------------------------

log "Running server-side Kubernetes manifest validation..."

kubectl apply \
  --dry-run=server \
  -f "${CONFIGMAP_MANIFEST}" \
  -f "${SERVICE_MANIFEST}" \
  -f "${RENDERED_DEPLOYMENT}" \
  -f "${PDB_MANIFEST}" \
  >/dev/null

success "Server-side validation passed."

# ----------------------------------------------------------
# Deploy application
# ----------------------------------------------------------

log "Applying Java application manifests..."

kubectl apply \
  -f "${CONFIGMAP_MANIFEST}" \
  -f "${SERVICE_MANIFEST}" \
  -f "${RENDERED_DEPLOYMENT}" \
  -f "${PDB_MANIFEST}"

success "Application manifests were applied."

# ----------------------------------------------------------
# Wait for rollout
# ----------------------------------------------------------

log "Waiting for Java application rollout..."

if ! kubectl rollout status \
  "deployment/${APP_DEPLOYMENT}" \
  --namespace "${APP_NAMESPACE}" \
  --timeout=600s
then
  warning "Deployment rollout failed."

  kubectl get deployment,replicaset,pods \
    --namespace "${APP_NAMESPACE}" \
    -o wide \
    || true

  kubectl describe deployment "${APP_DEPLOYMENT}" \
    --namespace "${APP_NAMESPACE}" \
    || true

  kubectl get events \
    --namespace "${APP_NAMESPACE}" \
    --sort-by='.lastTimestamp' \
    | tail -50 \
    || true

  fail "Java application rollout did not complete successfully."
fi

success "Java application rollout completed."

# ----------------------------------------------------------
# Validate replica status
# ----------------------------------------------------------

log "Validating Deployment replica status..."

DESIRED_REPLICAS="$(
  kubectl get deployment "${APP_DEPLOYMENT}" \
    --namespace "${APP_NAMESPACE}" \
    --output=jsonpath='{.spec.replicas}'
)"

UPDATED_REPLICAS="$(
  kubectl get deployment "${APP_DEPLOYMENT}" \
    --namespace "${APP_NAMESPACE}" \
    --output=jsonpath='{.status.updatedReplicas}'
)"

AVAILABLE_REPLICAS="$(
  kubectl get deployment "${APP_DEPLOYMENT}" \
    --namespace "${APP_NAMESPACE}" \
    --output=jsonpath='{.status.availableReplicas}'
)"

READY_REPLICAS="$(
  kubectl get deployment "${APP_DEPLOYMENT}" \
    --namespace "${APP_NAMESPACE}" \
    --output=jsonpath='{.status.readyReplicas}'
)"

printf '  Desired replicas:   %s\n' "${DESIRED_REPLICAS:-0}"
printf '  Updated replicas:   %s\n' "${UPDATED_REPLICAS:-0}"
printf '  Available replicas: %s\n' "${AVAILABLE_REPLICAS:-0}"
printf '  Ready replicas:     %s\n' "${READY_REPLICAS:-0}"

if [[ "${DESIRED_REPLICAS:-0}" -ne "${EXPECTED_REPLICAS}" ]]; then
  fail "Expected desired replicas ${EXPECTED_REPLICAS}; found ${DESIRED_REPLICAS:-0}."
fi

if [[ "${UPDATED_REPLICAS:-0}" -ne "${EXPECTED_REPLICAS}" ]]; then
  fail "Expected updated replicas ${EXPECTED_REPLICAS}; found ${UPDATED_REPLICAS:-0}."
fi

if [[ "${AVAILABLE_REPLICAS:-0}" -ne "${EXPECTED_REPLICAS}" ]]; then
  fail "Expected available replicas ${EXPECTED_REPLICAS}; found ${AVAILABLE_REPLICAS:-0}."
fi

if [[ "${READY_REPLICAS:-0}" -ne "${EXPECTED_REPLICAS}" ]]; then
  fail "Expected ready replicas ${EXPECTED_REPLICAS}; found ${READY_REPLICAS:-0}."
fi

success "All ${EXPECTED_REPLICAS} application replicas are available."

# ----------------------------------------------------------
# Validate deployed image
# ----------------------------------------------------------

log "Validating the image configured on the live Deployment..."

DEPLOYED_IMAGE="$(
  kubectl get deployment "${APP_DEPLOYMENT}" \
    --namespace "${APP_NAMESPACE}" \
    --output=jsonpath='{.spec.template.spec.containers[0].image}'
)"

printf '  Expected image: %s\n' "${FULL_IMAGE_NAME}"
printf '  Deployed image: %s\n' "${DEPLOYED_IMAGE}"

if [[ "${DEPLOYED_IMAGE}" != "${FULL_IMAGE_NAME}" ]]; then
  fail "The deployed image does not match the expected ECR image."
fi

success "The expected ECR image is deployed."

# ----------------------------------------------------------
# Validate Fargate scheduling and Pod status
# ----------------------------------------------------------

log "Validating Java application Pods..."

kubectl get pods \
  --namespace "${APP_NAMESPACE}" \
  --selector app.kubernetes.io/name=java-app \
  -o wide

POD_COUNT="$(
  kubectl get pods \
    --namespace "${APP_NAMESPACE}" \
    --selector app.kubernetes.io/name=java-app \
    --output=json \
  | jq '.items | length'
)"

RUNNING_POD_COUNT="$(
  kubectl get pods \
    --namespace "${APP_NAMESPACE}" \
    --selector app.kubernetes.io/name=java-app \
    --output=json \
  | jq '[.items[] | select(.status.phase == "Running")] | length'
)"

READY_POD_COUNT="$(
  kubectl get pods \
    --namespace "${APP_NAMESPACE}" \
    --selector app.kubernetes.io/name=java-app \
    --output=json \
  | jq '[
      .items[]
      | select(
          .status.containerStatuses != null
          and all(.status.containerStatuses[]; .ready == true)
        )
    ] | length'
)"

FARGATE_POD_COUNT="$(
  kubectl get pods \
    --namespace "${APP_NAMESPACE}" \
    --selector app.kubernetes.io/name=java-app \
    --output=json \
  | jq '[
      .items[]
      | select(
          .spec.nodeName != null
          and (.spec.nodeName | startswith("fargate-"))
        )
    ] | length'
)"

printf '  Total Pods:          %s\n' "${POD_COUNT}"
printf '  Running Pods:        %s\n' "${RUNNING_POD_COUNT}"
printf '  Ready Pods:          %s\n' "${READY_POD_COUNT}"
printf '  Fargate-backed Pods: %s\n' "${FARGATE_POD_COUNT}"

if [[ "${POD_COUNT}" -ne "${EXPECTED_REPLICAS}" ]]; then
  fail "Expected ${EXPECTED_REPLICAS} Java Pods; found ${POD_COUNT}."
fi

if [[ "${RUNNING_POD_COUNT}" -ne "${EXPECTED_REPLICAS}" ]]; then
  fail "Expected ${EXPECTED_REPLICAS} Running Pods; found ${RUNNING_POD_COUNT}."
fi

if [[ "${READY_POD_COUNT}" -ne "${EXPECTED_REPLICAS}" ]]; then
  fail "Expected ${EXPECTED_REPLICAS} Ready Pods; found ${READY_POD_COUNT}."
fi

if [[ "${FARGATE_POD_COUNT}" -ne "${EXPECTED_REPLICAS}" ]]; then
  fail "Expected ${EXPECTED_REPLICAS} Fargate-backed Pods; found ${FARGATE_POD_COUNT}."
fi

success "All Java application Pods are healthy and running on Fargate."

# ----------------------------------------------------------
# Validate container user
# ----------------------------------------------------------

log "Validating that the Java container runs as a non-root user..."

JAVA_APP_POD="$(
  kubectl get pods \
    --namespace "${APP_NAMESPACE}" \
    --selector app.kubernetes.io/name=java-app \
    --output=jsonpath='{.items[0].metadata.name}'
)"

CONTAINER_IDENTITY="$(
  kubectl exec \
    --namespace "${APP_NAMESPACE}" \
    "${JAVA_APP_POD}" \
    -- id
)"

printf '  Container identity: %s\n' "${CONTAINER_IDENTITY}"

if grep -q 'uid=0(root)' <<<"${CONTAINER_IDENTITY}"; then
  fail "The Java application container is running as root."
fi

success "The Java application container is running as a non-root user."

# ----------------------------------------------------------
# Validate Service and endpoint
# ----------------------------------------------------------

log "Validating the Java application Service..."

kubectl get service "${APP_SERVICE}" \
  --namespace "${APP_NAMESPACE}" \
  -o wide

APP_HOST="$(
  kubectl get service "${APP_SERVICE}" \
    --namespace "${APP_NAMESPACE}" \
    --output=jsonpath='{.status.loadBalancer.ingress[0].hostname}'
)"

if [[ -z "${APP_HOST}" ]]; then
  warning "The LoadBalancer hostname is not available yet."
  warning "The Kubernetes deployment itself completed successfully."
elif [[ "${SKIP_ENDPOINT_TEST}" == "true" ]]; then
  warning "Endpoint test skipped because SKIP_ENDPOINT_TEST=true."
else
  printf '  Application hostname: %s\n' "${APP_HOST}"

  log "Testing the application endpoint..."

  HTTP_STATUS="$(
    curl \
      --silent \
      --show-error \
      --output /dev/null \
      --write-out '%{http_code}' \
      --retry 10 \
      --retry-delay 10 \
      --retry-connrefused \
      --connect-timeout 10 \
      --max-time 30 \
      "http://${APP_HOST}/" \
      || true
  )"

  printf '  HTTP status: %s\n' "${HTTP_STATUS:-unavailable}"

  if [[ "${HTTP_STATUS}" != "200" ]]; then
    fail "Application endpoint returned HTTP ${HTTP_STATUS:-unavailable}; expected 200."
  fi

  success "Application endpoint returned HTTP 200."
fi

# ----------------------------------------------------------
# Final summary
# ----------------------------------------------------------

echo
echo "=========================================================="
echo "Java Application Deployment Successful"
echo "=========================================================="
printf 'Cluster:             %s\n' "${CLUSTER_NAME}"
printf 'Region:              %s\n' "${AWS_REGION}"
printf 'Namespace:           %s\n' "${APP_NAMESPACE}"
printf 'Deployment:          %s\n' "${APP_DEPLOYMENT}"
printf 'Available replicas:  %s\n' "${AVAILABLE_REPLICAS}"
printf 'Image:               %s\n' "${FULL_IMAGE_NAME}"
printf 'Image digest:        %s\n' "${IMAGE_DIGEST}"

if [[ -n "${APP_HOST}" ]]; then
  printf 'Application URL:     http://%s\n' "${APP_HOST}"
fi

echo "=========================================================="