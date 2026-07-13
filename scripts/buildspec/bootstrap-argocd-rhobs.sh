#!/usr/bin/env bash
# Bootstrap ArgoCD on a RHOBS Cluster.
# Called from: terraform/config/pipeline-rhobs-cluster/buildspec-bootstrap-argocd.yml
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check

ENVIRONMENT="${ENVIRONMENT:-staging}"
RHOBS_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-rhobs-cluster-inputs/terraform.json"
if [ ! -f "$RHOBS_CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $RHOBS_CONFIG_FILE" >&2
    exit 1
fi

DELETE_FLAG=$(jq -r '.delete // false' "$RHOBS_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "delete=true — skipping ArgoCD bootstrap"
    exit 0
fi

use_mc_account
terraform_init_backend rhobs-cluster "${TARGET_REGION}" "${REGIONAL_ID}"
bootstrap_argocd rhobs-cluster "${TARGET_ACCOUNT_ID}"
