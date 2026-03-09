#!/bin/bash
set -euo pipefail

CHANGED_FILES_PATH="${1:-}"

echo "Changed files list input: ${CHANGED_FILES_PATH:-<none>}"

REPO_ROOT="/github/workspace"
ALLOWED_LICENSES_FILE="$REPO_ROOT/allowed_licenses.txt"

###########################################################
# Validate allowed licenses file
###########################################################
if [[ ! -f "$ALLOWED_LICENSES_FILE" ]]; then
    echo "Error: allowed_licenses.txt not found at repository root."
    exit 1
fi

tr '[:upper:]' '[:lower:]' < "$ALLOWED_LICENSES_FILE" \
  | tr ',' '\n' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | sed '/^$/d' \
  | sort -u > allowed_licenses_normalized.txt

echo "Allowed licenses:"
cat allowed_licenses_normalized.txt

###########################################################
# Determine scan mode: changed files only OR full repo
###########################################################
SCAN_TARGETS=()
FULL_SCAN=false

if [[ -n "$CHANGED_FILES_PATH" && -f "$CHANGED_FILES_PATH" ]]; then
    echo "Using changed files list:"
    cat "$CHANGED_FILES_PATH"

    while IFS= read -r f; do
        [[ -f "$REPO_ROOT/$f" ]] && SCAN_TARGETS+=("$f")
    done < "$CHANGED_FILES_PATH"

    if [[ ${#SCAN_TARGETS[@]} -eq 0 ]]; then
        echo "No valid changed files found; fallback to FULL SCAN."
        FULL_SCAN=true
    fi
else
    echo "No changed file list provided; FULL SCAN enabled."
    FULL_SCAN=true
fi

###########################################################
# FILTER OUT NON-SOURCE FILES (PDF/TXT/MAP/CSV)
###########################################################
if [[ "$FULL_SCAN" == false ]]; then
    FILTERED_TARGETS=()
    for f in "${SCAN_TARGETS[@]}"; do
        if [[ ! "$f" =~ \.(pdf|csv|map|txt)$ ]]; then
            FILTERED_TARGETS+=("$f")
        fi
    done

    if [[ ${#FILTERED_TARGETS[@]} -eq 0 ]]; then
        echo "Changed files exist but all were filtered out. Exiting cleanly."
        exit 0
    fi
fi

###########################################################
# SCAN EXECUTION
###########################################################
if [[ "$FULL_SCAN" == true ]]; then
    echo "=== FULL REPOSITORY SCAN MODE ==="
    SCAN_DIR="$REPO_ROOT"

    scancode --license \
             --processes 8 \
             --timeout 900 \
             --verbose \
             --json-pp scan_results.json \
             "$SCAN_DIR"

else
    echo "=== PARTIAL SCAN: SCANNING ONLY CHANGED FILES ==="
    echo "Files to scan:"
    printf '%s\n' "${FILTERED_TARGETS[@]}"

    mkdir -p sc_tmp
    echo '[]' > sc_tmp/combined.json

    for t in "${FILTERED_TARGETS[@]}"; do
        abs="$REPO_ROOT/$t"
        echo "Running ScanCode on: $abs"

        scancode --license \
                 --processes 4 \
                 --timeout 300 \
                 --json-pp sc_tmp/out.json \
                 "$abs"

        jq -s '.[0] + .[1]' sc_tmp/combined.json sc_tmp/out.json \
          > sc_tmp/merged.json

        mv sc_tmp/merged.json sc_tmp/combined.json
    done

    mv sc_tmp/combined.json scan_results.json
fi

echo "ScanCode completed."

###########################################################
# EXTRACT LICENSE EXPRESSIONS
###########################################################
jq -r '
  .license_detections[].license_expression? // empty
' scan_results.json \
| tr '[:upper:]' '[:lower:]' \
| sed 's/ AND / /g; s/ OR / /g' \
| tr -d '()' \
| xargs -n1 \
| sort -u \
| grep -vE '^(and|or)$' \
> detected_licenses.txt

echo "Detected licenses:"
cat detected_licenses.txt || true

if [[ ! -s detected_licenses.txt ]]; then
    echo "No licenses detected — failing."
    exit 1
fi

###########################################################
# COMPARE AGAINST ALLOWED LICENSES
###########################################################
DISALLOWED=$(comm -23 detected_licenses.txt allowed_licenses_normalized.txt || true)

if [[ -n "$DISALLOWED" ]]; then
    echo "❌ Disallowed licenses detected:"
    echo "$DISALLOWED"
    exit 1
fi

echo "✔ All detected licenses are allowed."
exit 0