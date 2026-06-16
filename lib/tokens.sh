#!/bin/bash
# lib/tokens.sh - deterministic byte→token estimator with per-content-type ratios.
# Source this file; do not execute directly.

# Default ratios (bytes per token)
BYTES_PER_TOKEN_DEFAULT=3.2
BYTES_PER_TOKEN_JSON=2.7
BYTES_PER_TOKEN_CODE=3.2
BYTES_PER_TOKEN_DIFF=3.0
BYTES_PER_TOKEN_BASE64=2.0
BYTES_PER_TOKEN_PROSE=4.0

# Opus 4.7 content-dependent multipliers
OPUS_4_7_MULT_PROSE=1.10
OPUS_4_7_MULT_CODE=1.20

# tokens::load_ratios - source ratios override file if present. Idempotent.
tokens::load_ratios() {
  local ratios_file="${BATON_TOKEN_RATIOS:-$HOME/.config/baton/token-ratios.sh}"
  if [ -f "$ratios_file" ]; then
    # shellcheck disable=SC1090
    source "$ratios_file"
  fi
}

# _tokens::ratio_for <content_type> - echo the bytes-per-token ratio for content type.
_tokens::ratio_for() {
  local ctype="$1"
  case "$ctype" in
    json)   echo "${BYTES_PER_TOKEN_JSON:-2.7}" ;;
    code)   echo "${BYTES_PER_TOKEN_CODE:-3.2}" ;;
    diff)   echo "${BYTES_PER_TOKEN_DIFF:-3.0}" ;;
    base64) echo "${BYTES_PER_TOKEN_BASE64:-2.0}" ;;
    prose)  echo "${BYTES_PER_TOKEN_PROSE:-4.0}" ;;
    *)      echo "${BYTES_PER_TOKEN_DEFAULT:-3.2}" ;;
  esac
}

# _tokens::opus_mult <content_type> - echo Opus 4.7 multiplier for content type.
_tokens::opus_mult() {
  local ctype="$1"
  case "$ctype" in
    prose) echo "${OPUS_4_7_MULT_PROSE:-1.10}" ;;
    *)     echo "${OPUS_4_7_MULT_CODE:-1.20}" ;;
  esac
}

# tokens::estimate <byte_count> <content_type> [model]
# Prints integer token count (half-up rounding).
tokens::estimate() {
  local bytes="$1"
  local ctype="$2"
  local model="${3:-${BATON_COST_MODEL:-claude-sonnet-4-6}}"

  local ratio
  ratio=$(_tokens::ratio_for "$ctype")

  local mult=1.0
  case "$model" in
    claude-opus-4-7*)
      mult=$(_tokens::opus_mult "$ctype")
      ;;
  esac

  # Round half-up: int( bytes/ratio * mult + 0.5 )
  awk -v b="$bytes" -v r="$ratio" -v m="$mult" \
    'BEGIN { printf "%d\n", int(b / r * m + 0.5) }'
}

# tokens::estimate_file <path> <content_type> [model]
# Reads byte count from file, calls tokens::estimate. Exit 2 on read failure.
tokens::estimate_file() {
  local path="$1"
  local ctype="$2"
  local model="${3:-${BATON_COST_MODEL:-claude-sonnet-4-6}}"

  if [ ! -r "$path" ]; then
    echo "tokens::estimate_file: cannot read '$path'" >&2
    return 2
  fi

  local bytes
  bytes=$(wc -c < "$path")
  tokens::estimate "$bytes" "$ctype" "$model"
}

# tokens::content_type_for_path <path>
# Heuristic extension-based content type. Returns: json, code, prose, diff, base64, code (default).
tokens::content_type_for_path() {
  local path="$1"
  local base="${path##*/}"
  local ext="${base##*.}"

  # No extension → default
  if [ "$ext" = "$base" ]; then
    echo "code"
    return
  fi

  case "$ext" in
    json)
      echo "json" ;;
    sh|py|ts|js|tsx|jsx|rb|go|rs|c|cpp|h|hpp|java|kt|swift|cs|php|lua|r|scala|ex|exs|clj|hs|ml|fs|vim|zsh|bash|fish|ps1|pl|m)
      echo "code" ;;
    md|txt|rst|adoc|asciidoc|org)
      echo "prose" ;;
    patch|diff)
      echo "diff" ;;
    *)
      echo "code" ;;
  esac
}
