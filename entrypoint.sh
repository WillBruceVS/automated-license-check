#!/bin/bash

set -euo pipefail

REPO_WORKSPACE_PATH="/github/workspace"
LICENSE_FILE_PATH="/allowed_licenses.txt"

# Path to the allowed licenses file in the repo
REPO_WORKSPACE_LICENCE_FILE_PATH="${REPO_WORKSPACE_PATH}${LICENSE_FILE_PATH}"

# Check that the allowed licenses file exists
if [ ! -f "$REPO_WORKSPACE_LICENCE_FILE_PATH" ]; then
    echo "Error: allowed licenses file not found at $LICENSE_FILE_PATH"
    exit 1
fi

# Normalize allowed licenses: lowercase, sorted, unique
tr '[:upper:]' '[:lower:]' < "$REPO_WORKSPACE_LICENCE_FILE_PATH" | sort | uniq > allowed_licenses_normalized.txt

echo "Allowed Licenses:"
cat allowed_licenses_normalized.txt

# Run Scancode to scan the codebase
echo "Running Scancode on /github/workspace..."
COUNT=$(find . \
  -type d \( -name .git -o -name .hg -o -name .svn \) -prune -false \
  -o -type f | wc -l)
echo "/github/workspace contains: $COUNT files"

# Heartbeat for long-running scans
( while sleep 60; do echo "Scancode still running..."; done ) &
HB=$!
trap 'kill $HB 2>/dev/null || true' EXIT

# Run ScanCode; output JSON to stdout (so it does not create files accidentally in CI)
scancode --license --processes 4 --json-pp - /github/workspace > scan_results.json

echo ""
echo "Scancode completed."

# Verify scan_results.json exists
if [ ! -f scan_results.json ]; then
    echo "Error: scan_results.json not found."
    exit 1
fi

# Extract and normalize detected licenses
echo "Extracting detected licenses..."
LICENSE_DETECTIONS_COUNT=$(jq '.license_detections | length' scan_results.json)

if [ "$LICENSE_DETECTIONS_COUNT" -eq 0 ]; then
    echo "No licenses detected in the scanned files."
    exit 1
fi

jq -r '
  .license_detections[].license_expression |
  gsub("[()]"; "") |
  gsub(" AND "; " ") |
  gsub(" OR "; " ") |
  split(" ")[]' scan_results.json \
  | tr '[:upper:]' '[:lower:]' \
  | xargs -n1 \
  | sort \
  | uniq > detected_licenses.txt

echo "Detected Licenses:"
cat detected_licenses.txt

# Ensure detected_licenses.txt is not empty
if [ ! -s detected_licenses.txt ]; then
    echo "No detected licenses found."
    exit 1
fi

# Compare detected licenses against allowed licenses
DISALLOWED_LICENSES=$(comm -23 detected_licenses.txt allowed_licenses_normalized.txt)

if [ -n "$DISALLOWED_LICENSES" ]; then
    echo "Disallowed licenses found:"
    echo "$DISALLOWED_LICENSES"
    exit 1
else
    echo "All detected licenses are allowed."
fi
