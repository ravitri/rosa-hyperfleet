#!/usr/bin/env bash
# Provision or destroy RHOBS Cluster infrastructure.
# Called from: terraform/config/pipeline-rhobs-cluster/buildspec-provision-infra.yml
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load rhobs

# Save central credentials as a named AWS profile so Terraform's aws.central
# provider can access the central account after use_mc_account switches
# ambient creds to the target account.
aws configure set aws_access_key_id     "$_CENTRAL_AWS_ACCESS_KEY_ID"     --profile central
aws configure set aws_secret_access_key "$_CENTRAL_AWS_SECRET_ACCESS_KEY" --profile central
aws configure set aws_session_token     "$_CENTRAL_AWS_SESSION_TOKEN"     --profile central
aws configure set region                "${TARGET_REGION}"                --profile central
export TF_VAR_central_aws_profile="central"

# Fetch PagerDuty config if enabled
_RAW_PD=$(jq -r '.enable_pagerduty // false' "$DEPLOY_CONFIG_FILE")
if [ "$_RAW_PD" == "true" ] || [ "$_RAW_PD" == "1" ]; then
    export TF_VAR_enable_pagerduty="true"
    export TF_VAR_pagerduty_escalation_policy_id=$(jq -r '.pagerduty_escalation_policy_id // ""' "$DEPLOY_CONFIG_FILE")
    PAGERDUTY_TOKEN=$(aws secretsmanager get-secret-value \
        --secret-id "pagerduty/service-account" \
        --region us-east-1 \
        --query SecretString \
        --output text)
    export PAGERDUTY_TOKEN
fi

use_mc_account

# Configure Terraform backend (state in target account)
export TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}-${TARGET_REGION}"
export TF_STATE_KEY="rhobs-cluster/${REGIONAL_ID}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

# Set Terraform variables
export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"

_REPO_BRANCH="${REPOSITORY_BRANCH:-main}"
export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${_REPO_BRANCH}"

if [ -z "${PLATFORM_IMAGE:-}" ]; then
    echo "ERROR: PLATFORM_IMAGE is not set" >&2
    exit 1
fi
export TF_VAR_container_image="${PLATFORM_IMAGE}"

export TF_VAR_enable_sns_alerting=$(parseBool '.enable_sns_alerting' false "$DEPLOY_CONFIG_FILE")

# RC remote state references for RHOBS cluster to read RC outputs
export TF_VAR_rc_state_bucket=$(jq -r '.rc_state_bucket // ""' "$DEPLOY_CONFIG_FILE")
export TF_VAR_rc_state_key=$(jq -r '.rc_state_key // ""' "$DEPLOY_CONFIG_FILE")

if [ -n "${ENVIRONMENT_DOMAIN:-}" ]; then
    export TF_VAR_environment_domain="${ENVIRONMENT_DOMAIN}"
fi
if [ -n "${ENVIRONMENT_HOSTED_ZONE_ID:-}" ]; then
    export TF_VAR_environment_hosted_zone_id="${ENVIRONMENT_HOSTED_ZONE_ID}"
fi

export TF_VAR_regional_id=$(jq -r '.regional_id' "$DEPLOY_CONFIG_FILE")
export TF_VAR_environment=$(jq -r '.environment' "$DEPLOY_CONFIG_FILE")
export TF_VAR_eph_prefix=$(jq -r '.eph_prefix // ""' "$DEPLOY_CONFIG_FILE")
export ENVIRONMENT="${ENVIRONMENT:-staging}"

# Determine terraform action
DELETE_FLAG=$(jq -r '.delete // false' "$DEPLOY_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

TERRAFORM_ACTION="apply"
[ "${DELETE_FLAG}" == "true" ] && TERRAFORM_ACTION="destroy"

echo "RHOBS ${REGIONAL_ID}: terraform ${TERRAFORM_ACTION} in ${TARGET_ACCOUNT_ID}/${TARGET_REGION}"

# Wait for RC terraform outputs before apply — RHOBS reads RC's VPC outputs
# via terraform_remote_state. Checking the S3 object alone is insufficient
# because the state file exists from terraform init, before apply writes the
# actual resource outputs.
if [ "${TERRAFORM_ACTION}" == "apply" ] && [ -n "${TF_VAR_rc_state_bucket}" ] && [ -n "${TF_VAR_rc_state_key}" ]; then
    echo "Waiting for RC terraform outputs (bucket=${TF_VAR_rc_state_bucket}, key=${TF_VAR_rc_state_key})..."
    _RC_TF_DIR="terraform/config/regional-cluster"
    (cd "$_RC_TF_DIR" && terraform init -reconfigure \
        -backend-config="bucket=${TF_VAR_rc_state_bucket}" \
        -backend-config="key=${TF_VAR_rc_state_key}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true" >/dev/null 2>&1)

    for _attempt in $(seq 1 90); do
        _rc_vpc_id=$(cd "$_RC_TF_DIR" && terraform output -raw vpc_id 2>/dev/null || true)
        # terraform output -raw writes warnings to stdout when no outputs
        # exist; discard anything that isn't a VPC ID.
        case "$_rc_vpc_id" in vpc-*) ;; *) _rc_vpc_id="" ;; esac
        if [ -n "${_rc_vpc_id}" ]; then
            echo "RC terraform outputs ready (attempt ${_attempt}, vpc_id=${_rc_vpc_id})"
            break
        fi
        if [ "$_attempt" -eq 90 ]; then
            echo "ERROR: RC terraform outputs not available after 45 minutes" >&2
            exit 1
        fi
        echo "  RC outputs not ready (attempt ${_attempt}/90), retrying in 30s..."
        sleep 30
    done
fi

cd terraform/config/rhobs-cluster
terraform init -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=${TF_STATE_KEY}" \
    -backend-config="region=${TF_STATE_REGION}" \
    -backend-config="use_lockfile=true"

if [ "${TERRAFORM_ACTION}" == "apply" ] && [ -f imports.sh ]; then
    source imports.sh
fi

terraform "${TERRAFORM_ACTION}" -auto-approve
