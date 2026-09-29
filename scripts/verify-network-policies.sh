#!/usr/bin/env bash
set -euo pipefail

SSH_NAMESPACE=${SSH_NAMESPACE:-dendenmushi-ssh}
AGENTIC_NAMESPACE=${AGENTIC_NAMESPACE:-dendenmushi-agentic}
WEBAPP_NAMESPACE=${WEBAPP_NAMESPACE:-dendenmushi-webapp}
PROBE_IMAGE=${PROBE_IMAGE:-curlimages/curl:8.12.1}
REDIS_PROBE_IMAGE=${REDIS_PROBE_IMAGE:-redis:8-alpine@sha256:2d3814be5e9b06a30a0be54770b7e12052e7e79ec85271aefd34875c1f393b23}
POLICY_SETTLE_SECONDS=${POLICY_SETTLE_SECONDS:-5}

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
  local image=$5
  local run_as_user=$6
  local command=$7

  kubectl delete pod "${name}" -n "${namespace}" --ignore-not-found --wait=true >/dev/null
  kubectl run "${name}" \
    -n "${namespace}" \
    --restart=Never \
    --image="${image}" \
    --labels="component=${component},network-policy-probe=true" \
    --dry-run=client \
    -o json \
    --command -- sh -ec "sleep ${POLICY_SETTLE_SECONDS}; ${command}" |
    jq --argjson run_as_user "${run_as_user}" '
      .spec.securityContext.seccompProfile.type = "RuntimeDefault" |
      .spec.containers[0].securityContext = {
        "allowPrivilegeEscalation": false,
        "capabilities": {"drop": ["ALL"]},
        "runAsNonRoot": true,
        "runAsUser": $run_as_user
      } |
      .spec.containers[0].resources = {
        "requests": {"cpu": "10m", "memory": "16Mi"},
        "limits": {"cpu": "100m", "memory": "64Mi"}
      }
    ' |
    kubectl apply -f - >/dev/null

  local phase=""
  for _ in $(seq 1 40); do
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
    echo "Expected allowed path failed: ${namespace}/${component}: ${command}" >&2
    exit 1
  fi
  if [[ "${expected}" == "deny" && "${phase}" != "Failed" ]]; then
    echo "Expected denied path succeeded: ${namespace}/${component}: ${command}" >&2
    exit 1
  fi
}

run_probe np-proxy-to-session "${SSH_NAMESPACE}" proxy-controlplane allow "${PROBE_IMAGE}" 100 \
  "curl --connect-timeout 3 --max-time 5 -fsS 'http://session-manager.${SSH_NAMESPACE}.svc.cluster.local:8081/healthz' >/dev/null"
run_probe np-agent-to-sts "${AGENTIC_NAMESPACE}" agent-controlplane allow "${PROBE_IMAGE}" 100 \
  "curl --connect-timeout 3 --max-time 5 -fsS 'http://sts.${SSH_NAMESPACE}.svc.cluster.local:8082/healthz' >/dev/null"
run_probe np-incident-to-reasoning "${AGENTIC_NAMESPACE}" incident-agent allow "${PROBE_IMAGE}" 100 \
  "curl --connect-timeout 3 --max-time 5 -fsS 'http://incident-reasoning-agent.${AGENTIC_NAMESPACE}.svc.cluster.local:8093/healthz' >/dev/null"
run_probe np-incident-to-gateway "${AGENTIC_NAMESPACE}" incident-agent allow "${PROBE_IMAGE}" 100 \
  "curl --connect-timeout 3 --max-time 5 -fsS 'http://agent-tool-gateway.${AGENTIC_NAMESPACE}.svc.cluster.local:8094/healthz' >/dev/null"
run_probe np-gateway-to-dataplane "${AGENTIC_NAMESPACE}" agent-tool-gateway allow "${PROBE_IMAGE}" 100 \
  "curl --connect-timeout 3 --max-time 5 -fsS 'http://proxy-dataplane.${SSH_NAMESPACE}.svc.cluster.local:8083/healthz' >/dev/null"
run_probe np-invalid-websocket-origin "${AGENTIC_NAMESPACE}" agent-tool-gateway allow "${PROBE_IMAGE}" 100 \
  "test \"\$(curl --connect-timeout 3 --max-time 5 -sS -o /dev/null -w '%{http_code}' -H 'Origin: https://invalid.example' 'http://proxy-dataplane.${SSH_NAMESPACE}.svc.cluster.local:8083/sessions/verification/ws?apiVersion=1')\" = 403"
run_probe np-controlplane-to-dataplane "${AGENTIC_NAMESPACE}" agent-controlplane deny "${PROBE_IMAGE}" 100 \
  "curl --connect-timeout 3 --max-time 5 -fsS 'http://proxy-dataplane.${SSH_NAMESPACE}.svc.cluster.local:8083/healthz' >/dev/null"
run_probe np-reasoning-to-controlplane "${AGENTIC_NAMESPACE}" incident-reasoning-agent deny "${PROBE_IMAGE}" 100 \
  "curl --connect-timeout 3 --max-time 5 -fsS 'http://agent-controlplane.${AGENTIC_NAMESPACE}.svc.cluster.local:8092/healthz' >/dev/null"
run_probe np-nest-to-audit "${WEBAPP_NAMESPACE}" nest-backend allow "${PROBE_IMAGE}" 100 \
  "curl --connect-timeout 3 --max-time 5 -fsS 'http://audit-service.${SSH_NAMESPACE}.svc.cluster.local:8085/healthz' >/dev/null"
run_probe np-angular-to-sts "${WEBAPP_NAMESPACE}" angular deny "${PROBE_IMAGE}" 100 \
  "curl --connect-timeout 3 --max-time 5 -fsS 'http://sts.${SSH_NAMESPACE}.svc.cluster.local:8082/healthz' >/dev/null"
run_probe np-incident-to-session "${AGENTIC_NAMESPACE}" incident-agent deny "${PROBE_IMAGE}" 100 \
  "curl --connect-timeout 3 --max-time 5 -fsS 'http://session-manager.${SSH_NAMESPACE}.svc.cluster.local:8081/healthz' >/dev/null"
run_probe np-nest-to-redis "${WEBAPP_NAMESPACE}" nest-backend allow "${REDIS_PROBE_IMAGE}" 999 \
  "timeout 5 redis-cli -h redis.${WEBAPP_NAMESPACE}.svc.cluster.local -p 6379 ping | grep -qx PONG"
run_probe np-angular-to-redis "${WEBAPP_NAMESPACE}" angular deny "${REDIS_PROBE_IMAGE}" 999 \
  "timeout 5 redis-cli -h redis.${WEBAPP_NAMESPACE}.svc.cluster.local -p 6379 ping | grep -qx PONG"

echo "NetworkPolicy allow and deny probes passed."
