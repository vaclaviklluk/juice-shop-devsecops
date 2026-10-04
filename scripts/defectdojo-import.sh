#!/usr/bin/env bash
# Imports every scanner report into one DefectDojo engagement, then exports the
# findings and a per-stage severity summary.
# Usage: defectdojo-import.sh <report-dir> <results-dir>
# Output: <results-dir>/findings.json, summary.md, context.json (ids for screenshots)
# Exits non-zero if any expected report is missing or rejected, after importing the rest.
set -euo pipefail
: "${JUICE_SHOP_VERSION:?}" "${JUICE_SHOP_COMMIT:?}"
reports=$(realpath "$1")
results=$(realpath -m "$2")
mkdir -p "$results/imports"
DD_URL=http://127.0.0.1:${DD_PORT:-8080}
# shellcheck source=/dev/null
. "${DD_ENV_FILE:-${RUNNER_TEMP:-/tmp}/defectdojo.env}"

# report file | DefectDojo scan type | test title | stage tag
imports=(
  "semgrep.json|Semgrep JSON Report|SAST - Semgrep|sast"
  "zap-report.xml|ZAP Scan|DAST - OWASP ZAP|dast"
  "sbom.syft.json|Syft SBOM|SBOM - Syft package inventory|sbom"
  "grype.json|Anchore Grype|SBOM - Grype vulnerabilities|sbom"
  "osv-scanner.json|OSV Scan|SCA - OSV-Scanner|sca"
  "gitleaks.json|Gitleaks Scan|Secrets - Gitleaks|secrets"
)

token=$(jq -n --arg p "$DD_ADMIN_PASSWORD" '{username: "admin", password: $p}' \
  | curl -sS --fail-with-body "$DD_URL/api/v2/api-token-auth/" \
      -H 'Content-Type: application/json' -d @- | jq -r .token)
if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::add-mask::$token"; fi
auth="Authorization: Token $token"

api_get() { curl -sS --fail-with-body -H "$auth" "$DD_URL/api/v2/$1"; }

engagement="GitHub Actions run ${GITHUB_RUN_ID:-local}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-local}"
failed=0
for entry in "${imports[@]}"; do
  IFS='|' read -r file scan_type title tag <<<"$entry"
  if [ ! -s "$reports/$file" ]; then
    echo "::error::$title: report $file is missing (did the scan job fail?)"
    failed=1
    continue
  fi
  if curl -sS --fail-with-body -H "$auth" "$DD_URL/api/v2/import-scan/" \
      -F "file=@$reports/$file" -F "scan_type=$scan_type" -F "test_title=$title" -F "tags=$tag" \
      -F "product_type_name=Web Applications" -F "product_name=OWASP Juice Shop" \
      -F "engagement_name=$engagement" -F "auto_create_context=true" \
      -F "deduplication_on_engagement=true" -F "close_old_findings=false" \
      -F "active=true" -F "verified=false" -F "minimum_severity=Info" \
      -F "version=$JUICE_SHOP_VERSION" -F "commit_hash=$JUICE_SHOP_COMMIT" \
      -F "branch_tag=$JUICE_SHOP_VERSION" \
      -F "source_code_management_uri=https://github.com/juice-shop/juice-shop" \
      -F "build_id=${GITHUB_RUN_ID:-local}" \
      -F "engagement_end_date=$(date -u +%F)" \
      -o "$results/imports/${file%%.*}.json"; then
    jq -r --arg t "$title" '"Imported \($t): test \(.test_id), \(.statistics.after.total.active // "?") active findings"' \
      "$results/imports/${file%%.*}.json"
  else
    echo "::error::$title: DefectDojo rejected $file as '$scan_type'"
    mv "$results/imports/${file%%.*}.json" "$results/imports/${file%%.*}.error.txt" 2>/dev/null || true
    cat "$results/imports/${file%%.*}.error.txt" >&2 || true
    echo >&2
    failed=1
  fi
done

engagement_id=$(cat "$results"/imports/*.json 2>/dev/null | jq -s -r 'map(.engagement_id // empty) | first // empty')
if [ -z "$engagement_id" ]; then
  echo "::error::Nothing was imported into DefectDojo"
  exit 1
fi

# import-scan records build and commit on each test; put them on the engagement too.
jq -n --arg run "$run_url" --arg version "$JUICE_SHOP_VERSION" --arg commit "$JUICE_SHOP_COMMIT" \
    --arg build "${GITHUB_RUN_ID:-local}" \
  '{description: "OWASP Juice Shop \($version) scanned by \($run)",
    build_id: $build, commit_hash: $commit, branch_tag: $version}' \
  | curl -sS --fail-with-body -X PATCH -H "$auth" -H 'Content-Type: application/json' \
      "$DD_URL/api/v2/engagements/$engagement_id/" -d @- -o /dev/null

# Export the engagement: tests, then all findings (paged), annotated with their test title.
api_get "tests/?engagement=$engagement_id&limit=100" | jq '.results | map({id, title})' > "$results/tests.json"
next="$DD_URL/api/v2/findings/?test__engagement=$engagement_id&limit=500"
echo '[]' > "$results/findings.json"
while [ -n "$next" ] && [ "$next" != null ]; do
  curl -sS --fail-with-body -H "$auth" "$next" -o "$results/page.json"
  jq -s '.[0] + .[1].results' "$results/findings.json" "$results/page.json" > "$results/findings.tmp"
  mv "$results/findings.tmp" "$results/findings.json"
  next=$(jq -r .next "$results/page.json")
done
rm -f "$results/page.json"
jq --slurpfile tests "$results/tests.json" '
  ($tests[0] | map({key: (.id | tostring), value: .title}) | from_entries) as $title
  | map({id, test_title: $title[.test | tostring], severity, title, cwe,
         component_name, component_version, file_path, line, vuln_id_from_tool,
         description})' "$results/findings.json" > "$results/findings.tmp"
mv "$results/findings.tmp" "$results/findings.json"

jq -n --argjson e "$engagement_id" --slurpfile tests "$results/tests.json" \
  --arg product "$(api_get "engagements/$engagement_id/" | jq -r .product)" \
  '{engagement_id: $e, product_id: ($product | tonumber), tests: $tests[0]}' > "$results/context.json"

# Per-stage severity table, in the order of the imports above.
order=$(printf '%s\n' "${imports[@]}" | cut -d'|' -f3 | jq -R . | jq -s .)
jq -r --argjson order "$order" --arg engagement "$engagement" '
  def count(s): map(select(.severity == s)) | length;
  def row(name): "| \(name) | \(count("Critical")) | \(count("High")) | \(count("Medium")) | \(count("Low")) | \(count("Info")) | \(length) |";
  . as $all
  | "### DefectDojo: \($engagement)\n",
    "| Stage / tool | Critical | High | Medium | Low | Info | Total |",
    "|---|---:|---:|---:|---:|---:|---:|",
    ($order[] as $t | $all | map(select(.test_title == $t)) | row($t)),
    ($all | row("**All stages**"))' "$results/findings.json" > "$results/summary.md"
cat "$results/summary.md"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$results/summary.md" >> "$GITHUB_STEP_SUMMARY"; fi

exit "$failed"
