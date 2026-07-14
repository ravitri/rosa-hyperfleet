#!/usr/bin/env bash
# Provision or destroy Management Cluster infrastructure.
# Called from: terraform/config/pipeline-management-cluster/buildspec-provision-infra.yml
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load management

RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

# Determine terraform action
DELETE_FLAG=$(jq -r '.delete // false' "$DEPLOY_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

TERRAFORM_ACTION="apply"
[ "${DELETE_FLAG}" == "true" ] && TERRAFORM_ACTION="destroy"

echo "MC ${MANAGEMENT_ID}: terraform ${TERRAFORM_ACTION} in ${TARGET_ACCOUNT_ID}/${TARGET_REGION}"

# ── Phase 1: Read IoT cert/config and OIDC outputs from RC account ───────────
if [ "${DELETE_FLAG}" == "true" ]; then
    # Provide placeholders so terraform destroy can pass the planning phase.
    export TF_VAR_maestro_agent_cert_file=$(mktemp)
    export TF_VAR_maestro_agent_config_file=$(mktemp)
    export TF_VAR_oidc_cloudfront_domain="placeholder"
    export TF_VAR_oidc_bucket_name="placeholder"
    export TF_VAR_oidc_bucket_arn="arn:aws:s3:::placeholder"
    export TF_VAR_oidc_bucket_region="us-east-1"
else
    use_rc_account
    read_iot_state "$RESOLVED_REGIONAL_ACCOUNT_ID" "$CLUSTER_ID" "$TARGET_REGION"

    _RC_REGIONAL_ID=$(jq -r '.regional_id // "regional"' "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json" 2>/dev/null || echo "regional")
    export DNS_ZONE_OPERATOR_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-dns-zone-operator"
    export OIDC_WRITER_ROLE_ARN="arn:aws:iam::${RESOLVED_REGIONAL_ACCOUNT_ID}:role/${_RC_REGIONAL_ID}-oidc-writer"

    # Read RC outputs (OIDC + ZOA). RC and MC pipelines run in parallel — wait
    # for ALL required outputs before proceeding (up to 45 min).
    _RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
    _RC_STATE_KEY="regional-cluster/${_RC_REGIONAL_ID}.tfstate"
    _RC_TF_DIR="terraform/config/regional-cluster"
    (cd "$_RC_TF_DIR" && terraform init -reconfigure \
        -backend-config="bucket=${_RC_STATE_BUCKET}" \
        -backend-config="key=${_RC_STATE_KEY}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true" >/dev/null 2>&1)

    _RC_JSON=$(wait_for_remote_outputs "$_RC_TF_DIR" 2700 "RC" \
        --upstream-pipeline "${_RC_REGIONAL_ID}-pipe" \
        oidc_cloudfront_domain oidc_bucket_name oidc_bucket_arn \
        oidc_bucket_region zoa_bucket_arn zoa_kms_key_arn) || exit 1

    export TF_VAR_oidc_cloudfront_domain=$(echo "$_RC_JSON" | jq -r '.oidc_cloudfront_domain.value')
    export TF_VAR_oidc_bucket_name=$(echo "$_RC_JSON" | jq -r '.oidc_bucket_name.value')
    export TF_VAR_oidc_bucket_arn=$(echo "$_RC_JSON" | jq -r '.oidc_bucket_arn.value')
    export TF_VAR_oidc_bucket_region=$(echo "$_RC_JSON" | jq -r '.oidc_bucket_region.value')
    export TF_VAR_zoa_outputs_bucket_arn=$(echo "$_RC_JSON" | jq -r '.zoa_bucket_arn.value')
    export TF_VAR_zoa_kms_key_arn=$(echo "$_RC_JSON" | jq -r '.zoa_kms_key_arn.value')
fi

# ── Phase 2: Apply/Destroy MC infrastructure ─────────────────────────────────
use_mc_account

export TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_KEY="management-cluster/${MANAGEMENT_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"
export TF_VAR_management_id="${CLUSTER_ID:-mgmt-cluster-01}"
export TF_VAR_environment="${ENVIRONMENT:-staging}"
export TF_VAR_regional_aws_account_id="${RESOLVED_REGIONAL_ACCOUNT_ID}"

# TF_VAR_maestro_agent_cert_file and TF_VAR_maestro_agent_config_file
# are already exported by read_iot_state()

_REPO_BRANCH="${REPOSITORY_BRANCH:-main}"
export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${_REPO_BRANCH}"

if [ -z "${PLATFORM_IMAGE:-}" ]; then
    echo "ERROR: PLATFORM_IMAGE is not set" >&2
    exit 1
fi
export TF_VAR_container_image="${PLATFORM_IMAGE}"

export TF_VAR_enable_bastion="${ENABLE_BASTION}"

if [ -n "${DNS_ZONE_OPERATOR_ROLE_ARN:-}" ]; then
    export TF_VAR_dns_zone_operator_role_arn="${DNS_ZONE_OPERATOR_ROLE_ARN}"
fi
if [ -n "${OIDC_WRITER_ROLE_ARN:-}" ]; then
    export TF_VAR_oidc_writer_role_arn="${OIDC_WRITER_ROLE_ARN}"
fi

export REGION_DEPLOYMENT=$(jq -r '.region' "$DEPLOY_CONFIG_FILE")
export ENVIRONMENT="${ENVIRONMENT:-staging}"

cd terraform/config/management-cluster
terraform init -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=${TF_STATE_KEY}" \
    -backend-config="region=${TF_STATE_REGION}" \
    -backend-config="use_lockfile=true"

if [ "${TERRAFORM_ACTION}" == "apply" ] && [ -f imports.sh ]; then
    source imports.sh
fi

set +e
terraform "${TERRAFORM_ACTION}" -auto-approve
TERRAFORM_STATUS=$?
set -e

if [ $TERRAFORM_STATUS -ne 0 ]; then
    exit $TERRAFORM_STATUS
fi

rm -f "${TF_VAR_maestro_agent_cert_file:-}" "${TF_VAR_maestro_agent_config_file:-}"
