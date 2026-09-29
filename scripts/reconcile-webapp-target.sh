#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE_DIR=$(cd "${ROOT_DIR}/.." && pwd)
AWS_TERRAFORM_DIR=${AWS_TERRAFORM_DIR:-"${WORKSPACE_DIR}/aws-terraform"}
TARGET_TERRAFORM_DIR=${TARGET_TERRAFORM_DIR:-"${WORKSPACE_DIR}/target-hosts-setup"}
AWS_PROFILE=${AWS_PROFILE:-capstone}
AWS_REGION=${AWS_REGION:-ap-southeast-1}
EXPECTED_AWS_ACCOUNT_ID=${EXPECTED_AWS_ACCOUNT_ID:-891377133321}
WEBAPP_NAMESPACE=${WEBAPP_NAMESPACE:-dendenmushi-webapp}
IMPLEMENTER_GROUP_NAME=${IMPLEMENTER_GROUP_NAME:-DenDenMushi Demo Operators}
JOB_NAME=webapp-target-reconcile
CONFIGMAP_NAME=dendenmushi-target-reconcile
RECONCILE_ENABLED=true

if [[ "${1:-}" == "--verify-only" ]]; then
  RECONCILE_ENABLED=false
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--verify-only]" >&2
  exit 2
fi

for command in aws terraform kubectl; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
done

tf_output() {
  terraform -chdir="$1" output -raw "$2"
}

cleanup() {
  kubectl delete job "${JOB_NAME}" -n "${WEBAPP_NAMESPACE}" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete configmap "${CONFIGMAP_NAME}" -n "${WEBAPP_NAMESPACE}" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

export AWS_PROFILE
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [[ "${AWS_ACCOUNT_ID}" != "${EXPECTED_AWS_ACCOUNT_ID}" ]]; then
  echo "Refusing to reconcile account ${AWS_ACCOUNT_ID}; expected ${EXPECTED_AWS_ACCOUNT_ID}." >&2
  exit 1
fi

CLUSTER_NAME=$(tf_output "${AWS_TERRAFORM_DIR}" cluster_name)
TARGET_HOST_ID=$(tf_output "${TARGET_TERRAFORM_DIR}" host_id)
TARGET_ADDRESS=$(tf_output "${TARGET_TERRAFORM_DIR}" private_address)
SSH_USERNAME=$(tf_output "${TARGET_TERRAFORM_DIR}" ssh_username)

if [[ ! "${TARGET_HOST_ID}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Terraform returned an invalid target host ID." >&2
  exit 1
fi
if [[ ! "${TARGET_ADDRESS}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Terraform returned an invalid target address." >&2
  exit 1
fi
if [[ ! "${SSH_USERNAME}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
  echo "Terraform returned an invalid SSH username." >&2
  exit 1
fi

if [[ "${SKIP_KUBECONFIG_UPDATE:-false}" != "true" ]]; then
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null
fi

kubectl create configmap "${CONFIGMAP_NAME}" \
  -n "${WEBAPP_NAMESPACE}" \
  --from-literal=reconcile-enabled="${RECONCILE_ENABLED}" \
  --from-literal=host-id="${TARGET_HOST_ID}" \
  --from-literal=target-address="${TARGET_ADDRESS}" \
  --from-literal=ssh-username="${SSH_USERNAME}" \
  --from-literal=implementer-group-name="${IMPLEMENTER_GROUP_NAME}" \
  --dry-run=client \
  -o yaml | kubectl apply -f - >/dev/null

kubectl delete job "${JOB_NAME}" -n "${WEBAPP_NAMESPACE}" \
  --ignore-not-found --wait=true >/dev/null
kubectl apply -f "${ROOT_DIR}/apps/dendenmushi/jobs/webapp-target-reconcile.yaml" >/dev/null

JOB_SUCCEEDED=false
for _ in $(seq 1 90); do
  if [[ "$(kubectl get job "${JOB_NAME}" -n "${WEBAPP_NAMESPACE}" \
    -o jsonpath='{.status.succeeded}' 2>/dev/null || true)" == "1" ]]; then
    JOB_SUCCEEDED=true
    break
  fi
  if [[ "$(kubectl get job "${JOB_NAME}" -n "${WEBAPP_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)" == "True" ]]; then
    break
  fi
  sleep 2
done

if [[ "${JOB_SUCCEEDED}" != "true" ]]; then
  kubectl logs "job/${JOB_NAME}" -n "${WEBAPP_NAMESPACE}" >&2 || true
  exit 1
fi

kubectl logs "job/${JOB_NAME}" -n "${WEBAPP_NAMESPACE}"
