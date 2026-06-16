#!/usr/bin/env bash
# tools/retry-intent-classify.sh - DR-9 LLM-as-judge classifier.
# Cross-family: Haiku (Anthropic) + gpt-4o-mini (OpenAI) for DR-5 bias mitigation.
# Gemini-flash forward-deferred (TODO E16-followup).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/cost-models.sh"

CSV=""
JUDGE="haiku"
while [ $# -gt 0 ]; do
  case "$1" in
    --csv) CSV="$2"; shift 2;;
    --judge) JUDGE="$2"; shift 2;;
    -h|--help) echo 'Usage: retry-intent-classify.sh --csv PATH --judge {haiku|gpt-4o-mini|gemini-flash}'; exit 0;;
    *) echo "unknown flag '$1'" >&2; exit 1;;
  esac
done
[ -n "$CSV" ] && [ -f "$CSV" ] || { echo 'retry-intent-classify: --csv PATH required and must exist' >&2; exit 1; }

# Pre-flight credential check before touching CSV.
case "$JUDGE" in
  haiku)
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      echo 'retry-intent-classify: ANTHROPIC_API_KEY not set' >&2
      exit 2
    fi
    ;;
  gpt-4o-mini)
    if [ -z "${OPENAI_API_KEY:-}" ]; then
      echo 'retry-intent-classify: OPENAI_API_KEY not set' >&2
      exit 2
    fi
    ;;
esac

case "$JUDGE" in
  haiku|gpt-4o-mini) ;;
  gemini-flash)
    echo 'retry-intent-classify: gemini-flash forward-deferred; see TODO(E16-followup): non-Anthropic non-OpenAI judge family per L1 line 211' >&2
    exit 2
    ;;
  *) echo "retry-intent-classify: unknown --judge '$JUDGE' (haiku|gpt-4o-mini|gemini-flash)" >&2; exit 1;;
esac

SYSTEM_PROMPT='Classify the user prompt as one of exactly four classes. Reply with a single JSON object {"label": "<LABEL>", "confidence": <0..1 float>}. The four classes are: EXPLORATION (user is trying a new direction), CORRECTION (user is correcting prior assistant output), CLARIFICATION (user is asking for elaboration), OTHER (none of the above).'

call_haiku() {
  local prompt="$1"
  local model_alias='claude-haiku-4-5'
  local model_id
  model_id=$(cost_models::resolve_id "$model_alias" 2>/dev/null)
  [ -z "$model_id" ] && model_id="$model_alias"
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo 'retry-intent-classify: ANTHROPIC_API_KEY not set' >&2
    return 2
  fi
  local resp
  resp=$(curl -sS -X POST 'https://api.anthropic.com/v1/messages' \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' \
    -d "$(jq -cn --arg model "$model_id" --arg sys "$SYSTEM_PROMPT" --arg p "$prompt" '{model: $model, max_tokens: 64, system: $sys, messages: [{role: "user", content: $p}]}')")
  echo "$resp" | jq -r '.content[0].text // empty' | jq -r '.label // "OTHER"' 2>/dev/null || echo OTHER
}

call_gpt4o_mini() {
  local prompt="$1"
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo 'retry-intent-classify: OPENAI_API_KEY not set' >&2
    return 2
  fi
  local resp
  resp=$(curl -sS -X POST 'https://api.openai.com/v1/chat/completions' \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H 'content-type: application/json' \
    -d "$(jq -cn --arg sys "$SYSTEM_PROMPT" --arg p "$prompt" '{model: "gpt-4o-mini", response_format: {type: "json_object"}, max_tokens: 64, messages: [{role: "system", content: $sys}, {role: "user", content: $p}]}')")
  echo "$resp" | jq -r '.choices[0].message.content // empty' | jq -r '.label // "OTHER"' 2>/dev/null || echo OTHER
}

tmp=$(mktemp "${CSV}.classified.XXXXXX")
trap 'rm -f "$tmp"' EXIT

{
  IFS= read -r header
  echo "$header"
  while IFS= read -r line; do
    judge_label=$(echo "$line" | awk -F',' '{print $NF}')
    if [ -n "$judge_label" ]; then
      echo "$line"; continue
    fi
    prompt_text=$(echo "$line" | awk -F',' 'BEGIN{OFS=","} {print $2}' | sed 's/^"//; s/"$//; s/""/"/g')
    case "$JUDGE" in
      haiku) label=$(call_haiku "$prompt_text");;
      gpt-4o-mini) label=$(call_gpt4o_mini "$prompt_text");;
    esac
    [ -z "$label" ] && label="OTHER"
    # Replace empty trailing column.
    echo "${line%,*},${label}"
  done
} < "$CSV" > "$tmp"
mv "$tmp" "$CSV"
chmod 0600 "$CSV"
trap - EXIT
exit 0
