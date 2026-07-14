#!/usr/bin/env bash
# Bootstrap ArgoCD on a Management Cluster.
# Called from: terraform/config/pipeline-management-cluster/buildspec-bootstrap-argocd.yml
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load management

RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

DELETE_FLAG=$(jq -r '.delete // false' "$DEPLOY_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "delete=true — skipping ArgoCD bootstrap"
    exit 0
fi

# Read RHOBS API URL from RHOBS cluster terraform state.
# The RHOBS pipeline runs in parallel — wait for the output to appear.
_RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
_RC_REGIONAL_ID=$(jq -r '.regional_id // "regional"' "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json" 2>/dev/null || echo "regional")
# RHOBS state key uses the provisioner config's regional_id (e.g. "rhobs" or
# "eph-xxx-rhobs"), NOT the terraform config's regional_id which refers to
# the RC's regional_id used for VPC naming.
_RHOBS_REGIONAL_ID=$(jq -r '.regional_id // "rhobs"' "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-provisioner-inputs/rhobs-cluster.json" 2>/dev/null || echo "rhobs")
_RHOBS_STATE_KEY="rhobs-cluster/${_RHOBS_REGIONAL_ID}.tfstate"
_RHOBS_TF_DIR="terraform/config/rhobs-cluster"

use_rc_account
(cd "$_RHOBS_TF_DIR" && terraform init -reconfigure \
    -backend-config="bucket=${_RC_STATE_BUCKET}" \
    -backend-config="key=${_RHOBS_STATE_KEY}" \
    -backend-config="region=${TARGET_REGION}" \
    -backend-config="use_lockfile=true" >/dev/null 2>&1)

_RHOBS_JSON=$(wait_for_remote_outputs "$_RHOBS_TF_DIR" 2700 "RHOBS" \
    --upstream-pipeline "${_RHOBS_REGIONAL_ID}-pipe" \
    rhobs_api_url) || exit 1
export RHOBS_API_URL=$(echo "$_RHOBS_JSON" | jq -r '.rhobs_api_url.value')

export DNS_ZONE_OPERATOR_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-dns-zone-operator"

use_mc_account
terraform_init_backend management-cluster "${TARGET_REGION}" "${MANAGEMENT_ID}"
bootstrap_argocd management-cluster "${TARGET_ACCOUNT_ID}"
