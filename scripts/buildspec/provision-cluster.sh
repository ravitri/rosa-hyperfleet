#!/usr/bin/env bash
# Unified cluster provisioning wrapper for RC and MC.
# Called from: combined buildspecs
#
# Usage: provision-cluster.sh <cluster-type>
#   cluster-type: regional-cluster | RC | rc | management-cluster | MC | mc
#
# Flow:
#   1. Source check-queue.sh (skip if stale SHA)
#   2. Call provision-infra-<type>.sh
#   3. Call bootstrap/register scripts per cluster type
set -euo pipefail

CLUSTER_TYPE_ARG="${1:?Usage: provision-cluster.sh <regional-cluster|RC|rc|management-cluster|MC|mc>}"

# Normalize cluster type (accept regional-cluster/RC/rc and management-cluster/MC/mc)
case "${CLUSTER_TYPE_ARG,,}" in  # ${var,,} = lowercase
    regional-cluster|rc)
        CLUSTER_TYPE="regional-cluster"
        ;;
    management-cluster|mc)
        CLUSTER_TYPE="management-cluster"
        ;;
    *)
        echo "ERROR: Unknown cluster type '${CLUSTER_TYPE_ARG}'. Expected: regional-cluster|RC|rc|management-cluster|MC|mc" >&2
        exit 1
        ;;
esac

# ── Phase 1: Check queue and skip stale commits ──────────────────────────────
# CRITICAL: Must 'source' (not execute) so check-queue's 'exit 0' kills THIS
# wrapper script. The buildspec sees wrapper exit 0 = success (skip).
source scripts/pipeline-common/check-queue.sh

# If we reach here, self is the newest commit — proceed to terraform apply.
echo "provision-cluster: proceeding with ${CLUSTER_TYPE} provisioning"

# ── Phase 2: Provision infrastructure ────────────────────────────────────────
case "$CLUSTER_TYPE" in
    regional-cluster)
        echo "provision-cluster: Regional Cluster (RC) pipeline"
        ./scripts/buildspec/provision-infra-rc.sh
        ./scripts/buildspec/bootstrap-argocd-rc.sh
        ;;

    management-cluster)
        echo "provision-cluster: Management Cluster (MC) pipeline"
        ./scripts/buildspec/provision-infra-mc.sh
        ./scripts/buildspec/provision-kube-applier-dynamodb.sh
        ./scripts/buildspec/bootstrap-argocd-mc.sh
        ./scripts/buildspec/register.sh
        ;;

esac

echo "provision-cluster: ${CLUSTER_TYPE} provisioning complete"
