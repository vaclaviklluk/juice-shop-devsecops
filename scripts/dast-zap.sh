#!/usr/bin/env bash
# DAST: OWASP ZAP (Automation Framework, zap/automation.yaml) against the released
# Juice Shop container, both on a private Docker network.
# Usage: dast-zap.sh <report-dir>
# Output: <report-dir>/zap-report.xml   (DefectDojo scan type "ZAP Scan")
#         <report-dir>/zap-report.html  (human-readable report, artifact only)
set -euo pipefail
: "${JUICE_SHOP_IMAGE:?}" "${ZAP_IMAGE:?}" "${JUICE_SHOP_VERSION:?}"
out=$(realpath -m "$1")
plan=$(dirname "$(realpath "$0")")/../zap/automation.yaml
mkdir -p "$out"

net=dast-$$
app=juice-shop-$$
work=$(mktemp -d)
cleanup() {
  docker rm -f "$app" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

docker network create "$net" >/dev/null
# Port published on loopback only, for the readiness check below.
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

# ZAP runs as uid 1000 inside its image; give it a scratch dir it can write.
cp "$plan" "$work/automation.yaml"
chmod 0777 "$work"
# The plan exits 1 on errors and 2 when it completed with warnings (reports written).
rc=0
docker run --rm --network "$net" -v "$work:/zap/wrk" "$ZAP_IMAGE" \
  zap.sh -cmd -autorun /zap/wrk/automation.yaml || rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  echo "ZAP automation plan failed with exit code $rc" >&2
  exit "$rc"
fi

cp "$work/zap-report.xml" "$work/zap-report.html" "$out/"
python3 - "$out/zap-report.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
alerts = ET.parse(sys.argv[1]).findall(".//alertitem")
print(f"ZAP: {len(alerts)} alert types")
EOF
