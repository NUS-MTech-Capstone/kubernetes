#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE_DIR=$(cd "${ROOT_DIR}/.." && pwd)
AWS_TERRAFORM_DIR=${AWS_TERRAFORM_DIR:-"${WORKSPACE_DIR}/aws-terraform"}
TARGET_TERRAFORM_DIR=${TARGET_TERRAFORM_DIR:-"${WORKSPACE_DIR}/target-hosts-setup"}
AWS_REGION=${AWS_REGION:-ap-southeast-1}
NAMESPACE=dendenmushi
KEYSCAN_POD=dendenmushi-ssh-keyscan
OVERLAY_DIR="${ROOT_DIR}/apps/dendenmushi/overlays/dev"

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

tf_output() {
  terraform -chdir="$1" output -raw "$2"
}

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME=$(tf_output "${AWS_TERRAFORM_DIR}" cluster_name)
PROXY_DATAPLANE_ROLE_ARN=$(tf_output "${AWS_TERRAFORM_DIR}" proxy_dataplane_role_arn)
STS_ROLE_ARN=$(tf_output "${AWS_TERRAFORM_DIR}" sts_role_arn)
PROXY_CONTROLPLANE_ROLE_ARN=$(tf_output "${AWS_TERRAFORM_DIR}" proxy_controlplane_role_arn)
SESSION_MANAGER_ROLE_ARN=$(tf_output "${AWS_TERRAFORM_DIR}" session_manager_role_arn)
AUDIT_SERVICE_ROLE_ARN=$(tf_output "${AWS_TERRAFORM_DIR}" audit_service_role_arn)
INCIDENT_AGENT_ROLE_ARN=$(tf_output "${AWS_TERRAFORM_DIR}" incident_agent_role_arn)
AGENT_CONTROLPLANE_ROLE_ARN=$(tf_output "${AWS_TERRAFORM_DIR}" agent_controlplane_role_arn)
INCIDENT_ALERTS_QUEUE_URL=$(tf_output "${AWS_TERRAFORM_DIR}" incident_alerts_queue_url)
EVENTS_TOPIC_ARN=$(tf_output "${AWS_TERRAFORM_DIR}" events_topic_arn)
AUDIT_EVENTS_QUEUE_URL=$(tf_output "${AWS_TERRAFORM_DIR}" audit_events_queue_url)
INCIDENT_DATABASE_SECRET_ID=$(tf_output "${AWS_TERRAFORM_DIR}" incident_database_secret_id)
INCIDENT_AGENT_LANGSMITH_TRACING=${INCIDENT_AGENT_LANGSMITH_TRACING:-true}
INCIDENT_AGENT_LANGSMITH_API_KEY_SECRET_ID=$(tf_output "${AWS_TERRAFORM_DIR}" incident_agent_langsmith_api_key_secret_id)
INCIDENT_AGENT_LANGSMITH_PROJECT=$(tf_output "${AWS_TERRAFORM_DIR}" incident_agent_langsmith_project)
INCIDENT_AGENT_LANGSMITH_ENDPOINT=$(tf_output "${AWS_TERRAFORM_DIR}" incident_agent_langsmith_endpoint)
INCIDENT_AGENT_LANGSMITH_WORKSPACE_ID=$(tf_output "${AWS_TERRAFORM_DIR}" incident_agent_langsmith_workspace_id)
WEBAPP_DATABASE_SECRET_ID=$(tf_output "${AWS_TERRAFORM_DIR}" webapp_database_secret_id)
WEBAPP_DATABASE_BOOTSTRAP_SECRET_ID=$(tf_output "${AWS_TERRAFORM_DIR}" webapp_database_bootstrap_secret_id)
NEST_BACKEND_ROLE_ARN=$(tf_output "${AWS_TERRAFORM_DIR}" nest_backend_role_arn)
APPLICATION_CERTIFICATE_ARN=$(tf_output "${AWS_TERRAFORM_DIR}" application_certificate_arn)
COGNITO_USER_POOL_ARN=$(tf_output "${AWS_TERRAFORM_DIR}" cognito_user_pool_arn)
COGNITO_USER_POOL_ID=$(tf_output "${AWS_TERRAFORM_DIR}" cognito_user_pool_id)
COGNITO_CLIENT_ID=$(tf_output "${AWS_TERRAFORM_DIR}" cognito_client_id)
COGNITO_DOMAIN=$(tf_output "${AWS_TERRAFORM_DIR}" cognito_domain)

WEBAPP_ADMIN_COUNT=$(aws cognito-idp list-users-in-group \
  --region "${AWS_REGION}" \
  --user-pool-id "${COGNITO_USER_POOL_ID}" \
  --group-name Admin \
  --limit 1 \
  --query 'length(Users)' \
  --output text)
if [[ "${WEBAPP_ADMIN_COUNT}" == "0" ]]; then
  echo "Cognito group Admin has no operator. Add an Admin user before bootstrapping." >&2
  exit 1
fi

HOST_ID=$(tf_output "${TARGET_TERRAFORM_DIR}" host_id)
TARGET_ADDRESS=$(tf_output "${TARGET_TERRAFORM_DIR}" private_address)
SSH_USERNAME=$(tf_output "${TARGET_TERRAFORM_DIR}" ssh_username)
CONNECTION_TYPE=$(tf_output "${TARGET_TERRAFORM_DIR}" connection_type)
CREDENTIAL_SECRET_ID=$(tf_output "${TARGET_TERRAFORM_DIR}" credential_secret_id)
AUTOMATION_SERVICE_NAME=$(tf_output "${TARGET_TERRAFORM_DIR}" automation_service_name)
AUTOMATION_HEALTH_URL=$(tf_output "${TARGET_TERRAFORM_DIR}" automation_health_url)
AUTOMATION_HELPER_PATH=$(tf_output "${TARGET_TERRAFORM_DIR}" automation_helper_path)

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

WEBAPP_DATABASE_URL=$(aws secretsmanager get-secret-value \
  --region "${AWS_REGION}" \
  --secret-id "${WEBAPP_DATABASE_SECRET_ID}" \
  --query SecretString \
  --output text)
WEBAPP_DATABASE_URL=${WEBAPP_DATABASE_URL/sslmode=require/sslmode=no-verify}
kubectl create secret generic dendenmushi-webapp-database \
  -n "${NAMESPACE}" \
  --from-literal=database-url="${WEBAPP_DATABASE_URL}" \
  --dry-run=client \
  -o yaml | kubectl apply -f -
unset WEBAPP_DATABASE_URL

WEBAPP_BOOTSTRAP=$(aws secretsmanager get-secret-value \
  --region "${AWS_REGION}" \
  --secret-id "${WEBAPP_DATABASE_BOOTSTRAP_SECRET_ID}" \
  --query SecretString \
  --output text)
ADMIN_DATABASE_URL=$(aws secretsmanager get-secret-value \
  --region "${AWS_REGION}" \
  --secret-id "${INCIDENT_DATABASE_SECRET_ID}" \
  --query SecretString \
  --output text)
kubectl create secret generic dendenmushi-webapp-bootstrap \
  -n "${NAMESPACE}" \
  --from-literal=admin-database-url="${ADMIN_DATABASE_URL}" \
  --from-literal=database-name="$(jq -r .databaseName <<<"${WEBAPP_BOOTSTRAP}")" \
  --from-literal=username="$(jq -r .username <<<"${WEBAPP_BOOTSTRAP}")" \
  --from-literal=password="$(jq -r .password <<<"${WEBAPP_BOOTSTRAP}")" \
  --dry-run=client \
  -o yaml | kubectl apply -f -
unset WEBAPP_BOOTSTRAP ADMIN_DATABASE_URL

kubectl delete job webapp-database-bootstrap \
  -n "${NAMESPACE}" \
  --ignore-not-found \
  --wait=true
kubectl apply -f "${ROOT_DIR}/apps/dendenmushi/jobs/webapp-database-bootstrap.yaml"
if ! kubectl wait \
  --for=condition=complete \
  job/webapp-database-bootstrap \
  -n "${NAMESPACE}" \
  --timeout=5m; then
  kubectl logs job/webapp-database-bootstrap -n "${NAMESPACE}" >&2 || true
  exit 1
fi
kubectl delete secret dendenmushi-webapp-bootstrap -n "${NAMESPACE}"

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
      catalogVersion: "v1",
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
        "target_probe",
        "restart_service",
        "recover_demo_app",
        "reload_service"
      ]
    }
  }}')
printf '%s\n' "${SERVER_INVENTORY_STATIC_JSON}" >"${OVERLAY_DIR}/server-inventory.static.json"

APPLICATION_ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names dendenmushi-dev \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || true)
if [[ -z "${APPLICATION_ALB_ARN}" || "${APPLICATION_ALB_ARN}" == "None" ]]; then
  APPLICATION_ALB_ARN="arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:loadbalancer/app/dendenmushi-dev/pending"
fi

ALB_AUTH_IDP_COGNITO=$(jq -cn \
  --arg user_pool_arn "${COGNITO_USER_POOL_ARN}" \
  --arg client_id "${COGNITO_CLIENT_ID}" \
  --arg domain "${COGNITO_DOMAIN}" \
  '{userPoolARN: $user_pool_arn, userPoolClientID: $client_id, userPoolDomain: $domain}')

cat >"${OVERLAY_DIR}/env.properties" <<EOF
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}
AWS_REGION=${AWS_REGION}
PROXY_DATAPLANE_ROLE_ARN=${PROXY_DATAPLANE_ROLE_ARN}
STS_ROLE_ARN=${STS_ROLE_ARN}
PROXY_CONTROLPLANE_ROLE_ARN=${PROXY_CONTROLPLANE_ROLE_ARN}
SESSION_MANAGER_ROLE_ARN=${SESSION_MANAGER_ROLE_ARN}
AUDIT_SERVICE_ROLE_ARN=${AUDIT_SERVICE_ROLE_ARN}
NEST_BACKEND_ROLE_ARN=${NEST_BACKEND_ROLE_ARN}
INCIDENT_AGENT_ROLE_ARN=${INCIDENT_AGENT_ROLE_ARN}
AGENT_CONTROLPLANE_ROLE_ARN=${AGENT_CONTROLPLANE_ROLE_ARN}
INCIDENT_ALERTS_QUEUE_URL=${INCIDENT_ALERTS_QUEUE_URL}
EVENTS_TOPIC_ARN=${EVENTS_TOPIC_ARN}
AUDIT_EVENTS_QUEUE_URL=${AUDIT_EVENTS_QUEUE_URL}
INCIDENT_DATABASE_SECRET_ID=${INCIDENT_DATABASE_SECRET_ID}
INCIDENT_AGENT_LANGSMITH_TRACING=${INCIDENT_AGENT_LANGSMITH_TRACING}
INCIDENT_AGENT_LANGSMITH_API_KEY_SECRET_ID=${INCIDENT_AGENT_LANGSMITH_API_KEY_SECRET_ID}
INCIDENT_AGENT_LANGSMITH_PROJECT=${INCIDENT_AGENT_LANGSMITH_PROJECT}
INCIDENT_AGENT_LANGSMITH_ENDPOINT=${INCIDENT_AGENT_LANGSMITH_ENDPOINT}
INCIDENT_AGENT_LANGSMITH_WORKSPACE_ID=${INCIDENT_AGENT_LANGSMITH_WORKSPACE_ID}
APPLICATION_CERTIFICATE_ARN=${APPLICATION_CERTIFICATE_ARN}
APPLICATION_ALB_ARN=${APPLICATION_ALB_ARN}
COGNITO_USER_POOL_ARN=${COGNITO_USER_POOL_ARN}
COGNITO_USER_POOL_ID=${COGNITO_USER_POOL_ID}
COGNITO_CLIENT_ID=${COGNITO_CLIENT_ID}
COGNITO_DOMAIN=${COGNITO_DOMAIN}
COGNITO_DOMAIN_URL=${COGNITO_DOMAIN}.auth.${AWS_REGION}.amazoncognito.com
ALB_AUTH_IDP_COGNITO=${ALB_AUTH_IDP_COGNITO}
EOF

kubectl kustomize "${OVERLAY_DIR}" >/dev/null

if [[ "${APPLY_ARGOCD_APPLICATION:-true}" == "true" ]]; then
  kubectl apply -f "${ROOT_DIR}/argocd/dendenmushi-dev-application.yaml"
fi

echo "Bootstrapped Kubernetes secrets and refreshed ${OVERLAY_DIR}."
echo "Review and commit env.properties and server-inventory.static.json before relying on Argo CD sync."
