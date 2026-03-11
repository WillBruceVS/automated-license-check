#!/bin/bash
set -euo pipefail

# Kill the entire process group on any exit/cancel, so no workers are left behind.
cleanup() {
  echo "Cleanup: terminating any child processes in this process group..."
  # Send TERM to the process group
  kill -TERM -- -$$ 2>/dev/null || true
  # Give them a moment to exit gracefully
  sleep 1
  # Hard kill any stubborn children
  kill -KILL -- -$$ 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Ensure GNU timeout is available
if ! command -v timeout >/dev/null 2>&1; then
  echo "Error: 'timeout' command not found. Please install coreutils 'timeout' on the runner."
  exit 1
fi

CHANGED_FILES_PATH="${1:-}"

REPO_ROOT="/github/workspace"
ALLOWED_LICENSES_FILE="$REPO_ROOT/allowed_licenses.txt"

echo "Changed files list input: ${CHANGED_FILES_PATH:-<none>}"

###############################################################################
# Allowed licenses file
###############################################################################
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

###############################################################################
# Determine scan mode
###############################################################################
SCAN_TARGETS=()
FULL_SCAN=false

if [[ -n "$CHANGED_FILES_PATH" && -f "$CHANGED_FILES_PATH" ]]; then
    echo "Using changed files list:"
    cat "$CHANGED_FILES_PATH"

    while IFS= read -r f; do
        [[ -f "$REPO_ROOT/$f" ]] && SCAN_TARGETS+=("$f")
    done < "$CHANGED_FILES_PATH"

    if [[ ${#SCAN_TARGETS[@]} -eq 0 ]]; then
        echo "Changed-file list exists but no valid files found → full scan fallback."
        FULL_SCAN=true
    fi
else
    echo "No changed-file list provided → full scan enabled."
    FULL_SCAN=true
fi

###############################################################################
# Filter out useless filetypes
###############################################################################
if [[ "$FULL_SCAN" == false ]]; then
    FILTERED_TARGETS=()
    for f in "${SCAN_TARGETS[@]}"; do
        # Skip non-source noise files
        if [[ ! "$f" =~ \.(pdf|csv|map|txt)$ ]]; then
          FILTERED_TARGETS+=("$f")
        fi
    done

    if [[ ${#FILTERED_TARGETS[@]} -eq 0 ]]; then
        echo "All changed files filtered out. Nothing to scan."
        exit 0
    fi
fi

###############################################################################
# Helper: run scancode with a hard timeout that kills the whole process tree
###############################################################################
run_scancode_with_timeout() {
  # Usage: run_scancode_with_timeout <duration> <command...>
  # Sends SIGTERM at <duration>, SIGKILL 30s later if still running.
  local duration="$1"; shift
  timeout --signal=TERM -k 30s "$duration" "$@"
}

###############################################################################
# FULL SCAN MODE
###############################################################################
if [[ "$FULL_SCAN" == true ]]; then
    echo "=== FULL SCAN MODE ==="

    # External timeout enforces a real kill of all workers after 900s (+30s grace)
    run_scancode_with_timeout 900s \
      scancode --license \
               --processes 8 \
               --timeout 900 \
               --verbose \
               --json-pp scan_results_full.json \
               "$REPO_ROOT"

    echo "Extracting license_detections → scan_results.json"
    jq '.license_detections // []' scan_results_full.json > scan_results.json

else
###############################################################################
# PARTIAL SCAN: ONLY CHANGED FILES
###############################################################################
    echo "=== PARTIAL SCAN MODE (scanning changed files only) ==="
    printf '%s\n' "${FILTERED_TARGETS[@]}"

    mkdir -p sc_tmp
    echo '[]' > sc_tmp/combined.json

    for t in "${FILTERED_TARGETS[@]}"; do
        abs="$REPO_ROOT/$t"
        echo ""
        echo "---------------------------------------------"
        echo "Running ScanCode on: $abs"
        echo "---------------------------------------------"

        run_scancode_with_timeout 300s \
          scancode --license \
                   --processes 4 \
                   --timeout 300 \
                   --json-pp sc_tmp/out.json \
                   "$abs"

        # Append only license detections
        jq -s '
          .[0] as $combined
          | .[1].license_detections as $new
          | ($combined + ($new // []))
        ' sc_tmp/combined.json sc_tmp/out.json > sc_tmp/merged.json

        mv sc_tmp/merged.json sc_tmp/combined.json
    done

    cp sc_tmp/combined.json scan_results.json
fi

###############################################################################
# Validate result JSON exists
###############################################################################
if [[ ! -s scan_results.json ]]; then
    echo "Error: scan_results.json missing or empty."
    exit 1
fi

###############################################################################
# Extract licenses
###############################################################################
jq -r '
  .[].license_expression? // empty
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

###############################################################################
# Compare to allowed licenses
###############################################################################
DISALLOWED=$(comm -23 detected_licenses.txt allowed_licenses_normalized.txt || true)

if [[ -n "$DISALLOWED" ]]; then
    echo "❌ Disallowed licenses detected:"
    echo "$DISALLOWED"
    exit 1
fi

echo "✔ All detected licenses are allowed."
exit 0