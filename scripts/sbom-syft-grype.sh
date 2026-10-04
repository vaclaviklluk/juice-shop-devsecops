#!/usr/bin/env bash
# SBOM: Syft catalogues every package in the released Juice Shop container image
# (OS packages and bundled npm modules), then Grype matches that SBOM against
# vulnerability databases.
# Usage: sbom-syft-grype.sh <report-dir>
# Output: <report-dir>/sbom.syft.json  (DefectDojo scan type "Syft SBOM", inventory)
#         <report-dir>/sbom.cdx.json   (CycloneDX SBOM, published as an artifact)
#         <report-dir>/grype.json      (DefectDojo scan type "Anchore Grype")
set -euo pipefail
: "${JUICE_SHOP_IMAGE:?}" "${SYFT_IMAGE:?}" "${GRYPE_IMAGE:?}"
out=$(realpath -m "$1")
mkdir -p "$out"

# Both images are distroless with no writable /tmp; give each a scratch dir on disk
# for image layers (Syft) and the vulnerability database (Grype).
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/syft" "$scratch/grype"

# The registry: source pulls the pinned image straight from the registry, so no
# Docker socket is mounted into the scanner container.
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$scratch/syft:/tmp" -v "$out:/out" "$SYFT_IMAGE" \
  scan "registry:$JUICE_SHOP_IMAGE" --platform linux/amd64 \
    -o syft-json=/out/sbom.syft.json -o cyclonedx-json=/out/sbom.cdx.json

docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$scratch/grype:/tmp" -v "$out:/out" "$GRYPE_IMAGE" \
  sbom:/out/sbom.syft.json -o json --file /out/grype.json

jq -r '"Syft: \(.artifacts | length) packages"' "$out/sbom.syft.json"
jq -r '"Grype: \(.matches | length) vulnerability matches"' "$out/grype.json"
