#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================================
# Amazon EKS Platform Destruction Script
# ==========================================================
#
# This script removes the Java–MySQL EKS project infrastructure.
#
# It intentionally deletes the Java LoadBalancer Service before
# deleting the EKS cluster so AWS can clean up the external load
# balancer while the Kubernetes control plane is still available.
#
# WARNING:
# This script can permanently delete Kubernetes workloads,
# EBS-backed data, EC2 nodes, Fargate resources, load balancers,
# and the EKS control plane.
#
# Optional environment variables:
#
#   AWS_PROFILE
#   AWS_REGION
#   CLUSTER_NAME
#   ECR_REPOSITORY
#   APP_NAMESPACE
#   APP_SERVICE
#   DATABASE_NAMESPACE
#   CLUSTER_AUTOSCALER_POLICY_NAME
#   LOAD_BALANCER_WAIT_SECONDS
#   SKIP_ECR_PROMPT
#
# Example:
#
#   AWS_PROFILE=eks-admin \
#   ./scripts/destroy-cluster.sh
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
APP_SERVICE="${APP_SERVICE:-java-app}"
DATABASE_NAMESPACE="${DATABASE_NAMESPACE:-database}"

CLUSTER_AUTOSCALER_POLICY_NAME="${
  CLUSTER_AUTOSCALER_POLICY_NAME:-JavaMysqlEksClusterAutoscalerPolicy
}"

LOAD_BALANCER_WAIT_SECONDS="${LOAD_BALANCER_WAIT_SECONDS:-300}"
SKIP_ECR_PROMPT="${SKIP_ECR_PROMPT:-false}"

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

# ----------------------------------------------------------
# Error handler
# ----------------------------------------------------------

on_error() {
  local exit_code=$?
  local line_number="${1:-unknown}"

  printf '\n' >&2
  warning "Cleanup script failed."
  warning "Line: ${line_number}"
  warning "Exit code: ${exit_code}"
  warning "Review the AWS Console for partially deleted resources."

  exit "${exit_code}"
}

trap 'on_error "${LINENO}"' ERR

# ----------------------------------------------------------
# Required command validation
# ----------------------------------------------------------

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    fail "Required command is not installed: ${command_name}"
  fi
}

for required_command in \
  aws \
  eksctl \
  kubectl \
  jq \
  grep \
  sed
do
  require_command "${required_command}"
done

# ----------------------------------------------------------
# Environment-value validation
# ----------------------------------------------------------

if [[ ! "${LOAD_BALANCER_WAIT_SECONDS}" =~ ^[0-9]+$ ]]; then
  fail "LOAD_BALANCER_WAIT_SECONDS must be a positive integer."
fi

case "${SKIP_ECR_PROMPT}" in
  true|false)
    ;;
  *)
    fail "SKIP_ECR_PROMPT must be either true or false."
    ;;
esac

# ----------------------------------------------------------
# Configuration summary
# ----------------------------------------------------------

echo
echo "=========================================================="
echo "DANGER: AMAZON EKS PLATFORM DESTRUCTION"
echo "=========================================================="
printf 'AWS profile:             %s\n' "${AWS_PROFILE}"
printf 'AWS region:              %s\n' "${AWS_REGION}"
printf 'EKS cluster:             %s\n' "${CLUSTER_NAME}"
printf 'Java namespace:          %s\n' "${APP_NAMESPACE}"
printf 'Java LoadBalancer:       %s\n' "${APP_SERVICE}"
printf 'Database namespace:      %s\n' "${DATABASE_NAMESPACE}"
printf 'ECR repository:          %s\n' "${ECR_REPOSITORY}"
printf 'Autoscaler IAM policy:   %s\n' "${CLUSTER_AUTOSCALER_POLICY_NAME}"
printf 'LoadBalancer wait:       %s seconds\n' \
  "${LOAD_BALANCER_WAIT_SECONDS}"
echo "=========================================================="
echo
echo "This operation may permanently delete:"
echo
echo "  - The Amazon EKS cluster"
echo "  - Managed EC2 worker nodes"
echo "  - AWS Fargate profiles"
echo "  - Kubernetes Deployments and StatefulSets"
echo "  - The Java application LoadBalancer"
echo "  - MySQL primary and replica Pods"
echo "  - phpMyAdmin"
echo "  - Kubernetes Secrets and ConfigMaps"
echo "  - Auto Scaling Groups"
echo "  - CloudFormation stacks"
echo "  - Dynamically provisioned EBS volumes"
echo
echo "Complete all screenshots, demonstrations, backups, and"
echo "assessment validation before continuing."
echo

read -r -p \
  "Type the cluster name '${CLUSTER_NAME}' to continue: " \
  CONFIRMED_CLUSTER_NAME

if [[ "${CONFIRMED_CLUSTER_NAME}" != "${CLUSTER_NAME}" ]]; then
  log "Cluster name confirmation did not match."
  log "Cleanup cancelled."
  exit 0
fi

read -r -p \
  "Type DELETE-EKS to authorize permanent deletion: " \
  DELETE_CONFIRMATION

if [[ "${DELETE_CONFIRMATION}" != "DELETE-EKS" ]]; then
  log "Destruction phrase did not match."
  log "Cleanup cancelled."
  exit 0
fi

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

if [[ -z "${AWS_CALLER_ARN}" || "${AWS_CALLER_ARN}" == "null" ]]; then
  fail "AWS caller ARN could not be determined."
fi

printf '  AWS account: %s\n' "${AWS_ACCOUNT_ID}"
printf '  AWS caller:  %s\n' "${AWS_CALLER_ARN}"

echo

read -r -p \
  "Type the AWS account ID '${AWS_ACCOUNT_ID}' to confirm: " \
  CONFIRMED_ACCOUNT_ID

if [[ "${CONFIRMED_ACCOUNT_ID}" != "${AWS_ACCOUNT_ID}" ]]; then
  log "AWS account confirmation did not match."
  log "Cleanup cancelled."
  exit 0
fi

success "AWS identity confirmed."

# ----------------------------------------------------------
# Confirm whether the cluster exists
# ----------------------------------------------------------

log "Checking whether the EKS cluster exists..."

if aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  >/dev/null 2>&1
then
  CLUSTER_EXISTS="true"

  CLUSTER_STATUS="$(
    aws eks describe-cluster \
      --name "${CLUSTER_NAME}" \
      --region "${AWS_REGION}" \
      --profile "${AWS_PROFILE}" \
      --query 'cluster.status' \
      --output text
  )"

  printf '  Cluster status: %s\n' "${CLUSTER_STATUS}"
else
  CLUSTER_EXISTS="false"

  warning "EKS cluster ${CLUSTER_NAME} does not exist or is inaccessible."

  read -r -p \
    "Continue with optional ECR and IAM cleanup? Type CONTINUE: " \
    CONTINUE_WITHOUT_CLUSTER

  if [[ "${CONTINUE_WITHOUT_CLUSTER}" != "CONTINUE" ]]; then
    log "Cleanup cancelled."
    exit 0
  fi
fi

# ----------------------------------------------------------
# Configure kubeconfig when the cluster exists
# ----------------------------------------------------------

KUBERNETES_ACCESSIBLE="false"

if [[ "${CLUSTER_EXISTS}" == "true" ]]; then
  log "Updating kubeconfig before resource cleanup..."

  if aws eks update-kubeconfig \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE}" \
    --alias "${CLUSTER_NAME}" \
    >/dev/null
  then
    if kubectl cluster-info >/dev/null 2>&1; then
      KUBERNETES_ACCESSIBLE="true"
      success "Kubernetes API access is available."
    else
      warning "kubeconfig was updated, but Kubernetes is inaccessible."
      warning "Kubernetes resource cleanup may be incomplete."
    fi
  else
    warning "Unable to update kubeconfig."
    warning "Kubernetes resource cleanup may be incomplete."
  fi
fi

# ----------------------------------------------------------
# Capture pre-deletion resource evidence
# ----------------------------------------------------------

if [[ "${KUBERNETES_ACCESSIBLE}" == "true" ]]; then
  echo
  echo "=========================================================="
  echo "Kubernetes Resources Before Deletion"
  echo "=========================================================="

  kubectl get nodes \
    -o wide \
    || true

  echo

  kubectl get \
    deployments,statefulsets,pods,services,persistentvolumeclaims \
    --all-namespaces \
    || true

  echo
  echo "PersistentVolume reclaim policies:"

  kubectl get persistentvolumes \
    -o custom-columns='PV:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase,CLAIM-NAMESPACE:.spec.claimRef.namespace,CLAIM-NAME:.spec.claimRef.name' \
    || true

  echo "=========================================================="
fi

# ----------------------------------------------------------
# Delete the Java LoadBalancer Service first
# ----------------------------------------------------------

if [[ "${KUBERNETES_ACCESSIBLE}" == "true" ]]; then
  log "Checking Java application Service..."

  if kubectl get service "${APP_SERVICE}" \
    --namespace "${APP_NAMESPACE}" \
    >/dev/null 2>&1
  then
    SERVICE_TYPE="$(
      kubectl get service "${APP_SERVICE}" \
        --namespace "${APP_NAMESPACE}" \
        --output=jsonpath='{.spec.type}'
    )"

    LOAD_BALANCER_HOSTNAME="$(
      kubectl get service "${APP_SERVICE}" \
        --namespace "${APP_NAMESPACE}" \
        --output=jsonpath='{.status.loadBalancer.ingress[0].hostname}'
    )"

    printf '  Service type: %s\n' "${SERVICE_TYPE}"
    printf '  LoadBalancer: %s\n' \
      "${LOAD_BALANCER_HOSTNAME:-not-assigned}"

    log "Deleting Java application Service..."

    kubectl delete service "${APP_SERVICE}" \
      --namespace "${APP_NAMESPACE}" \
      --ignore-not-found=true \
      --wait=true

    success "Java application Service deleted."

    if [[ "${SERVICE_TYPE}" == "LoadBalancer" ]]; then
      if [[ -z "${LOAD_BALANCER_HOSTNAME}" ]]; then
        success "No LoadBalancer hostname was assigned."
      else
        log "Waiting for AWS Load Balancer cleanup..."

        ELAPSED_SECONDS=0
        INTERVAL_SECONDS=15
        LOAD_BALANCER_REMOVED="false"

        while [[ "${ELAPSED_SECONDS}" -lt "${LOAD_BALANCER_WAIT_SECONDS}" ]]; do
          LOAD_BALANCER_COUNT="$(
            aws elbv2 describe-load-balancers \
              --region "${AWS_REGION}" \
              --profile "${AWS_PROFILE}" \
              --query \
                "length(LoadBalancers[?DNSName=='${LOAD_BALANCER_HOSTNAME}'])" \
              --output text \
              2>/dev/null \
            || printf 'unknown'
          )"

          if [[ "${LOAD_BALANCER_COUNT}" == "0" ]]; then
            success "AWS Load Balancer was removed."
            LOAD_BALANCER_REMOVED="true"
            break
          fi

          if [[ "${LOAD_BALANCER_COUNT}" == "unknown" ]]; then
            warning "Unable to query the AWS Load Balancer state."
          else
            log "Load Balancer still exists. Waiting..."
          fi

          sleep "${INTERVAL_SECONDS}"

          ELAPSED_SECONDS=$(
            (
              ELAPSED_SECONDS
              + INTERVAL_SECONDS
            )
          )
        done

        if [[ "${LOAD_BALANCER_REMOVED}" != "true" ]]; then
          warning "Load Balancer cleanup wait period expired."
          warning "Review EC2 → Load Balancers after cluster deletion."
        fi
      fi
    fi
  else
    log "Java application Service does not exist."
  fi
fi

# ----------------------------------------------------------
# Optional phpMyAdmin cleanup
# ----------------------------------------------------------

if [[ "${KUBERNETES_ACCESSIBLE}" == "true" ]]; then
  if kubectl get deployment phpmyadmin \
    --namespace "${DATABASE_NAMESPACE}" \
    >/dev/null 2>&1
  then
    read -r -p \
      "Delete phpMyAdmin before cluster deletion? Type DELETE-PMA: " \
      DELETE_PHPMYADMIN

    if [[ "${DELETE_PHPMYADMIN}" == "DELETE-PMA" ]]; then
      kubectl delete deployment phpmyadmin \
        --namespace "${DATABASE_NAMESPACE}" \
        --ignore-not-found=true \
        --wait=true

      kubectl delete service phpmyadmin \
        --namespace "${DATABASE_NAMESPACE}" \
        --ignore-not-found=true \
        --wait=true

      success "phpMyAdmin resources deleted."
    else
      log "phpMyAdmin will be removed with the cluster."
    fi
  else
    log "phpMyAdmin Deployment does not exist."
  fi
fi

# ----------------------------------------------------------
# Database data warning
# ----------------------------------------------------------

if [[ "${KUBERNETES_ACCESSIBLE}" == "true" ]]; then
  echo
  echo "=========================================================="
  echo "DATABASE DATA WARNING"
  echo "=========================================================="

  kubectl get persistentvolumeclaims \
    --namespace "${DATABASE_NAMESPACE}" \
    -o wide \
    || true

  echo
  echo "MySQL uses EBS-backed PersistentVolumes."
  echo "Volumes with a Delete reclaim policy may be deleted after"
  echo "their claims or the cluster are removed."
  echo

  read -r -p \
    "Type DELETE-MYSQL-DATA to accept possible data loss: " \
    DELETE_DATABASE_CONFIRMATION

  if [[ "${DELETE_DATABASE_CONFIRMATION}" != "DELETE-MYSQL-DATA" ]]; then
    fail "Database deletion was not authorized. Cluster cleanup stopped."
  fi
fi

# ----------------------------------------------------------
# Delete the EKS cluster
# ----------------------------------------------------------

if [[ "${CLUSTER_EXISTS}" == "true" ]]; then
  log "Deleting EKS cluster ${CLUSTER_NAME}..."

  eksctl delete cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE}" \
    --wait

  success "EKS cluster deletion command completed."
else
  log "Skipping EKS cluster deletion because the cluster was not found."
fi

# ----------------------------------------------------------
# Verify cluster deletion
# ----------------------------------------------------------

log "Verifying EKS cluster deletion..."

if aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  >/dev/null 2>&1
then
  warning "The EKS cluster still appears in the AWS API."
  warning "It may still be deleting. Review the AWS Console."
else
  success "The EKS cluster is no longer returned by the AWS API."
fi

# ----------------------------------------------------------
# Optional ECR repository deletion
# ----------------------------------------------------------

ECR_EXISTS="false"

if aws ecr describe-repositories \
  --repository-names "${ECR_REPOSITORY}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  >/dev/null 2>&1
then
  ECR_EXISTS="true"

  IMAGE_COUNT="$(
    aws ecr list-images \
      --repository-name "${ECR_REPOSITORY}" \
      --region "${AWS_REGION}" \
      --profile "${AWS_PROFILE}" \
      --query 'length(imageIds)' \
      --output text
  )"

  printf '\nECR repository %s contains %s image references.\n' \
    "${ECR_REPOSITORY}" \
    "${IMAGE_COUNT}"
fi

if [[ "${ECR_EXISTS}" == "true" ]]; then
  if [[ "${SKIP_ECR_PROMPT}" == "true" ]]; then
    log "Skipping ECR deletion because SKIP_ECR_PROMPT=true."
  else
    read -r -p \
      "Delete ECR repository '${ECR_REPOSITORY}' and all images? Type DELETE-ECR: " \
      DELETE_ECR_CONFIRMATION

    if [[ "${DELETE_ECR_CONFIRMATION}" == "DELETE-ECR" ]]; then
      aws ecr delete-repository \
        --repository-name "${ECR_REPOSITORY}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --force \
        >/dev/null

      success "ECR repository ${ECR_REPOSITORY} deleted."
    else
      log "ECR repository retained."
    fi
  fi
else
  log "ECR repository ${ECR_REPOSITORY} does not exist."
fi

# ----------------------------------------------------------
# Optional Cluster Autoscaler IAM policy cleanup
# ----------------------------------------------------------

CLUSTER_AUTOSCALER_POLICY_ARN="$(
  aws iam list-policies \
    --scope Local \
    --profile "${AWS_PROFILE}" \
    --query \
      "Policies[?PolicyName=='${CLUSTER_AUTOSCALER_POLICY_NAME}'].Arn | [0]" \
    --output text
)"

if [[ -n "${CLUSTER_AUTOSCALER_POLICY_ARN}" \
  && "${CLUSTER_AUTOSCALER_POLICY_ARN}" != "None" \
  && "${CLUSTER_AUTOSCALER_POLICY_ARN}" != "null" ]]; then
  echo

  printf 'Cluster Autoscaler policy: %s\n' \
    "${CLUSTER_AUTOSCALER_POLICY_ARN}"

  read -r -p \
    "Delete the Cluster Autoscaler IAM policy? Type DELETE-AUTOSCALER-POLICY: " \
    DELETE_AUTOSCALER_POLICY_CONFIRMATION

  if [[ "${DELETE_AUTOSCALER_POLICY_CONFIRMATION}" == "DELETE-AUTOSCALER-POLICY" ]]; then
    ATTACHED_ROLES="$(
      aws iam list-entities-for-policy \
        --policy-arn "${CLUSTER_AUTOSCALER_POLICY_ARN}" \
        --profile "${AWS_PROFILE}" \
        --query 'PolicyRoles[].RoleName' \
        --output text
    )"

    ATTACHED_USERS="$(
      aws iam list-entities-for-policy \
        --policy-arn "${CLUSTER_AUTOSCALER_POLICY_ARN}" \
        --profile "${AWS_PROFILE}" \
        --query 'PolicyUsers[].UserName' \
        --output text
    )"

    ATTACHED_GROUPS="$(
      aws iam list-entities-for-policy \
        --policy-arn "${CLUSTER_AUTOSCALER_POLICY_ARN}" \
        --profile "${AWS_PROFILE}" \
        --query 'PolicyGroups[].GroupName' \
        --output text
    )"

    if [[
      -n "${ATTACHED_ROLES}"
      || -n "${ATTACHED_USERS}"
      || -n "${ATTACHED_GROUPS}"
    ]]; then
      warning "The Cluster Autoscaler policy is still attached."

      if [[ -n "${ATTACHED_ROLES}" ]]; then
        warning "Attached roles: ${ATTACHED_ROLES}"
      fi

      if [[ -n "${ATTACHED_USERS}" ]]; then
        warning "Attached users: ${ATTACHED_USERS}"
      fi

      if [[ -n "${ATTACHED_GROUPS}" ]]; then
        warning "Attached groups: ${ATTACHED_GROUPS}"
      fi

      warning "The IAM policy was not deleted."
      warning "Wait for CloudFormation role cleanup or detach it manually."
    else
      POLICY_VERSIONS="$(
        aws iam list-policy-versions \
          --policy-arn "${CLUSTER_AUTOSCALER_POLICY_ARN}" \
          --profile "${AWS_PROFILE}" \
          --query 'Versions[?IsDefaultVersion==`false`].VersionId' \
          --output text
      )"

      if [[ -n "${POLICY_VERSIONS}" ]]; then
        for version_id in ${POLICY_VERSIONS}; do
          log "Deleting non-default IAM policy version ${version_id}..."

          aws iam delete-policy-version \
            --policy-arn "${CLUSTER_AUTOSCALER_POLICY_ARN}" \
            --version-id "${version_id}" \
            --profile "${AWS_PROFILE}"
        done
      fi

      aws iam delete-policy \
        --policy-arn "${CLUSTER_AUTOSCALER_POLICY_ARN}" \
        --profile "${AWS_PROFILE}"

      success "Cluster Autoscaler IAM policy deleted."
    fi
  else
    log "Cluster Autoscaler IAM policy retained."
  fi
else
  log "Cluster Autoscaler IAM policy was not found."
fi

# ----------------------------------------------------------
# Post-deletion resource review
# ----------------------------------------------------------

echo
echo "=========================================================="
echo "Post-Deletion AWS Resource Review"
echo "=========================================================="

log "Checking CloudFormation stacks related to the cluster..."

aws cloudformation list-stacks \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --stack-status-filter \
    CREATE_COMPLETE \
    UPDATE_COMPLETE \
    ROLLBACK_COMPLETE \
    DELETE_FAILED \
  --query \
    "StackSummaries[?contains(StackName, '${CLUSTER_NAME}')].{
      StackName:StackName,
      Status:StackStatus
    }" \
  --output table \
  || true

log "Checking remaining load balancers..."

aws elbv2 describe-load-balancers \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'LoadBalancers[].{
    Name:LoadBalancerName,
    DNSName:DNSName,
    State:State.Code,
    Type:Type
  }' \
  --output table \
  || true

log "Checking EBS volumes tagged for the cluster..."

aws ec2 describe-volumes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters \
    "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned,shared" \
  --query 'Volumes[].{
    VolumeId:VolumeId,
    State:State,
    SizeGiB:Size,
    AvailabilityZone:AvailabilityZone,
    Encrypted:Encrypted
  }' \
  --output table \
  || true

log "Checking remaining Auto Scaling Groups..."

aws autoscaling describe-auto-scaling-groups \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query \
    "AutoScalingGroups[
      ?Tags[?Key=='eks:cluster-name' && Value=='${CLUSTER_NAME}']
    ].{
      Name:AutoScalingGroupName,
      Min:MinSize,
      Desired:DesiredCapacity,
      Max:MaxSize
    }" \
  --output table \
  || true

log "Checking remaining cluster-related network interfaces..."

aws ec2 describe-network-interfaces \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters \
    "Name=description,Values=*${CLUSTER_NAME}*" \
  --query 'NetworkInterfaces[].{
    ENI:NetworkInterfaceId,
    Status:Status,
    Description:Description,
    Subnet:SubnetId,
    PrivateIP:PrivateIpAddress
  }' \
  --output table \
  || true

# ----------------------------------------------------------
# Final summary
# ----------------------------------------------------------

echo
echo "=========================================================="
echo "Cleanup Completed"
echo "=========================================================="
echo
echo "The automated cleanup has finished."
echo
echo "Manually review the AWS Console for:"
echo
echo "  - EKS clusters and add-ons"
echo "  - EC2 Load Balancers"
echo "  - EC2 Auto Scaling Groups"
echo "  - EBS volumes and snapshots"
echo "  - Elastic network interfaces"
echo "  - CloudFormation stacks"
echo "  - CloudWatch log groups"
echo "  - IAM roles and policies"
echo "  - ECR repositories"
echo "  - NAT gateways, if any"
echo "  - public IPv4 resources"
echo "  - security groups"
echo
echo "Retained resources may continue to generate AWS charges."
echo "=========================================================="