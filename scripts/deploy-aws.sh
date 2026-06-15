#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE_DIR=$(cd "${ROOT_DIR}/.." && pwd)
AWS_TERRAFORM_DIR=${AWS_TERRAFORM_DIR:-"${WORKSPACE_DIR}/aws-terraform"}
TARGET_TERRAFORM_DIR=${TARGET_TERRAFORM_DIR:-"${WORKSPACE_DIR}/target-hosts-setup"}
AWS_REGION=${AWS_REGION:-ap-southeast-1}
IMAGE_TAG=${IMAGE_TAG:-main}
SESSION_MANAGER_IMAGE_TAG=${SESSION_MANAGER_IMAGE_TAG:-${IMAGE_TAG}}
STS_IMAGE_TAG=${STS_IMAGE_TAG:-${IMAGE_TAG}}
PROXY_CONTROLPLANE_IMAGE_TAG=${PROXY_CONTROLPLANE_IMAGE_TAG:-${IMAGE_TAG}}
PROXY_DATAPLANE_IMAGE_TAG=${PROXY_DATAPLANE_IMAGE_TAG:-${IMAGE_TAG}}
INCIDENT_AGENT_IMAGE_TAG=${INCIDENT_AGENT_IMAGE_TAG:-${IMAGE_TAG}}
NAMESPACE=dendenmushi
KEYSCAN_POD=dendenmushi-ssh-keyscan

for command in aws terraform kubectl jq openssl awk; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
done

cleanup() {
  kubectl delete pod "${KEYSCAN_POD}" -n "${NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME=$(terraform -chdir="${AWS_TERRAFORM_DIR}" output -raw cluster_name)
PROXY_DATAPLANE_ROLE_ARN=$(terraform -chdir="${AWS_TERRAFORM_DIR}" output -raw proxy_dataplane_role_arn)
INCIDENT_AGENT_ROLE_ARN=$(terraform -chdir="${AWS_TERRAFORM_DIR}" output -raw incident_agent_role_arn)
INCIDENT_ALERTS_QUEUE_URL=$(terraform -chdir="${AWS_TERRAFORM_DIR}" output -raw incident_alerts_queue_url)
INCIDENT_DATABASE_SECRET_ID=$(terraform -chdir="${AWS_TERRAFORM_DIR}" output -raw incident_database_secret_id)
APPLICATION_CERTIFICATE_ARN=$(terraform -chdir="${AWS_TERRAFORM_DIR}" output -raw application_certificate_arn)
COGNITO_USER_POOL_ARN=$(terraform -chdir="${AWS_TERRAFORM_DIR}" output -raw cognito_user_pool_arn)
COGNITO_CLIENT_ID=$(terraform -chdir="${AWS_TERRAFORM_DIR}" output -raw cognito_client_id)
COGNITO_DOMAIN=$(terraform -chdir="${AWS_TERRAFORM_DIR}" output -raw cognito_domain)

HOST_ID=$(terraform -chdir="${TARGET_TERRAFORM_DIR}" output -raw host_id)
TARGET_ADDRESS=$(terraform -chdir="${TARGET_TERRAFORM_DIR}" output -raw private_address)
SSH_USERNAME=$(terraform -chdir="${TARGET_TERRAFORM_DIR}" output -raw ssh_username)
CONNECTION_TYPE=$(terraform -chdir="${TARGET_TERRAFORM_DIR}" output -raw connection_type)
CREDENTIAL_SECRET_ID=$(terraform -chdir="${TARGET_TERRAFORM_DIR}" output -raw credential_secret_id)
AUTOMATION_SERVICE_NAME=$(terraform -chdir="${TARGET_TERRAFORM_DIR}" output -raw automation_service_name)
AUTOMATION_HEALTH_URL=$(terraform -chdir="${TARGET_TERRAFORM_DIR}" output -raw automation_health_url)
AUTOMATION_HELPER_PATH=$(terraform -chdir="${TARGET_TERRAFORM_DIR}" output -raw automation_helper_path)

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"
kubectl apply -f "${ROOT_DIR}/apps/dendenmushi/base/namespace.yaml"

if [[ -n "${JWT_SIGNING_KEY:-}" ]]; then
  kubectl create secret generic dendenmushi-runtime \
    -n "${NAMESPACE}" \
    --from-literal=jwt-signing-key="${JWT_SIGNING_KEY}" \
    --dry-run=client \
    -o yaml | kubectl apply -f -
elif ! kubectl get secret dendenmushi-runtime -n "${NAMESPACE}" >/dev/null 2>&1; then
  GENERATED_JWT_SIGNING_KEY=$(openssl rand -base64 48)
  kubectl create secret generic dendenmushi-runtime \
    -n "${NAMESPACE}" \
    --from-literal=jwt-signing-key="${GENERATED_JWT_SIGNING_KEY}"
  echo "Created Kubernetes JWT signing secret."
else
  echo "Preserving the existing Kubernetes JWT signing secret."
fi

DATABASE_URL=$(aws secretsmanager get-secret-value \
  --region "${AWS_REGION}" \
  --secret-id "${INCIDENT_DATABASE_SECRET_ID}" \
  --query SecretString \
  --output text)
kubectl create secret generic dendenmushi-database \
  -n "${NAMESPACE}" \
  --from-literal=database-url="${DATABASE_URL}" \
  --dry-run=client \
  -o yaml | kubectl apply -f -
unset DATABASE_URL

kubectl delete pod "${KEYSCAN_POD}" \
  -n "${NAMESPACE}" \
  --ignore-not-found \
  --wait=true >/dev/null
kubectl run "${KEYSCAN_POD}" \
  -n "${NAMESPACE}" \
  --restart=Never \
  --image=alpine:3.21 \
  --command -- sh -c \
  "apk add --no-cache openssh-client >/dev/null && ssh-keyscan -T 10 -t ed25519 -p 22 '${TARGET_ADDRESS}'"

for _ in $(seq 1 60); do
  POD_PHASE=$(kubectl get pod "${KEYSCAN_POD}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "${POD_PHASE}" == "Succeeded" || "${POD_PHASE}" == "Failed" ]]; then
    break
  fi
  sleep 2
done

if [[ "${POD_PHASE:-}" != "Succeeded" ]]; then
  kubectl logs "${KEYSCAN_POD}" -n "${NAMESPACE}" >&2 || true
  echo "Unable to read the target SSH host key from inside EKS." >&2
  exit 1
fi

HOST_PUBLIC_KEY=$(kubectl logs "${KEYSCAN_POD}" -n "${NAMESPACE}" 2>/dev/null |
  awk '$2 == "ssh-ed25519" { print $2 " " $3; exit }')
if [[ -z "${HOST_PUBLIC_KEY}" ]]; then
  echo "The target did not return an ED25519 SSH host key." >&2
  exit 1
fi

SERVER_INVENTORY_STATIC_JSON=$(jq -cn \
  --arg host_id "${HOST_ID}" \
  --arg address "${TARGET_ADDRESS}:22" \
  --arg username "${SSH_USERNAME}" \
  --arg connection_type "${CONNECTION_TYPE}" \
  --arg credential_secret_id "${CREDENTIAL_SECRET_ID}" \
  --arg host_public_key "${HOST_PUBLIC_KEY}" \
  --arg automation_service_name "${AUTOMATION_SERVICE_NAME}" \
  --arg automation_health_url "${AUTOMATION_HEALTH_URL}" \
  --arg automation_helper_path "${AUTOMATION_HELPER_PATH}" \
  '{($host_id): {
    address: $address,
    username: $username,
    connectionType: $connection_type,
    credentialSecretId: $credential_secret_id,
    hostPublicKey: $host_public_key,
    automation: {
      serviceName: $automation_service_name,
      healthUrl: $automation_health_url,
      helperPath: $automation_helper_path,
      allowedOperations: [
        "system_overview",
        "disk_usage",
        "memory_usage",
        "top_processes",
        "service_status",
        "service_logs",
        "health_check",
        "restart_service"
      ]
    }
  }}')
SERVER_INVENTORY_YAML=$(printf '%s' "${SERVER_INVENTORY_STATIC_JSON}" | jq -Rs .)

MANIFEST=$(kubectl kustomize "${ROOT_DIR}/apps/dendenmushi/overlays/dev")
MANIFEST=${MANIFEST//__AWS_ACCOUNT_ID__/${AWS_ACCOUNT_ID}}
MANIFEST=${MANIFEST//__SESSION_MANAGER_IMAGE_TAG__/${SESSION_MANAGER_IMAGE_TAG}}
MANIFEST=${MANIFEST//__STS_IMAGE_TAG__/${STS_IMAGE_TAG}}
MANIFEST=${MANIFEST//__PROXY_CONTROLPLANE_IMAGE_TAG__/${PROXY_CONTROLPLANE_IMAGE_TAG}}
MANIFEST=${MANIFEST//__PROXY_DATAPLANE_IMAGE_TAG__/${PROXY_DATAPLANE_IMAGE_TAG}}
MANIFEST=${MANIFEST//__INCIDENT_AGENT_IMAGE_TAG__/${INCIDENT_AGENT_IMAGE_TAG}}
MANIFEST=${MANIFEST//__PROXY_DATAPLANE_ROLE_ARN__/${PROXY_DATAPLANE_ROLE_ARN}}
MANIFEST=${MANIFEST//__INCIDENT_AGENT_ROLE_ARN__/${INCIDENT_AGENT_ROLE_ARN}}
MANIFEST=${MANIFEST//__INCIDENT_ALERTS_QUEUE_URL__/${INCIDENT_ALERTS_QUEUE_URL}}
MANIFEST=${MANIFEST//__INCIDENT_DATABASE_SECRET_ID__/${INCIDENT_DATABASE_SECRET_ID}}
MANIFEST=${MANIFEST//__APPLICATION_CERTIFICATE_ARN__/${APPLICATION_CERTIFICATE_ARN}}
MANIFEST=${MANIFEST//__COGNITO_USER_POOL_ARN__/${COGNITO_USER_POOL_ARN}}
MANIFEST=${MANIFEST//__COGNITO_CLIENT_ID__/${COGNITO_CLIENT_ID}}
MANIFEST=${MANIFEST//__COGNITO_DOMAIN__/${COGNITO_DOMAIN}}
MANIFEST=${MANIFEST//__SERVER_INVENTORY_STATIC_JSON__/${SERVER_INVENTORY_YAML}}

if grep -Eq '__[A-Z0-9_]+__|000000000000' <<<"${MANIFEST}"; then
  echo "Rendered manifests still contain unresolved placeholders." >&2
  exit 1
fi

kubectl apply -f - <<<"${MANIFEST}"

for deployment in session-manager sts proxy-dataplane proxy-controlplane incident-agent; do
  kubectl rollout status "deployment/${deployment}" -n "${NAMESPACE}" --timeout=5m
done

ALB_DNS_NAME=""
for _ in $(seq 1 60); do
  ALB_DNS_NAME=$(kubectl get ingress proxy-controlplane \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "${ALB_DNS_NAME}" ]]; then
    break
  fi
  sleep 10
done

if [[ -z "${ALB_DNS_NAME}" ]]; then
  echo "Workloads deployed, but the ALB hostname is not available yet." >&2
  exit 1
fi

echo
echo "ALB DNS name: ${ALB_DNS_NAME}"
echo "Create/update api.ddm.keiyam.me with:"
echo "terraform -chdir=${AWS_TERRAFORM_DIR} apply -var-file=secrets.tfvars -var application_alb_dns_name=${ALB_DNS_NAME}"
