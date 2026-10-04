#!/usr/bin/env bash
# Captures DefectDojo pages with the imported findings, using headless Chromium in
# the official Playwright image. The playwright npm package is installed from the
# committed lockfile (integrity-checked, no install scripts).
# Usage: defectdojo-screenshots.sh <results-dir>   (after defectdojo-import.sh)
# Output: <results-dir>/screenshots/*.png
set -euo pipefail
: "${PLAYWRIGHT_IMAGE:?}"
here=$(dirname "$(realpath "$0")")/playwright
results=$(realpath "$1")
# shellcheck source=/dev/null
. "${DD_ENV_FILE:-${RUNNER_TEMP:-/tmp}/defectdojo.env}"
export DD_ADMIN_PASSWORD
mkdir -p "$results/screenshots"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$here/package.json" "$here/package-lock.json" "$here/defectdojo.mjs" "$work/"

docker run --rm --network host --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -e DD_ADMIN_PASSWORD -e DD_URL="http://127.0.0.1:${DD_PORT:-8080}" \
  -v "$work:/app" -v "$results:/results" -w /app "$PLAYWRIGHT_IMAGE" \
  sh -c 'npm ci --ignore-scripts --no-audit --no-fund --loglevel=error && node defectdojo.mjs /results'
