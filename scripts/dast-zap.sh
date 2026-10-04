#!/usr/bin/env bash
# DAST: OWASP ZAP (Automation Framework, zap/automation.yaml) against the released
# Juice Shop container, both on a private Docker network. A test user is registered
# for this run, Playwright walks it through the shop's features and records the
# traffic (scripts/playwright/dast-journeys.mjs), and ZAP imports that traffic, logs
# in as the same user, crawls the app and attacks everything it found.
# Usage: dast-zap.sh <report-dir>
# Output: <report-dir>/zap-report.xml   (DefectDojo scan type "ZAP Scan")
#         <report-dir>/zap-report.html  (human-readable report, artifact only)
#         <report-dir>/zap-urls.txt     (every request ZAP covered, artifact only)
set -euo pipefail
: "${JUICE_SHOP_IMAGE:?}" "${ZAP_IMAGE:?}" "${PLAYWRIGHT_IMAGE:?}" "${JUICE_SHOP_VERSION:?}"
out=$(realpath -m "$1")
here=$(dirname "$(realpath "$0")")
mkdir -p "$out"

net=dast-$$
app=juice-shop-$$
work=$(mktemp -d)
journeys=$(mktemp -d)
cleanup() {
  docker rm -f "$app" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work" "$journeys" 2>/dev/null || true
}
trap cleanup EXIT

docker network create "$net" >/dev/null
# Port published on loopback only, for the readiness check and user registration below.
docker run -d --name "$app" --network "$net" --network-alias juice-shop \
  -p 127.0.0.1:3000:3000 "$JUICE_SHOP_IMAGE" >/dev/null

version=""
for _ in $(seq 1 60); do
  version=$(curl -fsS http://127.0.0.1:3000/rest/admin/application-version 2>/dev/null | jq -r .version) && break
  sleep 2
done
if [ "v$version" != "$JUICE_SHOP_VERSION" ]; then
  echo "Juice Shop did not come up as $JUICE_SHOP_VERSION (got '${version}')" >&2
  docker logs "$app" | tail -50 >&2
  exit 1
fi
echo "Juice Shop $version is up"

# Test user for this run only: an ordinary customer account with a random password,
# passed to Playwright and ZAP through the environment.
DAST_USER_EMAIL="dast-$(openssl rand -hex 6)@example.test"
DAST_USER_PASSWORD=$(openssl rand -hex 16)
export DAST_USER_EMAIL DAST_USER_PASSWORD
if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::add-mask::$DAST_USER_PASSWORD"; fi
jq -n '{email: $ENV.DAST_USER_EMAIL, password: $ENV.DAST_USER_PASSWORD,
        passwordRepeat: $ENV.DAST_USER_PASSWORD, securityQuestion: {id: 1}, securityAnswer: "dast"}' \
  | curl -fsS -H 'Content-Type: application/json' -d @- -o /dev/null http://127.0.0.1:3000/api/Users
echo "Registered test user $DAST_USER_EMAIL"

# ZAP runs as uid 1000 inside its image; give it a scratch dir it can write.
cp "$here/../zap/automation.yaml" "$work/automation.yaml"
chmod 0777 "$work"

# Record the user journeys. The HAR file holds the test user's password and token, so
# it stays in the scratch dirs and is not published.
cp "$here/playwright/package.json" "$here/playwright/package-lock.json" "$here/playwright/dast-journeys.mjs" "$journeys/"
docker run --rm --network "$net" --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -e TARGET_URL=http://juice-shop:3000 -e DAST_USER_EMAIL -e DAST_USER_PASSWORD \
  -v "$journeys:/app" -w /app "$PLAYWRIGHT_IMAGE" \
  sh -c 'npm ci --ignore-scripts --no-audit --no-fund --loglevel=error && node dast-journeys.mjs journeys.har'
# ZAP's HAR import rejects entries without an HTTP status line: drop the requests the
# browser aborted when it moved to the next page (status -1) and the websockets.
jq '.log.entries |= map(select(.response.status >= 100 and (.request.url | startswith("http://juice-shop:3000/"))))' \
  "$journeys/journeys.har" > "$work/journeys.har"
jq -r '"Recorded \(.log.entries | length) requests"' "$work/journeys.har"

# -silent: no calls home, so ZAP runs only the add-ons in the pinned image instead of
# downloading updates at start. The plan exits 1 on errors (including a failed login
# of the test user) and 2 when it completed with warnings (reports written).
rc=0
docker run --rm --network "$net" -e DAST_USER_EMAIL -e DAST_USER_PASSWORD \
  -v "$work:/zap/wrk" "$ZAP_IMAGE" \
  zap.sh -cmd -silent -autorun /zap/wrk/automation.yaml || rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  echo "ZAP automation plan failed with exit code $rc" >&2
  exit "$rc"
fi

cp "$work/zap-report.xml" "$work/zap-report.html" "$out/"
# What ZAP covered, as "METHOD URL". The sites tree itself is not published: it also
# holds request bodies, including the test user's login.
awk '$1 == "url:" { url = $2; gsub(/^'\''|'\''$/, "", url) } $1 == "method:" { print $2, url }' \
  "$work/zap-sites.yaml" | sort -u > "$out/zap-urls.txt"
echo "ZAP covered $(wc -l < "$out/zap-urls.txt") requests (method and URL)"
python3 - "$out/zap-report.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
alerts = ET.parse(sys.argv[1]).findall(".//alertitem")
instances = sum(len(a.findall(".//instance")) for a in alerts)
print(f"ZAP: {len(alerts)} alert types, {instances} instances")
EOF
