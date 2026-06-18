#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

echo "deploy-aws.sh is now a compatibility wrapper for the GitOps flow."
echo "It bootstraps secrets/config, applies the Argo CD Application, then verifies the synced workloads."

"${ROOT_DIR}/scripts/bootstrap-aws.sh"
"${ROOT_DIR}/scripts/verify-aws.sh"
