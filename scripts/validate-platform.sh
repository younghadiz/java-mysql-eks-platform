#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================================
# Java MySQL EKS Platform Validation Script
# ==========================================================
#
# This script validates:
#
# 1. AWS identity
# 2. EKS cluster status
# 3. kubectl connectivity
# 4. EC2 managed node group
# 5. Fargate profile
# 6. Java application Deployment and Fargate scheduling
# 7. MySQL StatefulSets and Pods
# 8. MySQL persistent storage
# 9. MySQL replication
# 10. Kubernetes LoadBalancer Service
# 11. Public application response
# 12. Cluster Autoscaler Deployment
# 13. Managed node group autoscaling range
#
# Default project values can be overridden through environment
# variables when running this script.
# ==========================================================

CLUSTER_NAME="${CLUSTER_NAME:-java-mysql-eks}"
AWS_REGION="${AWS_REGION:-ca-central-1}"
AWS_PROFILE="${AWS_PROFILE:-eks-admin}"

NODEGROUP_NAME="${NODEGROUP_NAME:-application-nodes}"
FARGATE_PROFILE_NAME="${FARGATE_PROFILE_NAME:-java-app-fargate}"

JAVA_NAMESPACE="${JAVA_NAMESPACE:-java-app}"
JAVA_DEPLOYMENT="${JAVA_DEPLOYMENT:-java-app}"
JAVA_SERVICE="${JAVA_SERVICE:-java-app}"
EXPECTED_JAVA_REPLICAS="${EXPECTED_JAVA_REPLICAS:-3}"

DATABASE_NAMESPACE="${DATABASE_NAMESPACE:-database}"
MYSQL_PRIMARY_STATEFULSET="${MYSQL_PRIMARY_STATEFULSET:-mysql-primary}"
MYSQL_SECONDARY_STATEFULSET="${MYSQL_SECONDARY_STATEFULSET:-mysql-secondary}"
EXPECTED_MYSQL_PRIMARY_REPLICAS="${EXPECTED_MYSQL_PRIMARY_REPLICAS:-1}"
EXPECTED_MYSQL_SECONDARY_REPLICAS="${EXPECTED_MYSQL_SECONDARY_REPLICAS:-2}"

EXPECTED_NODEGROUP_MIN_SIZE="${EXPECTED_NODEGROUP_MIN_SIZE:-1}"
EXPECTED_NODEGROUP_MAX_SIZE="${EXPECTED_NODEGROUP_MAX_SIZE:-3}"

HTTP_TIMEOUT_SECONDS="${HTTP_TIMEOUT_SECONDS:-30}"

# Build reusable AWS CLI arguments.
AWS_ARGS=(
  --region "${AWS_REGION}"
)

if [[ -n "${AWS_PROFILE}" ]]; then
  AWS_ARGS+=(
    --profile "${AWS_PROFILE}"
  )
fi

fail() {
  local message="${1:-Unknown validation error}"

  echo
  echo "=========================================================="
  echo "VALIDATION FAILED"
  echo "=========================================================="
  echo "${message}"
  echo "=========================================================="

  exit 1
}

pass() {
  local message="${1:-Validation passed}"

  echo "PASS: ${message}"
}

section() {
  local number="${1}"
  local title="${2}"

  echo
  echo "=========================================================="
  echo "${number}. ${title}"
  echo "=========================================================="
}

handle_error() {
  local exit_code=$?
  local line_number="${1:-unknown}"

  echo
  echo "ERROR: Validation script failed unexpectedly."
  echo "Line: ${line_number}"
  echo "Exit code: ${exit_code}"

  exit "${exit_code}"
}

trap 'handle_error "${LINENO}"' ERR

# ==========================================================
# 1. Validate AWS identity
# ==========================================================

section "1" "Validating AWS identity"

AWS_ACCOUNT_ID="$(
  aws sts get-caller-identity \
    "${AWS_ARGS[@]}" \
    --query 'Account' \
    --output text
)"

AWS_CALLER_ARN="$(
  aws sts get-caller-identity \
    "${AWS_ARGS[@]}" \
    --query 'Arn' \
    --output text
)"

[[ -n "${AWS_ACCOUNT_ID}" ]] \
  || fail "AWS account ID could not be determined."

[[ "${AWS_ACCOUNT_ID}" != "None" ]] \
  || fail "AWS account ID returned None."

echo "AWS account: ${AWS_ACCOUNT_ID}"
echo "AWS caller: ${AWS_CALLER_ARN}"

pass "AWS identity is available."

# ==========================================================
# 2. Validate EKS cluster
# ==========================================================

section "2" "Validating EKS cluster"

CLUSTER_STATUS="$(
  aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    "${AWS_ARGS[@]}" \
    --query 'cluster.status' \
    --output text
)"

CLUSTER_VERSION="$(
  aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    "${AWS_ARGS[@]}" \
    --query 'cluster.version' \
    --output text
)"

[[ "${CLUSTER_STATUS}" == "ACTIVE" ]] \
  || fail "EKS cluster status is ${CLUSTER_STATUS}; expected ACTIVE."

echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo "Status: ${CLUSTER_STATUS}"
echo "Kubernetes version: ${CLUSTER_VERSION}"

pass "EKS cluster is ACTIVE."

# ==========================================================
# 3. Validate kubectl context and connectivity
# ==========================================================

section "3" "Validating kubectl context and API connectivity"

CURRENT_CONTEXT="$(
  kubectl config current-context
)"

[[ -n "${CURRENT_CONTEXT}" ]] \
  || fail "No active kubectl context was found."

echo "Current context: ${CURRENT_CONTEXT}"

kubectl cluster-info >/dev/null \
  || fail "kubectl cannot connect to the EKS API server."

pass "kubectl can reach the EKS cluster."

# ==========================================================
# 4. Validate EC2 managed nodes
# ==========================================================

section "4" "Validating EC2 managed nodes"

READY_EC2_NODES="$(
  kubectl get nodes \
    -l "eks.amazonaws.com/nodegroup=${NODEGROUP_NAME}" \
    --no-headers \
    2>/dev/null \
  | awk '$2 == "Ready" { count++ } END { print count+0 }'
)"

[[ "${READY_EC2_NODES}" -ge 1 ]] \
  || fail "No Ready EC2 nodes were found for node group ${NODEGROUP_NAME}."

kubectl get nodes \
  -l "eks.amazonaws.com/nodegroup=${NODEGROUP_NAME}" \
  -o wide

echo "Ready EC2 nodes: ${READY_EC2_NODES}"

pass "At least one managed EC2 node is Ready."

# ==========================================================
# 5. Validate Fargate profile
# ==========================================================

section "5" "Validating Fargate profile"

FARGATE_STATUS="$(
  aws eks describe-fargate-profile \
    --cluster-name "${CLUSTER_NAME}" \
    --fargate-profile-name "${FARGATE_PROFILE_NAME}" \
    "${AWS_ARGS[@]}" \
    --query 'fargateProfile.status' \
    --output text
)"

[[ "${FARGATE_STATUS}" == "ACTIVE" ]] \
  || fail \
    "Fargate profile ${FARGATE_PROFILE_NAME} status is ${FARGATE_STATUS}; expected ACTIVE."

echo "Fargate profile: ${FARGATE_PROFILE_NAME}"
echo "Status: ${FARGATE_STATUS}"

pass "Fargate profile is ACTIVE."

# ==========================================================
# 6. Validate Java application
# ==========================================================

section "6" "Validating Java application Deployment"

kubectl rollout status \
  "deployment/${JAVA_DEPLOYMENT}" \
  --namespace "${JAVA_NAMESPACE}" \
  --timeout=600s

DESIRED_JAVA_REPLICAS="$(
  kubectl get deployment "${JAVA_DEPLOYMENT}" \
    --namespace "${JAVA_NAMESPACE}" \
    --output=jsonpath='{.spec.replicas}'
)"

AVAILABLE_JAVA_REPLICAS="$(
  kubectl get deployment "${JAVA_DEPLOYMENT}" \
    --namespace "${JAVA_NAMESPACE}" \
    --output=jsonpath='{.status.availableReplicas}'
)"

UPDATED_JAVA_REPLICAS="$(
  kubectl get deployment "${JAVA_DEPLOYMENT}" \
    --namespace "${JAVA_NAMESPACE}" \
    --output=jsonpath='{.status.updatedReplicas}'
)"

DESIRED_JAVA_REPLICAS="${DESIRED_JAVA_REPLICAS:-0}"
AVAILABLE_JAVA_REPLICAS="${AVAILABLE_JAVA_REPLICAS:-0}"
UPDATED_JAVA_REPLICAS="${UPDATED_JAVA_REPLICAS:-0}"

[[ "${DESIRED_JAVA_REPLICAS}" -eq "${EXPECTED_JAVA_REPLICAS}" ]] \
  || fail \
    "Expected ${EXPECTED_JAVA_REPLICAS} desired Java replicas; found ${DESIRED_JAVA_REPLICAS}."

[[ "${AVAILABLE_JAVA_REPLICAS}" -eq "${EXPECTED_JAVA_REPLICAS}" ]] \
  || fail \
    "Expected ${EXPECTED_JAVA_REPLICAS} available Java replicas; found ${AVAILABLE_JAVA_REPLICAS}."

[[ "${UPDATED_JAVA_REPLICAS}" -eq "${EXPECTED_JAVA_REPLICAS}" ]] \
  || fail \
    "Expected ${EXPECTED_JAVA_REPLICAS} updated Java replicas; found ${UPDATED_JAVA_REPLICAS}."

kubectl get deployment "${JAVA_DEPLOYMENT}" \
  --namespace "${JAVA_NAMESPACE}" \
  -o wide

kubectl get pods \
  --namespace "${JAVA_NAMESPACE}" \
  -l app.kubernetes.io/name=java-app \
  -o wide

pass "Java Deployment has ${EXPECTED_JAVA_REPLICAS} available replicas."

# ==========================================================
# 7. Validate Java Fargate scheduling
# ==========================================================

section "7" "Validating Java application Fargate scheduling"

JAVA_POD_COUNT="$(
  kubectl get pods \
    --namespace "${JAVA_NAMESPACE}" \
    -l app.kubernetes.io/name=java-app \
    --no-headers \
  | wc -l \
  | tr -d ' '
)"

FARGATE_SCHEDULED_PODS="$(
  kubectl get pods \
    --namespace "${JAVA_NAMESPACE}" \
    -l app.kubernetes.io/name=java-app \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | grep -c '^fargate-' \
  || true
)"

[[ "${JAVA_POD_COUNT}" -eq "${EXPECTED_JAVA_REPLICAS}" ]] \
  || fail \
    "Expected ${EXPECTED_JAVA_REPLICAS} Java Pods; found ${JAVA_POD_COUNT}."

[[ "${FARGATE_SCHEDULED_PODS}" -eq "${EXPECTED_JAVA_REPLICAS}" ]] \
  || fail \
    "Expected all ${EXPECTED_JAVA_REPLICAS} Java Pods on Fargate; found ${FARGATE_SCHEDULED_PODS}."

echo "Java Pods: ${JAVA_POD_COUNT}"
echo "Java Pods scheduled on Fargate: ${FARGATE_SCHEDULED_PODS}"

pass "All Java application Pods run on Fargate."

# ==========================================================
# 8. Validate MySQL StatefulSets and Pods
# ==========================================================

section "8" "Validating MySQL StatefulSets"

PRIMARY_DESIRED="$(
  kubectl get statefulset "${MYSQL_PRIMARY_STATEFULSET}" \
    --namespace "${DATABASE_NAMESPACE}" \
    --output=jsonpath='{.spec.replicas}'
)"

PRIMARY_READY="$(
  kubectl get statefulset "${MYSQL_PRIMARY_STATEFULSET}" \
    --namespace "${DATABASE_NAMESPACE}" \
    --output=jsonpath='{.status.readyReplicas}'
)"

SECONDARY_DESIRED="$(
  kubectl get statefulset "${MYSQL_SECONDARY_STATEFULSET}" \
    --namespace "${DATABASE_NAMESPACE}" \
    --output=jsonpath='{.spec.replicas}'
)"

SECONDARY_READY="$(
  kubectl get statefulset "${MYSQL_SECONDARY_STATEFULSET}" \
    --namespace "${DATABASE_NAMESPACE}" \
    --output=jsonpath='{.status.readyReplicas}'
)"

PRIMARY_DESIRED="${PRIMARY_DESIRED:-0}"
PRIMARY_READY="${PRIMARY_READY:-0}"
SECONDARY_DESIRED="${SECONDARY_DESIRED:-0}"
SECONDARY_READY="${SECONDARY_READY:-0}"

[[ "${PRIMARY_DESIRED}" -eq "${EXPECTED_MYSQL_PRIMARY_REPLICAS}" ]] \
  || fail \
    "Expected ${EXPECTED_MYSQL_PRIMARY_REPLICAS} MySQL primary replica; found ${PRIMARY_DESIRED}."

[[ "${PRIMARY_READY}" -eq "${EXPECTED_MYSQL_PRIMARY_REPLICAS}" ]] \
  || fail \
    "Expected ${EXPECTED_MYSQL_PRIMARY_REPLICAS} Ready MySQL primary replica; found ${PRIMARY_READY}."

[[ "${SECONDARY_DESIRED}" -eq "${EXPECTED_MYSQL_SECONDARY_REPLICAS}" ]] \
  || fail \
    "Expected ${EXPECTED_MYSQL_SECONDARY_REPLICAS} MySQL secondary replicas; found ${SECONDARY_DESIRED}."

[[ "${SECONDARY_READY}" -eq "${EXPECTED_MYSQL_SECONDARY_REPLICAS}" ]] \
  || fail \
    "Expected ${EXPECTED_MYSQL_SECONDARY_REPLICAS} Ready MySQL secondary replicas; found ${SECONDARY_READY}."

kubectl get statefulsets,pods,services \
  --namespace "${DATABASE_NAMESPACE}" \
  -o wide

pass "MySQL primary and secondary StatefulSets are Ready."

# ==========================================================
# 9. Validate MySQL persistent storage
# ==========================================================

section "9" "Validating MySQL persistent storage"

PVC_COUNT="$(
  kubectl get pvc \
    --namespace "${DATABASE_NAMESPACE}" \
    --no-headers \
  | wc -l \
  | tr -d ' '
)"

UNBOUND_PVCS="$(
  kubectl get pvc \
    --namespace "${DATABASE_NAMESPACE}" \
    --no-headers \
  | awk '$2 != "Bound" { print $1 }'
)"

[[ "${PVC_COUNT}" -ge 3 ]] \
  || fail "Expected at least 3 MySQL PVCs; found ${PVC_COUNT}."

[[ -z "${UNBOUND_PVCS}" ]] \
  || fail "The following PVCs are not Bound: ${UNBOUND_PVCS}"

kubectl get pvc \
  --namespace "${DATABASE_NAMESPACE}" \
  -o wide

echo "Bound PVC count: ${PVC_COUNT}"

pass "All database PVCs are Bound."

# ==========================================================
# 10. Validate MySQL replication
# ==========================================================

section "10" "Validating MySQL replication"

for replica in mysql-secondary-0 mysql-secondary-1; do
  echo
  echo "Checking replication on ${replica}..."

  REPLICATION_STATUS="$(
    kubectl exec \
      --namespace "${DATABASE_NAMESPACE}" \
      "${replica}" \
      --container mysql \
      -- /bin/bash -ec '
        export MYSQL_PWD="$(
          cat /opt/bitnami/mysql/secrets/mysql-root-password
        )"

        mysql \
          --user=root \
          --batch \
          --skip-column-names \
          --execute="
            SELECT
              SERVICE_STATE
            FROM performance_schema.replication_connection_status
            LIMIT 1;
          "
      '
  )"

  [[ "${REPLICATION_STATUS}" == "ON" ]] \
    || fail \
      "Replication connection on ${replica} is ${REPLICATION_STATUS:-unknown}; expected ON."

  REPLICATION_APPLIER_STATUS="$(
    kubectl exec \
      --namespace "${DATABASE_NAMESPACE}" \
      "${replica}" \
      --container mysql \
      -- /bin/bash -ec '
        export MYSQL_PWD="$(
          cat /opt/bitnami/mysql/secrets/mysql-root-password
        )"

        mysql \
          --user=root \
          --batch \
          --skip-column-names \
          --execute="
            SELECT
              SERVICE_STATE
            FROM performance_schema.replication_applier_status
            LIMIT 1;
          "
      '
  )"

  [[ "${REPLICATION_APPLIER_STATUS}" == "ON" ]] \
    || fail \
      "Replication SQL applier on ${replica} is ${REPLICATION_APPLIER_STATUS:-unknown}; expected ON."

  echo "Replication connection: ${REPLICATION_STATUS}"
  echo "Replication SQL applier: ${REPLICATION_APPLIER_STATUS}"

  pass "Replication is healthy on ${replica}."
done

# ==========================================================
# 11. Validate LoadBalancer and application response
# ==========================================================

section "11" "Validating external Java application Service"

SERVICE_TYPE="$(
  kubectl get service "${JAVA_SERVICE}" \
    --namespace "${JAVA_NAMESPACE}" \
    --output=jsonpath='{.spec.type}'
)"

[[ "${SERVICE_TYPE}" == "LoadBalancer" ]] \
  || fail \
    "Java Service type is ${SERVICE_TYPE}; expected LoadBalancer."

APP_HOST="$(
  kubectl get service "${JAVA_SERVICE}" \
    --namespace "${JAVA_NAMESPACE}" \
    --output=jsonpath='{.status.loadBalancer.ingress[0].hostname}'
)"

[[ -n "${APP_HOST}" ]] \
  || fail "Application LoadBalancer hostname is empty."

echo "Service type: ${SERVICE_TYPE}"
echo "Application hostname: ${APP_HOST}"

HTTP_STATUS="$(
  curl \
    --silent \
    --show-error \
    --output /dev/null \
    --write-out '%{http_code}' \
    --connect-timeout 10 \
    --max-time "${HTTP_TIMEOUT_SECONDS}" \
    --retry 5 \
    --retry-delay 5 \
    "http://${APP_HOST}/" \
    || true
)"

[[ "${HTTP_STATUS}" == "200" ]] \
  || fail \
    "Application returned HTTP ${HTTP_STATUS:-unavailable}; expected HTTP 200."

echo "Application URL: http://${APP_HOST}/"
echo "HTTP status: ${HTTP_STATUS}"

pass "External application endpoint returned HTTP 200."

# ==========================================================
# 12. Validate Cluster Autoscaler
# ==========================================================

section "12" "Validating Cluster Autoscaler"

CLUSTER_AUTOSCALER_DEPLOYMENT="$(
  kubectl get deployment \
    --namespace kube-system \
    -l app.kubernetes.io/name=aws-cluster-autoscaler \
    -o jsonpath='{.items[0].metadata.name}'
)"

[[ -n "${CLUSTER_AUTOSCALER_DEPLOYMENT}" ]] \
  || fail "Cluster Autoscaler Deployment was not found."

kubectl rollout status \
  "deployment/${CLUSTER_AUTOSCALER_DEPLOYMENT}" \
  --namespace kube-system \
  --timeout=300s

AUTOSCALER_DESIRED_REPLICAS="$(
  kubectl get deployment "${CLUSTER_AUTOSCALER_DEPLOYMENT}" \
    --namespace kube-system \
    --output=jsonpath='{.spec.replicas}'
)"

AUTOSCALER_READY_REPLICAS="$(
  kubectl get deployment "${CLUSTER_AUTOSCALER_DEPLOYMENT}" \
    --namespace kube-system \
    --output=jsonpath='{.status.readyReplicas}'
)"

AUTOSCALER_DESIRED_REPLICAS="${AUTOSCALER_DESIRED_REPLICAS:-0}"
AUTOSCALER_READY_REPLICAS="${AUTOSCALER_READY_REPLICAS:-0}"

[[ "${AUTOSCALER_READY_REPLICAS}" -ge 1 ]] \
  || fail "Cluster Autoscaler has no Ready replicas."

AUTOSCALER_SERVICE_ACCOUNT="$(
  kubectl get deployment "${CLUSTER_AUTOSCALER_DEPLOYMENT}" \
    --namespace kube-system \
    --output=jsonpath='{.spec.template.spec.serviceAccountName}'
)"

[[ -n "${AUTOSCALER_SERVICE_ACCOUNT}" ]] \
  || fail "Cluster Autoscaler Deployment has no ServiceAccount configured."

AUTOSCALER_ROLE_ARN="$(
  kubectl get serviceaccount "${AUTOSCALER_SERVICE_ACCOUNT}" \
    --namespace kube-system \
    --output=jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
)"

[[ -n "${AUTOSCALER_ROLE_ARN}" ]] \
  || fail \
  "ServiceAccount ${AUTOSCALER_SERVICE_ACCOUNT} has no IRSA role annotation."

kubectl get deployment,pods \
  --namespace kube-system \
  -l app.kubernetes.io/name=aws-cluster-autoscaler \
  -o wide

echo "Deployment: ${CLUSTER_AUTOSCALER_DEPLOYMENT}"
echo "Desired replicas: ${AUTOSCALER_DESIRED_REPLICAS}"
echo "Ready replicas: ${AUTOSCALER_READY_REPLICAS}"
echo "ServiceAccount: ${AUTOSCALER_SERVICE_ACCOUNT}"
echo "IRSA role configured: yes"

pass "Cluster Autoscaler is deployed and Ready."

# ==========================================================
# 13. Validate managed node group scaling range
# ==========================================================

section "13" "Validating managed node group scaling range"

MIN_SIZE="$(
  aws eks describe-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${NODEGROUP_NAME}" \
    "${AWS_ARGS[@]}" \
    --query 'nodegroup.scalingConfig.minSize' \
    --output text
)"

DESIRED_SIZE="$(
  aws eks describe-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${NODEGROUP_NAME}" \
    "${AWS_ARGS[@]}" \
    --query 'nodegroup.scalingConfig.desiredSize' \
    --output text
)"

MAX_SIZE="$(
  aws eks describe-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${NODEGROUP_NAME}" \
    "${AWS_ARGS[@]}" \
    --query 'nodegroup.scalingConfig.maxSize' \
    --output text
)"

[[ "${MIN_SIZE}" -eq "${EXPECTED_NODEGROUP_MIN_SIZE}" ]] \
  || fail \
    "Expected minimum node count ${EXPECTED_NODEGROUP_MIN_SIZE}; found ${MIN_SIZE}."

[[ "${MAX_SIZE}" -eq "${EXPECTED_NODEGROUP_MAX_SIZE}" ]] \
  || fail \
    "Expected maximum node count ${EXPECTED_NODEGROUP_MAX_SIZE}; found ${MAX_SIZE}."

[[ "${DESIRED_SIZE}" -ge "${MIN_SIZE}" ]] \
  || fail \
    "Desired node count ${DESIRED_SIZE} is below minimum ${MIN_SIZE}."

[[ "${DESIRED_SIZE}" -le "${MAX_SIZE}" ]] \
  || fail \
    "Desired node count ${DESIRED_SIZE} exceeds maximum ${MAX_SIZE}."

echo "Node group: ${NODEGROUP_NAME}"
echo "Minimum size: ${MIN_SIZE}"
echo "Desired size: ${DESIRED_SIZE}"
echo "Maximum size: ${MAX_SIZE}"

pass "Node group scaling range is ${MIN_SIZE}-${MAX_SIZE}."

# ==========================================================
# 14. Validate Cluster Autoscaler discovery tags
# ==========================================================

section "14" "Validating Cluster Autoscaler discovery tags"

ASG_NAME="$(
  aws eks describe-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${NODEGROUP_NAME}" \
    "${AWS_ARGS[@]}" \
    --query 'nodegroup.resources.autoScalingGroups[0].name' \
    --output text
)"

[[ -n "${ASG_NAME}" ]] \
  || fail "Managed node group Auto Scaling Group was not found."

AUTOSCALER_ENABLED_TAG="$(
  aws autoscaling describe-tags \
    "${AWS_ARGS[@]}" \
    --filters \
      "Name=auto-scaling-group,Values=${ASG_NAME}" \
      "Name=key,Values=k8s.io/cluster-autoscaler/enabled" \
    --query 'Tags[0].Value' \
    --output text
)"

AUTOSCALER_CLUSTER_TAG="$(
  aws autoscaling describe-tags \
    "${AWS_ARGS[@]}" \
    --filters \
      "Name=auto-scaling-group,Values=${ASG_NAME}" \
      "Name=key,Values=k8s.io/cluster-autoscaler/${CLUSTER_NAME}" \
    --query 'Tags[0].Value' \
    --output text
)"

[[ "${AUTOSCALER_ENABLED_TAG}" == "true" ]] \
  || fail \
    "ASG autoscaler enabled tag is ${AUTOSCALER_ENABLED_TAG}; expected true."

[[ "${AUTOSCALER_CLUSTER_TAG}" == "owned" ]] \
  || fail \
    "ASG cluster autoscaler tag is ${AUTOSCALER_CLUSTER_TAG}; expected owned."

echo "Auto Scaling Group: ${ASG_NAME}"
echo "Autoscaler enabled tag: ${AUTOSCALER_ENABLED_TAG}"
echo "Cluster ownership tag: ${AUTOSCALER_CLUSTER_TAG}"

pass "Cluster Autoscaler discovery tags are configured."

# ==========================================================
# Final result
# ==========================================================

echo
echo "=========================================================="
echo "PLATFORM VALIDATION SUCCESSFUL"
echo "=========================================================="
echo "AWS account: ${AWS_ACCOUNT_ID}"
echo "AWS caller: ${AWS_CALLER_ARN}"
echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo "Kubernetes version: ${CLUSTER_VERSION}"
echo "Managed node group: ${NODEGROUP_NAME}"
echo "Ready EC2 nodes: ${READY_EC2_NODES}"
echo "Node scaling range: ${MIN_SIZE}-${MAX_SIZE}"
echo "Current desired nodes: ${DESIRED_SIZE}"
echo "Fargate profile: ${FARGATE_PROFILE_NAME}"
echo "Java replicas: ${AVAILABLE_JAVA_REPLICAS}"
echo "Java Fargate Pods: ${FARGATE_SCHEDULED_PODS}"
echo "MySQL primary replicas: ${PRIMARY_READY}"
echo "MySQL secondary replicas: ${SECONDARY_READY}"
echo "Bound database PVCs: ${PVC_COUNT}"
echo "Cluster Autoscaler: ${CLUSTER_AUTOSCALER_DEPLOYMENT}"
echo "Application: http://${APP_HOST}/"
echo "HTTP status: ${HTTP_STATUS}"
echo "=========================================================="
