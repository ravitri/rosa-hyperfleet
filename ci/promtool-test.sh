#!/bin/bash
# Render the alerting-rules Helm chart, extract PrometheusRule specs,
# and validate them with promtool.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${REPO_ROOT}/argocd/config/rhobs-cluster/alerting-rules"
TEST_DIR="${REPO_ROOT}/ci/promtool-test"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

RULES_FILE="${TEST_DIR}/rules.yaml"

echo "=== Rendering alerting-rules chart ==="
helm template alerting-rules "${CHART_DIR}" \
  --set global.cluster_name="test-regional" \
  --set global.management_clusters="test-regional-mc01:111111111111" \
  > "${WORK_DIR}/rendered.yaml"

echo "=== Extracting PrometheusRule specs ==="
yq eval-all '[select(.kind == "PrometheusRule") | .spec.groups[]] | {"groups": .}' "${WORK_DIR}/rendered.yaml" > "${RULES_FILE}"
trap 'rm -f "${RULES_FILE}"; rm -rf "${WORK_DIR}"' EXIT

echo "=== Checking rules syntax ==="
promtool check rules "${RULES_FILE}"

echo "=== Running promtool tests ==="
for test_file in "${TEST_DIR}"/*_test.yaml; do
    [ -f "${test_file}" ] || continue
    echo "--- ${test_file} ---"
    promtool test rules "${test_file}"
done

echo "=== All promtool tests passed ==="
