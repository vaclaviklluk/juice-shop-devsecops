#!/usr/bin/env bash
# SAST: Semgrep (OSS engine) with registry rule packs for JavaScript, TypeScript,
# Node.js/Express (incl. the njsscan rules) and the OWASP Top 10.
# Usage: sast-semgrep.sh <juice-shop-src> <report-dir>
# Output: <report-dir>/semgrep.json  (DefectDojo scan type "Semgrep JSON Report")
set -euo pipefail
: "${SEMGREP_IMAGE:?}"
src=$(realpath "$1")
out=$(realpath -m "$2")
mkdir -p "$out"

# Semgrep exits 0 when it finds issues (no --error) and non-zero only when the
# scan itself fails, so a red job means a broken scan, not a vulnerable app.
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$src:/src:ro" -v "$out:/out" -w /src "$SEMGREP_IMAGE" \
  semgrep scan --metrics=off --disable-version-check \
    --config p/javascript --config p/typescript --config p/nodejs \
    --config p/expressjs --config p/owasp-top-ten --config p/jwt \
    --config p/sql-injection --config p/xss --config p/nodejsscan --config p/default \
    --json --output /out/semgrep.json

# Semgrep lists files it could only partly parse (mostly Angular templates) as
# warn-level "errors"; they do not fail the scan.
jq -r '"Semgrep: \(.results | length) findings, \([.errors[] | select(.level != "warn")] | length) scan errors, \([.errors[] | select(.level == "warn")] | length) parse warnings"' "$out/semgrep.json"
