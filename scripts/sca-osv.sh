#!/usr/bin/env bash
# SCA: OSV-Scanner over the npm dependency trees of the backend and the Angular frontend.
# Juice Shop does not commit lockfiles (.npmrc: package-lock=false), so the script first
# resolves one per package.json without running any install scripts.
# Usage: sca-osv.sh <juice-shop-src> <report-dir>
# Output: <report-dir>/osv-scanner.json  (DefectDojo scan type "OSV Scan")
set -euo pipefail
: "${NODE_IMAGE:?}" "${OSV_SCANNER_IMAGE:?}"
src=$(realpath "$1")
out=$(realpath -m "$2")
mkdir -p "$out"

for dir in . frontend; do
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$src:/src" -w "/src/$dir" "$NODE_IMAGE" \
    npm install --package-lock=true --package-lock-only --ignore-scripts \
      --no-audit --no-fund --loglevel=error
done

# osv-scanner exits 1 when it finds vulnerabilities; anything else non-zero is an error.
rc=0
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$src:/src:ro" -v "$out:/out" "$OSV_SCANNER_IMAGE" \
  scan source --format json --output-file /out/osv-scanner.json \
    --lockfile /src/package-lock.json --lockfile /src/frontend/package-lock.json || rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
  echo "osv-scanner failed with exit code $rc" >&2
  exit "$rc"
fi

jq -r '"OSV-Scanner: \([.results[].packages[].vulnerabilities[]] | length) vulnerabilities in \([.results[].packages[]] | length) packages"' "$out/osv-scanner.json"
