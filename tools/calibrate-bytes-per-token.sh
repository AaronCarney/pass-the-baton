#!/usr/bin/env bash
# calibrate-bytes-per-token.sh - walk a corpus, call count_tokens API, compute B/tok ratios.
# Usage: calibrate-bytes-per-token.sh [--corpus DIR] [--model MODEL] [--write]
# Brief 4 §5+§9: count_tokens endpoint is free, independent quota.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
CORPUS_DIR="./corpus"
MODEL="claude-sonnet-4-6"
WRITE_MODE=0
RATIOS_FILE="${BATON_TOKEN_RATIOS:-$HOME/.config/baton/token-ratios.sh}"

# ---------------------------------------------------------------------------
# Usage / --help
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: calibrate-bytes-per-token.sh [OPTIONS]

Walk a corpus directory and call the Anthropic count_tokens API for each file
to compute bytes-per-token ratios. Optionally writes medians per content type
into the token-ratios config file.

Options:
  --corpus DIR    Directory of files to calibrate against (default: ./corpus)
  --model  MODEL  Model name for token counting (default: claude-sonnet-4-6)
  --write         Write computed medians to the ratios config file
  --help          Show this help and exit

Environment:
  ANTHROPIC_API_KEY          Required. API key for the count_tokens endpoint.
  BATON_TOKEN_RATIOS    Override path for the ratios output file.
  CALIBRATE_MOCK_TOKENS      If set, skip real HTTP and return this token count
                             for every file (for testing).
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --corpus)  CORPUS_DIR="$2"; shift 2 ;;
    --model)   MODEL="$2";      shift 2 ;;
    --write)   WRITE_MODE=1;    shift   ;;
    --help)    usage; exit 0            ;;
    *)         echo "calibrate-bytes-per-token.sh: unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Guard: API key required
# ---------------------------------------------------------------------------
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "baton: ANTHROPIC_API_KEY required for calibration" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Guard: corpus dir must exist
# ---------------------------------------------------------------------------
if [[ ! -d "$CORPUS_DIR" ]]; then
  echo "baton: corpus directory not found: $CORPUS_DIR" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# content_type_for_path - classify a file into a content type whose label
# matches the ratio keys tokens.sh actually consumes (json/code/prose/diff/
# base64/code-default). Delegate to the canonical tokens::content_type_for_path
# so calibration and estimation never diverge; the inline case is only a
# fallback mirror for when lib/tokens.sh is unavailable, and it MUST emit the
# same canonical labels (not sh/py/js/md/text, which no estimator reads).
# ---------------------------------------------------------------------------
_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ -r "$_REPO_ROOT/lib/tokens.sh" ]]; then
  # shellcheck source=../lib/tokens.sh
  source "$_REPO_ROOT/lib/tokens.sh"
fi

_content_type_for_path() {
  local path="$1"
  if declare -F tokens::content_type_for_path >/dev/null 2>&1; then
    tokens::content_type_for_path "$path"
    return
  fi
  case "${path##*.}" in
    json)                       echo "json"   ;;
    md|markdown|txt|rst)        echo "prose"  ;;
    patch|diff)                 echo "diff"   ;;
    *)                          echo "code"   ;;
  esac
}

# ---------------------------------------------------------------------------
# calibrate::_count_tokens - network seam (all HTTP calls go through here).
# Reads JSON request body on stdin, writes JSON response on stdout.
# Returns 0 on success, nonzero on error.
# ---------------------------------------------------------------------------
calibrate::_count_tokens() {
  # Mock seam: if CALIBRATE_MOCK_TOKENS is set, skip the real HTTP call.
  if [[ -n "${CALIBRATE_MOCK_TOKENS:-}" ]]; then
    printf '{"input_tokens":%d}\n' "$CALIBRATE_MOCK_TOKENS"
    return 0
  fi

  curl -sS https://api.anthropic.com/v1/messages/count_tokens \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d @-
}

# ---------------------------------------------------------------------------
# Process each file in corpus
# ---------------------------------------------------------------------------
# Per content type: newline-free space-separated list of per-file B/tok
# ratios, so --write can take a true median (spec: "aggregate medians").
declare -A type_ratios

while IFS= read -r -d '' f; do
  basename_f="$(basename "$f")"
  bytes="$(wc -c < "$f")"
  content_type="$(_content_type_for_path "$f")"

  # Build request body safely with jq --rawfile
  request_body="$(jq -n \
    --arg model "$MODEL" \
    --rawfile content "$f" \
    '{"model":$model,"messages":[{"role":"user","content":$content}]}')"

  response="$(printf '%s' "$request_body" | calibrate::_count_tokens)"
  toks="$(printf '%s' "$response" | jq -r '.input_tokens')"

  if [[ -z "$toks" || "$toks" == "null" ]]; then
    echo "calibrate-bytes-per-token.sh: failed to parse token count for $basename_f" >&2
    continue
  fi

  if [[ "$toks" -eq 0 ]]; then
    ratio="0.000"
  else
    ratio="$(LC_ALL=C awk "BEGIN { printf \"%.3f\", $bytes / $toks }")"
  fi

  printf "%-40s %8d bytes %8d tokens %6s B/tok %s\n" \
    "$basename_f" "$bytes" "$toks" "$ratio" "$content_type"

  # Collect the per-file ratio for a true per-type median in --write.
  # Zero-token files have an undefined ratio - exclude them from the sample.
  if [[ "$toks" -ne 0 ]]; then
    file_ratio="$(LC_ALL=C awk "BEGIN { printf \"%.6f\", $bytes / $toks }")"
    type_ratios["$content_type"]="${type_ratios[$content_type]:-} $file_ratio"
  fi

done < <(find "$CORPUS_DIR" -maxdepth 5 -type f -print0 | sort -z)

# ---------------------------------------------------------------------------
# --write: compute per-type medians and write ratios file
# ---------------------------------------------------------------------------
if [[ "$WRITE_MODE" -eq 1 ]]; then
  mkdir -p "$(dirname "$RATIOS_FILE")"

  # Load old values if present
  declare -A old_ratios
  if [[ -f "$RATIOS_FILE" ]]; then
    while IFS='=' read -r key val; do
      [[ "$key" =~ ^BYTES_PER_TOKEN_ ]] && old_ratios["$key"]="${val//[\"\']/}"
    done < <(grep '^BYTES_PER_TOKEN_' "$RATIOS_FILE" || true)
  fi

  # Build new ratios content
  {
    echo "# Generated by calibrate-bytes-per-token.sh on $(date +%Y-%m-%d)"
    echo "BYTES_PER_TOKEN_DEFAULT=3.2"
    for ct in "${!type_ratios[@]}"; do
      # Median of the per-file ratios for this content type.
      ct_ratio="$(printf '%s\n' ${type_ratios[$ct]} | LC_ALL=C sort -n | LC_ALL=C awk '
        { v[NR] = $1 }
        END {
          if (NR == 0) exit 1
          if (NR % 2) m = v[(NR + 1) / 2]
          else        m = (v[NR / 2] + v[NR / 2 + 1]) / 2.0
          printf "%.1f", m
        }')" || continue
      varname="BYTES_PER_TOKEN_$(echo "$ct" | tr '[:lower:]' '[:upper:]')"
      echo "${varname}=${ct_ratio}"
    done
  } > "$RATIOS_FILE"

  echo
  echo "Wrote $RATIOS_FILE:"
  # Print old vs new for each ratio
  while IFS='=' read -r key val; do
    old="${old_ratios[$key]:-<none>}"
    echo "  $key: $old -> $val"
  done < <(grep '^BYTES_PER_TOKEN_' "$RATIOS_FILE" || true)
fi

# ---------------------------------------------------------------------------
# CC6 disclaimer
# ---------------------------------------------------------------------------
echo
echo "Token counts are an estimate. Actual billing may vary. Use --verify for exact counts."
