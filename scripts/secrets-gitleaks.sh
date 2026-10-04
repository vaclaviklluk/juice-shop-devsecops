#!/usr/bin/env bash
# Secrets scanning: Gitleaks over the full git history of Juice Shop.
# Usage: secrets-gitleaks.sh <juice-shop-git-checkout> <report-dir>
# Output: <report-dir>/gitleaks.json  (DefectDojo scan type "Gitleaks Scan")
set -euo pipefail
: "${GITLEAKS_IMAGE:?}"
src=$(realpath "$1")
out=$(realpath -m "$2")
mkdir -p "$out"

# --redact keeps the secret values out of the report, the artifact and DefectDojo.
# --exit-code 0: leaks are reported, not fatal; a scan error still exits 1.
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$src:/repo:ro" -v "$out:/out" "$GITLEAKS_IMAGE" \
  git /repo --redact --no-banner --exit-code 0 \
    --report-format json --report-path /out/gitleaks.json

jq -r '"Gitleaks: \(length) secrets"' "$out/gitleaks.json"
