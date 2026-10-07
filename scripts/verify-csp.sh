#!/usr/bin/env bash
set -euo pipefail

APPLICATION_URL=${APPLICATION_URL:-https://api.ddm.keiyam.me}
APPLICATION_URL=${APPLICATION_URL%/}
EXPECTED_WEBSOCKET_ORIGIN=${EXPECTED_WEBSOCKET_ORIGIN:-wss://api.ddm.keiyam.me}
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "${WORK_DIR}"' EXIT

header_value() {
  awk -v name="$2" 'tolower($0) ~ "^" tolower(name) ":" {
    sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit
  }' "$1"
}

previous_nonce=
for attempt in 1 2; do
  curl --fail --silent --show-error --max-time 20 \
    -D "${WORK_DIR}/headers" -o "${WORK_DIR}/body" "${APPLICATION_URL}/"
  csp=$(header_value "${WORK_DIR}/headers" Content-Security-Policy)
  nonce=$(printf '%s\n' "${csp}" | sed -nE "s/.*style-src 'self' 'nonce-([0-9a-f]{32})';.*/\1/p")
  if [[ -z "${nonce}" || "${csp}" == *"'unsafe-inline'"* \
    || "${csp}" != *"connect-src 'self' ${EXPECTED_WEBSOCKET_ORIGIN};"* ]]; then
    echo "Angular CSP must contain a response nonce and the explicit WebSocket origin." >&2
    exit 1
  fi
  if ! grep -Eiq "ngcspnonce=[\"']${nonce}[\"']" "${WORK_DIR}/body" \
    || grep -q '__DDM_CSP_NONCE__' "${WORK_DIR}/body"; then
    echo "Angular HTML nonce does not match its response CSP." >&2
    exit 1
  fi
  if [[ "$(header_value "${WORK_DIR}/headers" Cache-Control)" != *no-store* ]]; then
    echo "Angular HTML must use Cache-Control: no-store." >&2
    exit 1
  fi
  if [[ "${attempt}" == 2 && "${nonce}" == "${previous_nonce}" ]]; then
    echo "Angular CSP nonce was reused across document responses." >&2
    exit 1
  fi
  previous_nonce=${nonce}
done

echo "Angular CSP verified: fresh matching nonces, explicit WebSocket origin and no-store HTML."
