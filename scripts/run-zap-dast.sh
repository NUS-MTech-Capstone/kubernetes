#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

TARGET_URL=${TARGET_URL:-https://api.ddm.keiyam.me}
TARGET_URL=${TARGET_URL%/}
ZAP_IMAGE=${ZAP_IMAGE:-ghcr.io/zaproxy/zaproxy:2.17.0}
REPORT_DIR=${REPORT_DIR:-"${ROOT_DIR}/dast-results"}
ZAP_PLAN=${ZAP_PLAN:-"${ROOT_DIR}/security/zap-automation.yaml"}

if ! command -v docker >/dev/null 2>&1; then
  echo "Required command not found: docker" >&2
  exit 1
fi

if [[ ! "${TARGET_URL}" =~ ^https?://[^/]+$ ]]; then
  echo "TARGET_URL must be an HTTP(S) origin without a path: ${TARGET_URL}" >&2
  exit 1
fi

if [[ ! -f "${ZAP_PLAN}" ]]; then
  echo "ZAP automation plan not found: ${ZAP_PLAN}" >&2
  exit 1
fi

mkdir -p "${REPORT_DIR}"
REPORT_DIR=$(cd "${REPORT_DIR}" && pwd)
REPORT_FILE=${REPORT_DIR}/zap-report.html

# The official image runs as its unprivileged zap user. Only this dedicated,
# ignored output directory is made container-writable.
chmod a+rwx "${REPORT_DIR}"
trap 'chmod 0755 "${REPORT_DIR}"' EXIT
rm -f "${REPORT_FILE}"

echo "Running unauthenticated passive DAST against ${TARGET_URL}"
echo "ZAP image: ${ZAP_IMAGE}"

docker run --rm \
  --env "TARGET_URL=${TARGET_URL}" \
  --volume "${ZAP_PLAN}:/zap/wrk/zap-automation.yaml:ro" \
  --volume "${REPORT_DIR}:/zap/wrk/reports:rw" \
  "${ZAP_IMAGE}" \
  zap.sh -cmd -autorun /zap/wrk/zap-automation.yaml

if [[ ! -s "${REPORT_FILE}" ]]; then
  echo "ZAP did not produce a non-empty HTML report: ${REPORT_FILE}" >&2
  exit 1
fi

echo "ZAP HTML report: ${REPORT_FILE}"
