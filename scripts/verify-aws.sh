#!/usr/bin/env bash
set -euo pipefail

AWS_REGION=${AWS_REGION:-ap-southeast-1}
NAMESPACE=${NAMESPACE:-dendenmushi}
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

for deployment in session-manager sts agent-controlplane proxy-dataplane proxy-controlplane incident-agent nest-backend angular; do
  kubectl rollout status "deployment/${deployment}" -n "${NAMESPACE}" --timeout=5m
done

ALB_DNS_NAME=$(kubectl get ingress proxy-controlplane \
  -n "${NAMESPACE}" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [[ -z "${ALB_DNS_NAME}" ]]; then
  echo "The application ALB hostname is not available yet." >&2
  exit 1
fi

curl -fsS "${APPLICATION_URL}/healthz" >/dev/null
curl -fsS "${APPLICATION_URL}/readyz" >/dev/null

echo "ALB DNS name: ${ALB_DNS_NAME}"
echo "Create/update api.ddm.keiyam.me with:"
echo "terraform -chdir=${AWS_TERRAFORM_DIR} apply -var-file=secrets.tfvars -var application_alb_dns_name=${ALB_DNS_NAME}"
