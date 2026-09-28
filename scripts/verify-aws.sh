#!/usr/bin/env bash
set -euo pipefail

AWS_REGION=${AWS_REGION:-ap-southeast-1}
SSH_NAMESPACE=${SSH_NAMESPACE:-dendenmushi-ssh}
AGENTIC_NAMESPACE=${AGENTIC_NAMESPACE:-dendenmushi-agentic}
WEBAPP_NAMESPACE=${WEBAPP_NAMESPACE:-dendenmushi-webapp}
APPLICATION_URL=${APPLICATION_URL:-https://api.ddm.keiyam.me}

for command in aws terraform kubectl curl; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
done

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE_DIR=$(cd "${ROOT_DIR}/.." && pwd)
AWS_TERRAFORM_DIR=${AWS_TERRAFORM_DIR:-"${WORKSPACE_DIR}/aws-terraform"}
CLUSTER_NAME=$(terraform -chdir="${AWS_TERRAFORM_DIR}" output -raw cluster_name)

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

if kubectl get application dendenmushi-dev -n argocd >/dev/null 2>&1; then
  kubectl get application dendenmushi-dev -n argocd
fi

for deployment in session-manager audit-service sts proxy-dataplane proxy-controlplane; do
  kubectl rollout status "deployment/${deployment}" -n "${SSH_NAMESPACE}" --timeout=5m
done
for deployment in agent-controlplane incident-agent; do
  kubectl rollout status "deployment/${deployment}" -n "${AGENTIC_NAMESPACE}" --timeout=5m
done
for deployment in nest-backend angular; do
  kubectl rollout status "deployment/${deployment}" -n "${WEBAPP_NAMESPACE}" --timeout=5m
done

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
trap 'rm -f -- "${ROOT_HEADERS}" "${AUTH_HEADERS}"' EXIT

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

echo "ALB DNS name: ${ALB_DNS_NAME}"
echo "Create/update api.ddm.keiyam.me with:"
echo "terraform -chdir=${AWS_TERRAFORM_DIR} apply -var-file=secrets.tfvars -var application_alb_dns_name=${ALB_DNS_NAME}"
