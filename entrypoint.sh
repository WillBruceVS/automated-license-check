#!/bin/bash

set -euo pipefail

CHANGED_FILES_PATH="$1"

echo "Changed files list: ${CHANGED_FILES_PATH:-<none>}"

SCAN_TARGETS=()

if [[ -n "$CHANGED_FILES_PATH" && -f "$CHANGED_FILES_PATH" ]]; then
    echo "Using changed files list:"
    cat "$CHANGED_FILES_PATH"

    # Filter only files that actually exist
    while IFS= read -r file; do
        if [[ -f "/github/workspace/$file" ]]; then
            SCAN_TARGETS+=("$file")
        fi
    done < "$CHANGED_FILES_PATH"

    if [[ ${#SCAN_TARGETS[@]} -eq 0 ]]; then
        echo "No valid changed files to scan. Exiting cleanly."
        exit 0
    fi

else
    echo "No changed files provided; scanning entire workspace."
    SCAN_TARGETS=("/github/workspace")
fi

REPO_WORKSPACE_PATH="/github/workspace"
LICENSE_FILE_PATH="/allowed_licenses.txt"

REPO_WORKSPACE_LICENCE_FILE_PATH="${REPO_WORKSPACE_PATH}${LICENSE_FILE_PATH}"

if [ ! -f "$REPO_WORKSPACE_LICENCE_FILE_PATH" ]; then
    echo "Error: allowed licenses file not found at $LICENSE_FILE_PATH"
    exit 1
fi

# Normalize allowed licenses
tr '[:upper:]' '[:lower:]' < "$REPO_WORKSPACE_LICENCE_FILE_PATH" \
  | tr ',' '\n' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | sed '/^$/d' \
  | sort -u > allowed_licenses_normalized.txt

echo "Allowed Licenses:"
cat allowed_licenses_normalized.txt

# Filter out ignored file types
FILTERED_TARGETS=()
for target in "${SCAN_TARGETS[@]}"; do
    if [[ ! "$target" =~ \.pdf$ && ! "$target" =~ \.csv$ && ! "$target" =~ \.map$ && ! "$target" =~ \.txt$ ]]; then
        FILTERED_TARGETS+=("$target")
    fi
done

if [[ ${#FILTERED_TARGETS[@]} -eq 0 ]]; then
    echo "All changed files were ignored (txt/csv/pdf/map). Nothing to scan."
    exit 0
fi

##############################################
# NEW: Compute deepest common directory
##############################################

abs_targets=()
for t in "${FILTERED_TARGETS[@]}"; do
  abs_targets+=("${REPO_WORKSPACE_PATH}/${t}")
done

COMMON_DIR="$(dirname "${abs_targets[0]}")"

for abs in "${abs_targets[@]}"; do
  while [[ "${abs}" != "${COMMON_DIR}"/* && "${abs}" != "${COMMON_DIR}" ]]; do
    COMMON_DIR="$(dirname "${COMMON_DIR}")"
    if [[ "${COMMON_DIR}" == "/" || "${COMMON_DIR}" == "${REPO_WORKSPACE_PATH%/}" ]]; then
      COMMON_DIR="${REPO_WORKSPACE_PATH%/}"
      break
    fi
  done
done

REL_COMMON_DIR="${COMMON_DIR#"${REPO_WORKSPACE_PATH%/}"/}"
if [[ "${COMMON_DIR}" == "${REPO_WORKSPACE_PATH%/}" ]]; then
  REL_COMMON_DIR=""
fi

echo "Running Scancode on common directory: ${COMMON_DIR}"
echo "Changed files (filtered):"
printf '%s\n' "${FILTERED_TARGETS[@]}"

( while sleep 60; do echo "Scancode still running..."; done ) &
HB=$!
trap 'kill $HB 2>/dev/null || true' EXIT

##############################################
# IMPORTANT: Scan only the COMMON_DIR
##############################################
scancode --license --verbose --processes 8 --timeout 900 --json-pp - "${COMMON_DIR}" > scan_results.json

echo ""
echo "Scancode completed."

# Verify scan output
if [ ! -f scan_results.json ]; then
    echo "Error: scan_results.json not found."
    exit 1
fi

##############################################
# Filter detections to only changed files
##############################################

targets_rel_to_common="targets_rel_to_common.txt"
: > "${targets_rel_to_common}"

for t in "${FILTERED_TARGETS[@]}"; do
  if [[ -n "${REL_COMMON_DIR}" ]]; then
    rel="${t#"${REL_COMMON_DIR}"/}"
  else
    rel="${t}"
  fi
  printf '%s\n' "${rel}" >> "${targets_rel_to_common}"
done

echo "Extracting detected licenses (only for changed files)..."

LICENSE_DETECTIONS_COUNT=$(jq '.license_detections | length' scan_results.json)

if [ "$LICENSE_DETECTIONS_COUNT" -eq 0 ]; then
    echo "No licenses detected in the scanned scope."
    : > detected_licenses.txt
else
    jq -r --rawfile wanted "${targets_rel_to_common}" '
      ( $wanted | split("\n") | map(select(length>0)) ) as $want
      |
      .license_detections
      | map(select( any(.matches[]?; (.from_file as $f | $want | index($f))) ))
      | .[].license_expression
    ' scan_results.json \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/ AND / /g; s/ OR / /g' \
    | tr -d '()' \
    | xargs -n1 \
    | sort -u > detected_licenses.txt
fi

echo "Detected Licenses:" || true
[[ -s detected_licenses.txt ]] && cat detected_licenses.txt || echo "(none)"

if [ ! -s detected_licenses.txt ]; then
    echo "No detected licenses found."
    exit 1
fi

##############################################
# Final comparison vs allowed list
##############################################
DISALLOWED_LICENSES=$(comm -23 detected_licenses.txt allowed_licenses_normalized.txt)

if [ -n "$DISALLOWED_LICENSES" ]; then
    echo "Disallowed licenses found:"
    echo "$DISALLOWED_LICENSES"
    exit 1
else
    echo "All detected licenses are allowed."
fi