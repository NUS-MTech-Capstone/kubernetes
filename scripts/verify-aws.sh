#!/usr/bin/env bash
set -euo pipefail

AWS_REGION=${AWS_REGION:-ap-southeast-1}
EXPECTED_AWS_ACCOUNT_ID=${EXPECTED_AWS_ACCOUNT_ID:-891377133321}
SSH_NAMESPACE=${SSH_NAMESPACE:-dendenmushi-ssh}
AGENTIC_NAMESPACE=${AGENTIC_NAMESPACE:-dendenmushi-agentic}
WEBAPP_NAMESPACE=${WEBAPP_NAMESPACE:-dendenmushi-webapp}
APPLICATION_URL=${APPLICATION_URL:-https://api.ddm.keiyam.me}
PROTOCOL_PROBE_NAME=${PROTOCOL_PROBE_NAME:-agent-protocol-verification}

for command in aws terraform kubectl curl jq ruby; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
done

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE_DIR=$(cd "${ROOT_DIR}/.." && pwd)
AWS_TERRAFORM_DIR=${AWS_TERRAFORM_DIR:-"${WORKSPACE_DIR}/aws-terraform"}
TARGET_TERRAFORM_DIR=${TARGET_TERRAFORM_DIR:-"${WORKSPACE_DIR}/target-hosts-setup"}
CLUSTER_NAME=$(terraform -chdir="${AWS_TERRAFORM_DIR}" output -raw cluster_name)

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [[ "${AWS_ACCOUNT_ID}" != "${EXPECTED_AWS_ACCOUNT_ID}" ]]; then
  echo "Refusing to verify account ${AWS_ACCOUNT_ID}; expected ${EXPECTED_AWS_ACCOUNT_ID}." >&2
  exit 1
fi

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

if kubectl get deployment sts -n "${SSH_NAMESPACE}" -o json |
  jq -e '.spec.template.spec.containers[] | select(.name == "sts") | .env[]? | select(.name == "SERVER_INVENTORY_URL")' >/dev/null; then
  echo "STS still has SERVER_INVENTORY_URL; trusted target inventory must be static." >&2
  exit 1
fi

TARGET_HOST_ID=$(terraform -chdir="${TARGET_TERRAFORM_DIR}" output -raw host_id)
TARGET_ADDRESS=$(terraform -chdir="${TARGET_TERRAFORM_DIR}" output -raw private_address)
STATIC_INVENTORY=$(kubectl get configmap dendenmushi-config -n "${SSH_NAMESPACE}" \
  -o jsonpath='{.data.SERVER_INVENTORY_STATIC_JSON}')
if ! jq -e --arg host_id "${TARGET_HOST_ID}" --arg address "${TARGET_ADDRESS}:22" \
  '.[$host_id].address == $address' <<<"${STATIC_INVENTORY}" >/dev/null; then
  echo "STS static target inventory does not match the Terraform target address." >&2
  exit 1
fi

AWS_PROFILE=${AWS_PROFILE:-capstone} \
SKIP_KUBECONFIG_UPDATE=true \
AWS_TERRAFORM_DIR="${AWS_TERRAFORM_DIR}" \
TARGET_TERRAFORM_DIR="${TARGET_TERRAFORM_DIR}" \
EXPECTED_AWS_ACCOUNT_ID="${EXPECTED_AWS_ACCOUNT_ID}" \
"${ROOT_DIR}/scripts/reconcile-webapp-target.sh" --verify-only

if kubectl get application dendenmushi-dev -n argocd >/dev/null 2>&1; then
  kubectl get application dendenmushi-dev -n argocd
  ARGO_SYNC=$(kubectl get application dendenmushi-dev -n argocd -o jsonpath='{.status.sync.status}')
  ARGO_HEALTH=$(kubectl get application dendenmushi-dev -n argocd -o jsonpath='{.status.health.status}')
  if [[ "${ARGO_SYNC}" != "Synced" || "${ARGO_HEALTH}" != "Healthy" ]]; then
    echo "Argo CD is not ready: sync=${ARGO_SYNC:-unknown} health=${ARGO_HEALTH:-unknown}." >&2
    exit 1
  fi
fi

for deployment in session-manager audit-service sts proxy-dataplane proxy-controlplane; do
  kubectl rollout status "deployment/${deployment}" -n "${SSH_NAMESPACE}" --timeout=5m
done
for deployment in agent-controlplane incident-agent incident-reasoning-agent agent-tool-gateway; do
  kubectl rollout status "deployment/${deployment}" -n "${AGENTIC_NAMESPACE}" --timeout=5m
done
for deployment in redis nest-backend angular; do
  kubectl rollout status "deployment/${deployment}" -n "${WEBAPP_NAMESPACE}" --timeout=5m
done

ruby "${ROOT_DIR}/scripts/verify-image-digests.rb" --live "${ROOT_DIR}/apps/dendenmushi/overlays/dev"

DEPLOYMENT_COUNT=$(kubectl get deployment --all-namespaces -l app=dendenmushi -o name | wc -l | tr -d ' ')
if [[ "${DEPLOYMENT_COUNT}" != "12" ]]; then
  echo "Expected 12 DenDenMushi deployments, found ${DEPLOYMENT_COUNT}." >&2
  exit 1
fi

ALB_DNS_NAME=$(kubectl get ingress \
  --all-namespaces \
  -l app=dendenmushi \
  -o jsonpath='{range .items[*].status.loadBalancer.ingress[*]}{.hostname}{"\n"}{end}' \
  2>/dev/null | sed -n '1p' || true)
if [[ -z "${ALB_DNS_NAME}" ]]; then
  echo "The application ALB hostname is not available yet." >&2
  exit 1
fi

curl -fsS "${APPLICATION_URL}/healthz" >/dev/null
curl -fsS "${APPLICATION_URL}/readyz" >/dev/null

ROOT_HEADERS=$(mktemp)
AUTH_HEADERS=$(mktemp)
cleanup() {
  rm -f -- "${ROOT_HEADERS}" "${AUTH_HEADERS}"
  kubectl delete pod "${PROTOCOL_PROBE_NAME}" -n "${AGENTIC_NAMESPACE}" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

assert_response_header() {
  local file=$1
  local name=$2
  local expected=$3
  local value
  value=$(grep -i -m 1 "^${name}:" "${file}" | tr -d '\r' || true)
  if [[ "${value}" != *"${expected}"* ]]; then
    echo "Expected ${name} to contain '${expected}', got '${value}'" >&2
    exit 1
  fi
}

curl -fsS -D "${ROOT_HEADERS}" -o /dev/null "${APPLICATION_URL}/"
assert_response_header "${ROOT_HEADERS}" "Strict-Transport-Security" "max-age=31536000"
assert_response_header "${ROOT_HEADERS}" "X-Content-Type-Options" "nosniff"
assert_response_header "${ROOT_HEADERS}" "X-Frame-Options" "DENY"
assert_response_header "${ROOT_HEADERS}" "Referrer-Policy" "strict-origin-when-cross-origin"
assert_response_header "${ROOT_HEADERS}" "Permissions-Policy" "camera=(), microphone=(), geolocation=()"
assert_response_header "${ROOT_HEADERS}" "Content-Security-Policy" "default-src 'self'"
APPLICATION_URL="${APPLICATION_URL}" bash "${ROOT_DIR}/scripts/verify-csp.sh"

# This protected request is expected to be denied by Cognito at the ALB. Its
# response still needs the listener-level headers even though no pod handles it.
curl -sS -D "${AUTH_HEADERS}" -o /dev/null "${APPLICATION_URL}/sessions"
assert_response_header "${AUTH_HEADERS}" "Strict-Transport-Security" "max-age=31536000"
assert_response_header "${AUTH_HEADERS}" "X-Content-Type-Options" "nosniff"
assert_response_header "${AUTH_HEADERS}" "X-Frame-Options" "DENY"

for namespace in "${SSH_NAMESPACE}" "${AGENTIC_NAMESPACE}" "${WEBAPP_NAMESPACE}"; do
  kubectl get resourcequota,limitrange,networkpolicy -n "${namespace}"
done

NETWORK_POLICY_AGENT=$(kubectl get daemonset aws-node -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-eks-nodeagent")].name}')
NETWORK_POLICY_MODE=$(kubectl get daemonset aws-node -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-node")].env[?(@.name=="NETWORK_POLICY_ENFORCING_MODE")].value}')
if [[ "${NETWORK_POLICY_AGENT}" != "aws-eks-nodeagent" || "${NETWORK_POLICY_MODE}" != "standard" ]]; then
  echo "AWS VPC CNI NetworkPolicy support is not ready in standard mode." >&2
  exit 1
fi

"${ROOT_DIR}/scripts/verify-network-policies.sh"

PROTOCOL_IMAGE=$(kubectl get deployment incident-agent -n "${AGENTIC_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="incident-agent")].image}')
kubectl delete pod "${PROTOCOL_PROBE_NAME}" -n "${AGENTIC_NAMESPACE}" \
  --ignore-not-found --wait=true >/dev/null
kubectl run "${PROTOCOL_PROBE_NAME}" \
  -n "${AGENTIC_NAMESPACE}" \
  --restart=Never \
  --image="${PROTOCOL_IMAGE}" \
  --labels="app=dendenmushi,component=incident-agent,network-policy-probe=true" \
  --dry-run=client \
  -o json \
  --command -- sleep 300 |
  jq '
    .spec.serviceAccountName = "incident-agent" |
    .spec.automountServiceAccountToken = false |
    .spec.securityContext.seccompProfile.type = "RuntimeDefault" |
    .spec.containers[0].securityContext = {
      "allowPrivilegeEscalation": false,
      "capabilities": {"drop": ["ALL"]},
      "runAsNonRoot": true
    } |
    .spec.containers[0].resources = {
      "requests": {"cpu": "25m", "memory": "64Mi"},
      "limits": {"cpu": "250m", "memory": "256Mi"}
    } |
    .spec.containers[0].volumeMounts = [{
      "name": "workload-token",
      "mountPath": "/var/run/secrets/tokens",
      "readOnly": true
    }] |
    .spec.volumes = [{
      "name": "workload-token",
      "projected": {"sources": [{
        "serviceAccountToken": {
          "audience": "dendenmushi-incident-agent",
          "expirationSeconds": 900,
          "path": "incident-agent-token"
        }
      }]}
    }]
  ' |
  kubectl apply -f - >/dev/null
kubectl wait pod "${PROTOCOL_PROBE_NAME}" -n "${AGENTIC_NAMESPACE}" \
  --for=condition=Ready --timeout=2m >/dev/null

kubectl exec -i -n "${AGENTIC_NAMESPACE}" "${PROTOCOL_PROBE_NAME}" -- python - <<'PY'
import asyncio
import json
import urllib.request

import httpx2
from mcp import Client
from mcp.client.streamable_http import streamable_http_client

token = open("/var/run/secrets/tokens/incident-agent-token", encoding="utf-8").read().strip()
card_request = urllib.request.Request(
    "http://incident-reasoning-agent.dendenmushi-agentic.svc.cluster.local:8093/.well-known/agent-card.json",
    headers={"Authorization": f"Bearer {token}"},
)
with urllib.request.urlopen(card_request, timeout=5) as response:
    card = json.load(response)
if not any(skill.get("id") == "analyze_incident" for skill in card.get("skills", [])):
    raise RuntimeError("A2A analyze_incident skill is unavailable")


async def verify_mcp() -> None:
    async with httpx2.AsyncClient(headers={"Authorization": f"Bearer {token}"}, timeout=10) as http_client:
        transport = streamable_http_client(
            "http://agent-tool-gateway.dendenmushi-agentic.svc.cluster.local:8094/mcp",
            http_client=http_client,
        )
        async with Client(transport, read_timeout_seconds=10) as client:
            tools = await client.list_tools()
            names = {tool.name for tool in tools.tools}
            if not {"service_status", "health_check"}.issubset(names):
                raise RuntimeError("required diagnostic tools are unavailable")
            if "restart_service" in names:
                raise RuntimeError("coordinator can discover a remediation tool")
            denied = await client.call_tool("restart_service", {"runId": "verification-only"})
            if not denied.is_error:
                raise RuntimeError("default-deny MCP policy did not reject remediation discovery bypass")


asyncio.run(verify_mcp())
PY

echo "ALB DNS name: ${ALB_DNS_NAME}"
echo "Create/update api.ddm.keiyam.me with:"
echo "terraform -chdir=${AWS_TERRAFORM_DIR} apply -var-file=secrets.tfvars -var-file=teammate-access.local.tfvars -var application_alb_dns_name=${ALB_DNS_NAME}"
