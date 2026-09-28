#!/usr/bin/env bash
set -euo pipefail

SSH_NAMESPACE=${SSH_NAMESPACE:-dendenmushi-ssh}
AGENTIC_NAMESPACE=${AGENTIC_NAMESPACE:-dendenmushi-agentic}
WEBAPP_NAMESPACE=${WEBAPP_NAMESPACE:-dendenmushi-webapp}
PROBE_IMAGE=${PROBE_IMAGE:-curlimages/curl:8.12.1}

for command in kubectl jq; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
done

cleanup() {
  for namespace in "${SSH_NAMESPACE}" "${AGENTIC_NAMESPACE}" "${WEBAPP_NAMESPACE}"; do
    kubectl delete pod -n "${namespace}" -l network-policy-probe=true --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

run_probe() {
  local name=$1
  local namespace=$2
  local component=$3
  local expected=$4
  local url=$5

  kubectl delete pod "${name}" -n "${namespace}" --ignore-not-found --wait=true >/dev/null
  kubectl run "${name}" \
    -n "${namespace}" \
    --restart=Never \
    --image="${PROBE_IMAGE}" \
    --labels="component=${component},network-policy-probe=true" \
    --dry-run=client \
    -o json \
    --command -- sh -ec "curl --connect-timeout 3 --max-time 5 -fsS '${url}' >/dev/null" |
    jq '
      .spec.securityContext.seccompProfile.type = "RuntimeDefault" |
      .spec.containers[0].securityContext = {
        "allowPrivilegeEscalation": false,
        "capabilities": {"drop": ["ALL"]},
        "runAsNonRoot": true,
        "runAsUser": 100
      } |
      .spec.containers[0].resources = {
        "requests": {"cpu": "10m", "memory": "16Mi"},
        "limits": {"cpu": "100m", "memory": "64Mi"}
      }
    ' |
    kubectl apply -f - >/dev/null

  local phase=""
  for _ in $(seq 1 20); do
    phase=$(kubectl get pod "${name}" -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]]; then
      break
    fi
    sleep 1
  done

  if [[ "${phase}" != "Succeeded" && "${phase}" != "Failed" ]]; then
    kubectl describe pod "${name}" -n "${namespace}" >&2 || true
    echo "NetworkPolicy probe did not finish: ${namespace}/${name} (phase=${phase:-unknown})" >&2
    exit 1
  fi

  if [[ "${expected}" == "allow" && "${phase}" != "Succeeded" ]]; then
    kubectl logs "${name}" -n "${namespace}" >&2 || true
    echo "Expected allowed path failed: ${namespace}/${component} -> ${url}" >&2
    exit 1
  fi
  if [[ "${expected}" == "deny" && "${phase}" != "Failed" ]]; then
    echo "Expected denied path succeeded: ${namespace}/${component} -> ${url}" >&2
    exit 1
  fi
}

run_probe np-proxy-to-session "${SSH_NAMESPACE}" proxy-controlplane allow \
  "http://session-manager.${SSH_NAMESPACE}.svc.cluster.local:8081/healthz"
run_probe np-agent-to-sts "${AGENTIC_NAMESPACE}" agent-controlplane allow \
  "http://sts.${SSH_NAMESPACE}.svc.cluster.local:8082/healthz"
run_probe np-nest-to-audit "${WEBAPP_NAMESPACE}" nest-backend allow \
  "http://audit-service.${SSH_NAMESPACE}.svc.cluster.local:8085/healthz"
run_probe np-angular-to-sts "${WEBAPP_NAMESPACE}" angular deny \
  "http://sts.${SSH_NAMESPACE}.svc.cluster.local:8082/healthz"
run_probe np-incident-to-session "${AGENTIC_NAMESPACE}" incident-agent deny \
  "http://session-manager.${SSH_NAMESPACE}.svc.cluster.local:8081/healthz"

echo "NetworkPolicy allow and deny probes passed."
