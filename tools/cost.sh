#!/usr/bin/env bash
# tools/cost.sh - baton cost subcommand.
# Reads Claude Code transcript JSONL; computes per-session cost breakdown.
# Usage: tools/cost.sh [--session <uuid>] [--model <id>] [--geo us] [--fast]
#                      [--verify] [--corpus DIR] [--self-check] [--last N]
#                      [--json] [--transcript <path>] [--arc <slug>]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

# Allow test override of cost-models lib path (used by --self-check mutation test)
COST_MODELS_LIB="${BATON_COST_MODELS_PATH:-$REPO_ROOT/lib/cost-models.sh}"
TOKENS_LIB="$REPO_ROOT/lib/tokens.sh"

# shellcheck disable=SC1090
source "$COST_MODELS_LIB"
# shellcheck disable=SC1090
source "$TOKENS_LIB"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/eventlog.sh"   # CC20: tolerant event-log record reader

# ---------------------------------------------------------------------------
# CC6 disclaimer (canonical text)
# ---------------------------------------------------------------------------
CC6_DISCLAIMER="Token counts are an estimate computed from content size and Anthropic's published per-model tokenizer behavior. Actual API billing uses Anthropic's authoritative count, which may differ by up to ~5% on prose and up to ~35% on code or structured text for Opus 4.7. For a billing-grade figure, use \`bash tools/cost.sh --verify --corpus DIR\`."

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SESSION_UUID=""
MODEL="${BATON_COST_MODEL:-claude-sonnet-4-6}"
GEO_FLAG=""
FAST_FLAG=""
VERIFY_MODE=0
CORPUS_DIR=""
SELF_CHECK=0
LAST_N=0
JSON_MODE=0
DIST_MODE=0
ARC_SLUG=""
TRANSCRIPT_OVERRIDE="${BATON_TRANSCRIPT_PATH:-}"
TRANSCRIPT_DIR_OVERRIDE="${BATON_TRANSCRIPT_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)      SESSION_UUID="$2";    shift 2 ;;
    --model)        MODEL="$2";           shift 2 ;;
    --geo)          GEO_FLAG="--geo $2";  shift 2 ;;
    --fast)         FAST_FLAG="--fast";   shift 1 ;;
    --verify)       VERIFY_MODE=1;        shift 1 ;;
    --corpus)       CORPUS_DIR="$2";      shift 2 ;;
    --self-check)   SELF_CHECK=1;         shift 1 ;;
    --last)         LAST_N="$2";          shift 2 ;;
    --json)         JSON_MODE=1;          shift 1 ;;
    --arc)          ARC_SLUG="$2";          shift 2 ;;
    --distribution) DIST_MODE=1;          shift 1 ;;
    --transcript)   TRANSCRIPT_OVERRIDE="$2"; shift 2 ;;
    --compare)
      shift 1
      _cc_args=()
      [[ -n "${MODEL:-}" ]] && _cc_args+=(--model "$MODEL")
      [[ -n "${TRANSCRIPT_OVERRIDE:-}" ]] && _cc_args+=(--transcript "$TRANSCRIPT_OVERRIDE")
      while [ $# -gt 0 ]; do
        case "$1" in
          --transcript) _cc_args+=(--transcript "$2"); shift 2;;
          --model)      _cc_args+=(--model "$2");      shift 2;;
          --json)       _cc_args+=(--json);            shift 1;;
          *) shift 1;;
        esac
      done
      exec bash "$(dirname "${BASH_SOURCE[0]}")/cost-compare.sh" "${_cc_args[@]}"
      ;;
    *) echo "cost.sh: unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# --arc mode: sum stamped cost_rollup events for one arc, price per-model
# ---------------------------------------------------------------------------
if [[ -n "${ARC_SLUG:-}" ]]; then
  log="${BATON_EVENT_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/baton/hook-events.jsonl}"
  declare -A CR CW5 CW1 FRESH OUT; events=0
  if [[ -f "$log" ]]; then
    while IFS=$'\t' read -r model cr cw5 cw1 fi out; do
      [[ -z "$model" ]] && continue
      CR[$model]=$(( ${CR[$model]:-0} + cr ));   CW5[$model]=$(( ${CW5[$model]:-0} + cw5 ))
      CW1[$model]=$(( ${CW1[$model]:-0} + cw1 )); FRESH[$model]=$(( ${FRESH[$model]:-0} + fi ))
      OUT[$model]=$(( ${OUT[$model]:-0} + out )); events=$(( events + 1 ))
    done < <(eventlog::stream "$log" | jq -r --arg slug "$ARC_SLUG" '
        select(.event=="cost_rollup" and .data.project_slug==$slug)
        | [.data.model, (.data.cache_read//0), (.data.cache_write_5m//0), (.data.cache_write_1h//0), (.data.fresh_input//0), (.data.output//0)]
        | @tsv')
  fi
  total_usd=0; tcr=0; tcw5=0; tcw1=0; tfi=0; tout=0; unpriced=()
  for model in "${!CR[@]}"; do
    # Producers stamp .message.model verbatim - a dated pin (<alias>-YYYYMMDD), not the
    # bare alias _CM_PRICE is keyed on. Strip exactly the trailing -<8 digits> so a real
    # dated id resolves to its priced alias (mirrors the main path's _priced_alias_for_turn).
    priced="$model"
    if [[ -z "${_CM_PRICE[${priced}:base_in]+set}" ]]; then
      priced="${model%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
    fi
    # A model still absent from the price table returns non-zero. Do NOT swallow it as $0 -
    # a silently-zeroed model under-reports the headline cost while its tokens still show,
    # defeating the envelope's honest-total guarantee. Track the RAW id and surface it instead.
    if usd=$(cost_models::cost_of_turn "$priced" "${CR[$model]}" "${CW5[$model]}" "${CW1[$model]}" "${FRESH[$model]}" "${OUT[$model]}" 2>/dev/null); then
      :
    else
      usd=0; unpriced+=("$model")
    fi
    total_usd=$(awk -v a="$total_usd" -v b="$usd" 'BEGIN{printf "%.6f", a+b}')
    tcr=$(( tcr + CR[$model] )); tcw5=$(( tcw5 + CW5[$model] )); tcw1=$(( tcw1 + CW1[$model] ))
    tfi=$(( tfi + FRESH[$model] )); tout=$(( tout + OUT[$model] ))
  done
  if [[ ${#unpriced[@]} -gt 0 ]]; then
    unpriced_json=$(printf '%s\n' "${unpriced[@]}" | jq -R . | jq -cs .)
  else
    unpriced_json='[]'
  fi
  if [[ "${JSON_MODE:-0}" -eq 1 ]]; then
    jq -cn --arg arc "$ARC_SLUG" --argjson ev "$events" --argjson usd "$total_usd" \
      --argjson cr "$tcr" --argjson cw5 "$tcw5" --argjson cw1 "$tcw1" --argjson fi "$tfi" --argjson out "$tout" \
      --argjson unpriced "$unpriced_json" \
      '{arc:$arc, events:$ev, usd:$usd, unpriced_models:$unpriced, tokens:{cache_read:$cr, cache_write_5m:$cw5, cache_write_1h:$cw1, fresh_input:$fi, output:$out}}'
  else
    printf 'arc: %s\n events: %d\n tokens: cache_read=%d cache_write_5m=%d cache_write_1h=%d fresh_input=%d output=%d\n usd: $%.6f\n' \
      "$ARC_SLUG" "$events" "$tcr" "$tcw5" "$tcw1" "$tfi" "$tout" "$total_usd"
    if [[ ${#unpriced[@]} -gt 0 ]]; then
      printf ' WARNING: %d unpriced model(s) contributed $0 to usd (tokens still counted): %s\n' "${#unpriced[@]}" "${unpriced[*]}"
    fi
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --self-check mode: arithmetic identity assertions
# ---------------------------------------------------------------------------
if [[ "$SELF_CHECK" -eq 1 ]]; then
  SELF_PASS=0
  SELF_FAIL=0
  CHECK_MODEL="claude-sonnet-4-6"

  self_assert() {
    local name="$1" cond="$2"
    if eval "$cond"; then
      SELF_PASS=$((SELF_PASS+1))
      echo "  PASS  $name"
    else
      SELF_FAIL=$((SELF_FAIL+1))
      echo "  FAIL  $name"
    fi
  }

  echo "## --self-check: arithmetic identity assertions"
  echo

  # (a) Linearity in output: cost(2N output) == 2 × cost(N output)
  for N in 1000 50000 1000000; do
    cost_2n=$(cost_models::cost_of_turn "$CHECK_MODEL" 0 0 0 0 $((N*2)))
    cost_n=$(cost_models::cost_of_turn "$CHECK_MODEL" 0 0 0 0 "$N")
    exp_2n=$(awk -v c="$cost_n" 'BEGIN{printf "%.6f", c*2}')
    self_assert "linearity: cost(2×$N output) == 2×cost($N output)" \
      "[ '$cost_2n' = '$exp_2n' ]"
  done

  # (a2) Cross-primitive ratio: cost(1M output) / cost(1M cache_read) must equal
  #      price(base_out) / price(cache_read) - catches wrong coefficients.
  #      With the output*2 mutation, the ratio would be 2× expected.
  _p_cr=$(cost_models::price "$CHECK_MODEL" cache_read)
  _p_out=$(cost_models::price "$CHECK_MODEL" base_out)
  _c_cr_1m=$(cost_models::cost_of_turn "$CHECK_MODEL" 1000000 0 0 0 0)
  _c_out_1m=$(cost_models::cost_of_turn "$CHECK_MODEL" 0 0 0 0 1000000)
  _ratio_actual=$(awk -v a="$_c_out_1m" -v b="$_c_cr_1m" 'BEGIN{printf "%.6f", a/b}')
  _ratio_exp=$(awk -v p_out="$_p_out" -v p_cr="$_p_cr" 'BEGIN{printf "%.6f", p_out/p_cr}')
  self_assert "cross-primitive ratio: cost(1M output)/cost(1M cache_read) == price_out/price_cr" \
    "[ '$_ratio_actual' = '$_ratio_exp' ]"

  # (b) Primitive isolation/additivity:
  # cost(N,0,0,0,0)+cost(0,N,0,0,0)+...+cost(0,0,0,0,N) == cost(N,N,N,N,N)
  N=100000
  c_cr=$(cost_models::cost_of_turn "$CHECK_MODEL" "$N" 0 0 0 0)
  c_cw5=$(cost_models::cost_of_turn "$CHECK_MODEL" 0 "$N" 0 0 0)
  c_cw1=$(cost_models::cost_of_turn "$CHECK_MODEL" 0 0 "$N" 0 0)
  c_fi=$(cost_models::cost_of_turn "$CHECK_MODEL" 0 0 0 "$N" 0)
  c_out=$(cost_models::cost_of_turn "$CHECK_MODEL" 0 0 0 0 "$N")
  c_all=$(cost_models::cost_of_turn "$CHECK_MODEL" "$N" "$N" "$N" "$N" "$N")
  c_sum=$(awk -v cr="$c_cr" -v cw5="$c_cw5" -v cw1="$c_cw1" -v fi="$c_fi" -v out="$c_out" \
    'BEGIN{printf "%.6f", cr+cw5+cw1+fi+out}')
  self_assert "additivity: sum of isolations == cost(N,N,N,N,N)" \
    "[ '$c_sum' = '$c_all' ]"

  # (c) Geo multiplier: cost(--geo us) == 1.1 × cost()
  c_base=$(cost_models::cost_of_turn "$CHECK_MODEL" 50000 10000 0 5000 2000)
  c_geo=$(cost_models::cost_of_turn "$CHECK_MODEL" 50000 10000 0 5000 2000 --geo us)
  c_geo_exp=$(awk -v b="$c_base" 'BEGIN{printf "%.6f", b*1.10}')
  self_assert "geo multiplier: --geo us == 1.10×base" \
    "[ '$c_geo' = '$c_geo_exp' ]"

  # (d) Fast multiplier (opus only): cost(--fast) == 6 × cost()
  FAST_MODEL="claude-opus-4-7"
  c_base_fast=$(cost_models::cost_of_turn "$FAST_MODEL" 0 0 0 0 5000)
  c_fast=$(cost_models::cost_of_turn "$FAST_MODEL" 0 0 0 0 5000 --fast)
  c_fast_exp=$(awk -v b="$c_base_fast" 'BEGIN{printf "%.6f", b*6.00}')
  self_assert "fast multiplier: opus --fast == 6.00×base" \
    "[ '$c_fast' = '$c_fast_exp' ]"

  # (e) Zero in / zero out == 0
  c_zero=$(cost_models::cost_of_turn "$CHECK_MODEL" 0 0 0 0 0)
  self_assert "zero inputs: cost == 0.000000" \
    "[ '$c_zero' = '0.000000' ]"

  # (f) ABSOLUTE price anchors. All checks above are scale-invariant: a uniform
  #     divisor/scale bug (e.g. /1000000 -> /2000000) preserves linearity,
  #     additivity, ratios and zero, so they pass anyway. Feeding exactly 1M of
  #     a single primitive MUST equal that primitive's per-MTok price verbatim.
  #     Derived from the PRICE table via cost_models::price (not magic numbers),
  #     so this stays correct if prices change but catches divisor errors.
  ANCHOR_MODEL="claude-opus-4-7"
  # <primitive>:<cr cw5 cw1 fi out> positional args to cost_of_turn
  _anchor_specs=(
    "cache_read:1000000 0 0 0 0"
    "cache_write_5m:0 1000000 0 0 0"
    "cache_write_1h:0 0 1000000 0 0"
    "base_in:0 0 0 1000000 0"
    "base_out:0 0 0 0 1000000"
  )
  for _spec in "${_anchor_specs[@]}"; do
    _prim="${_spec%%:*}"
    _args="${_spec#*:}"
    # shellcheck disable=SC2086 # $_args is intentionally word-split into 5 args
    _anchor_actual=$(cost_models::cost_of_turn "$ANCHOR_MODEL" $_args)
    _anchor_price=$(cost_models::price "$ANCHOR_MODEL" "$_prim")
    _anchor_exp=$(awk -v p="$_anchor_price" 'BEGIN{printf "%.6f", p}')
    self_assert "price anchor: 1M $_prim == price($ANCHOR_MODEL,$_prim)=$_anchor_exp" \
      "[ '$_anchor_actual' = '$_anchor_exp' ]"
  done

  echo
  # Print freshness info
  today=$(date +%Y-%m-%d)
  age_days=$(awk -v d1="$PRICING_VERIFIED_DATE" -v d2="$today" 'BEGIN {
    split(d1,a,"-"); split(d2,b,"-")
    t1=mktime(a[1]" "a[2]" "a[3]" 0 0 0")
    t2=mktime(b[1]" "b[2]" "b[3]" 0 0 0")
    print int((t2-t1)/86400)
  }')
  echo "PRICING_VERIFIED_DATE=$PRICING_VERIFIED_DATE  age=${age_days}d"
  echo

  echo "====================================="
  echo "Results: $SELF_PASS passed, $SELF_FAIL failed"
  if [[ "$SELF_FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --verify mode: delegate to calibrate-bytes-per-token.sh
# ---------------------------------------------------------------------------
if [[ "$VERIFY_MODE" -eq 1 ]]; then
  if [[ -z "$CORPUS_DIR" ]]; then
    echo "cost.sh: --corpus required when using --verify (CC8: session text must not be used as corpus)" >&2
    exit 2
  fi

  CALIBRATE="$REPO_ROOT/tools/calibrate-bytes-per-token.sh"
  RATIOS_FILE="${BATON_TOKEN_RATIOS:-$HOME/.config/baton/token-ratios.sh}"

  # Capture old ratios before calibration
  declare -A old_ratios
  if [[ -f "$RATIOS_FILE" ]]; then
    while IFS='=' read -r key val; do
      [[ "$key" =~ ^BYTES_PER_TOKEN_ ]] && old_ratios["$key"]="${val//[\"\']/}"
    done < <(grep '^BYTES_PER_TOKEN_' "$RATIOS_FILE" || true)
  fi

  # Delegate to calibrate script
  bash "$CALIBRATE" --corpus "$CORPUS_DIR" --model "$MODEL" --write

  # Re-source ratios and show diff
  if [[ -f "$RATIOS_FILE" ]]; then
    echo
    echo "Ratio changes:"
    while IFS='=' read -r key val; do
      old="${old_ratios[$key]:-<none>}"
      echo "  $key: $old -> $val"
    done < <(grep '^BYTES_PER_TOKEN_' "$RATIOS_FILE" || true)
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Model validation
# ---------------------------------------------------------------------------
# Check for unknown model (not in PRICE table and not a pinned ID)
if [[ -z "${_CM_PRICE[${MODEL}:base_in]+set}" ]] && [[ -z "${_CM_PINNED[$MODEL]+set}" ]]; then
  echo "cost.sh: unknown model '$MODEL'" >&2
  exit 2
fi

# _model_for_cost: the alias used for PRICE table lookups (cost_of_turn).
# Pinned IDs have the fixed shape <alias>-YYYYMMDD; strip exactly the trailing
# -<8 digits> so multi-segment aliases (claude-sonnet-4-6) survive intact.
_model_for_cost="$MODEL"
if [[ -z "${_CM_PRICE[${MODEL}:base_in]+set}" ]]; then
  _model_for_cost="${MODEL%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
  if [[ -z "${_CM_PRICE[${_model_for_cost}:base_in]+set}" ]]; then
    echo "cost.sh: cannot derive a priced alias from model '$MODEL' (got '$_model_for_cost')" >&2
    exit 2
  fi
fi

# _model_display: the pinned ID for display; also emit alias warning if needed
_alias_stderr="$(mktemp)"
_model_display=$(cost_models::resolve_id "$MODEL" 2>"$_alias_stderr")
if [[ -s "$_alias_stderr" ]]; then
  cat "$_alias_stderr" >&2
fi
rm -f "$_alias_stderr"

# Validate --fast eligibility before processing (exit early)
if [[ -n "$FAST_FLAG" ]]; then
  if ! _cm_is_fast_eligible "$_model_for_cost"; then
    echo "cost.sh: --fast is only available for claude-opus-4-6 and claude-opus-4-7" >&2
    exit 2
  fi
fi

# Build extra flags array for cost_of_turn (geo / fast multipliers). Defined
# before the parse loop so per-turn pricing applies identical multipliers to
# every turn, the distribution path, and the grand-total calls below.
EXTRA_FLAGS_ARR=()
[[ -n "$GEO_FLAG" ]] && EXTRA_FLAGS_ARR+=(--geo us)
[[ -n "$FAST_FLAG" ]] && EXTRA_FLAGS_ARR+=(--fast)

# _priced_alias_for_turn <raw_model>
#   Maps a per-turn .message.model to a priced alias usable by cost_of_turn.
#   Falls back to $_model_for_cost (the BATON_COST_MODEL-derived default)
#   when the turn's model is empty/null, or cannot be derived to a priced
#   alias. Memoised in _TURN_ALIAS_CACHE. --fast pre-validates against the
#   default model, so a per-turn opus alias keeps --fast eligible; a per-turn
#   non-opus alias under --fast would be rejected by cost_of_turn, so for the
#   --fast path we pin every turn to the (already-validated) default model.
_priced_alias_for_turn() {
  local raw="$1"
  if [[ -z "$raw" || "$raw" == "null" ]]; then
    printf '%s' "$_model_for_cost"; return 0
  fi
  if [[ -n "$FAST_FLAG" ]]; then
    printf '%s' "$_model_for_cost"; return 0
  fi
  if [[ -n "${_TURN_ALIAS_CACHE[$raw]+set}" ]]; then
    printf '%s' "${_TURN_ALIAS_CACHE[$raw]}"; return 0
  fi
  local alias="$raw"
  if [[ -z "${_CM_PRICE[${alias}:base_in]+set}" ]]; then
    alias="${raw%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
    if [[ -z "${_CM_PRICE[${alias}:base_in]+set}" ]]; then
      alias="$_model_for_cost"
    fi
  fi
  _TURN_ALIAS_CACHE["$raw"]="$alias"
  printf '%s' "$alias"
}

# ---------------------------------------------------------------------------
# Transcript resolution
# ---------------------------------------------------------------------------
_find_transcripts() {
  # Returns list of transcript paths (newest-first) under ~/.claude/projects/
  local projects_dir="$HOME/.claude/projects"
  if [[ ! -d "$projects_dir" ]]; then
    return
  fi
  find "$projects_dir" -maxdepth 2 -name "*.jsonl" -type f 2>/dev/null \
    | xargs ls -t 2>/dev/null
}

if [[ "$LAST_N" -gt 0 ]]; then
  # Collect N most recent transcripts
  if [[ -n "${TRANSCRIPT_DIR_OVERRIDE:-}" ]]; then
    mapfile -t TRANSCRIPT_PATHS < <(
      find "$TRANSCRIPT_DIR_OVERRIDE" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null \
        | xargs ls -t 2>/dev/null \
        | head -n "$LAST_N"
    )
  else
    mapfile -t TRANSCRIPT_PATHS < <(_find_transcripts | head -n "$LAST_N")
  fi
  if [[ "${#TRANSCRIPT_PATHS[@]}" -eq 0 ]]; then
    echo "cost.sh: no transcript files found" >&2
    exit 2
  fi
else
  # Single transcript
  if [[ -n "$TRANSCRIPT_OVERRIDE" ]]; then
    TRANSCRIPT_PATHS=("$TRANSCRIPT_OVERRIDE")
  elif [[ -n "$SESSION_UUID" ]]; then
    # Search by UUID under ~/.claude/projects/
    mapfile -t TRANSCRIPT_PATHS < <(
      find "$HOME/.claude/projects" -maxdepth 2 -name "${SESSION_UUID}.jsonl" -type f 2>/dev/null
    )
    if [[ "${#TRANSCRIPT_PATHS[@]}" -eq 0 ]]; then
      echo "cost.sh: transcript not found for session '$SESSION_UUID'" >&2
      exit 2
    fi
    TRANSCRIPT_PATHS=("${TRANSCRIPT_PATHS[0]}")
  else
    # Default: most recently updated transcript
    mapfile -t TRANSCRIPT_PATHS < <(_find_transcripts | head -1)
    if [[ "${#TRANSCRIPT_PATHS[@]}" -eq 0 ]]; then
      echo "cost.sh: no transcript files found under ~/.claude/projects/" >&2
      exit 2
    fi
  fi
fi

# Verify each transcript exists
for tp in "${TRANSCRIPT_PATHS[@]}"; do
  if [[ ! -f "$tp" ]]; then
    echo "cost.sh: transcript file not found: $tp" >&2
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# Parse transcripts and aggregate token counts
# ---------------------------------------------------------------------------
# Aggregate all primitives across all selected transcripts. PER_SESSION_USD
# collects per-transcript totals when --distribution is set (drives quantile
# reporting); empty otherwise so the existing aggregate path is untouched.
TOT_CR=0; TOT_CW5=0; TOT_CW1=0; TOT_FI=0; TOT_OUT=0
PER_SESSION_USD=()

# Per-turn pricing accumulators (E19-004): each turn is priced at its own
# .message.model; BATON_COST_MODEL ($_model_for_cost) is the fallback when
# the turn does not record one. PER_TURN_USD aggregates these correctly even
# when a session mixes models. TURN_COUNT is the number of priced assistant
# turns. A small alias cache avoids re-deriving the priced alias per turn.
PER_TURN_USD=0
TURN_COUNT=0
declare -A _TURN_ALIAS_CACHE=()

# Pre-build extra flags array once so the distribution path applies the same
# geo / fast multipliers as the grand-total cost_of_turn calls below - keeps
# Σ(PER_SESSION_USD) ≈ USD_TOTAL under any flag combination.
_DIST_EXTRA_FLAGS=()
[[ -n "$GEO_FLAG" ]] && _DIST_EXTRA_FLAGS+=(--geo us)
[[ -n "$FAST_FLAG" ]] && _DIST_EXTRA_FLAGS+=(--fast)

for tp in "${TRANSCRIPT_PATHS[@]}"; do
  # Per-transcript accumulators (reset each iteration). For --distribution
  # we compute this session's USD from its own primitives; otherwise we just
  # roll the per-message tokens straight into the grand total.
  S_CR=0; S_CW5=0; S_CW1=0; S_FI=0; S_OUT=0
  while IFS=$'\t' read -r cr cw5 cw1 fi out turn_raw_model; do
    S_CR=$((S_CR + cr))
    S_CW5=$((S_CW5 + cw5))
    S_CW1=$((S_CW1 + cw1))
    S_FI=$((S_FI + fi))
    S_OUT=$((S_OUT + out))

    # Per-turn pricing (E19-004): price this turn at its own .message.model,
    # falling back to $_model_for_cost when the turn's model is absent, the
    # literal null, or not derivable to a priced alias.
    _turn_alias=$(_priced_alias_for_turn "$turn_raw_model")
    _turn_usd=$(cost_models::cost_of_turn "$_turn_alias" \
      "$cr" "$cw5" "$cw1" "$fi" "$out" \
      "${EXTRA_FLAGS_ARR[@]+"${EXTRA_FLAGS_ARR[@]}"}")
    PER_TURN_USD=$(awk -v a="$PER_TURN_USD" -v b="$_turn_usd" 'BEGIN{printf "%.6f", a+b}')
    TURN_COUNT=$((TURN_COUNT + 1))
  done < <(
    # -R + fromjson? makes parsing tolerant per-line: one corrupt/partial
    # JSONL line (interrupted session, partial write) is skipped instead of
    # aborting the whole stream and silently zeroing every later turn.
    # 6th column carries .message.model verbatim ("" when absent/null) for
    # per-turn pricing; null normalises to "" so the fallback path triggers.
    jq -rR '
      (fromjson? // empty) |
      select(.type == "assistant" or (.message != null)) |
      . as $line |
      .message.usage |
      if . == null then empty else
        [
          (.cache_read_input_tokens // 0),
          (
            if (.ephemeral_5m_input_tokens != null or .ephemeral_1h_input_tokens != null) then
              (.ephemeral_5m_input_tokens // 0)
            else
              (.cache_creation_input_tokens // 0)
            end
          ),
          (.ephemeral_1h_input_tokens // 0),
          (.input_tokens // 0),
          (.output_tokens // 0),
          ($line.message.model // "")
        ] | @tsv
      end
    ' "$tp" 2>/dev/null || true
  )
  # Roll per-session into grand totals (preserves prior --json / human shape).
  TOT_CR=$((TOT_CR + S_CR))
  TOT_CW5=$((TOT_CW5 + S_CW5))
  TOT_CW1=$((TOT_CW1 + S_CW1))
  TOT_FI=$((TOT_FI + S_FI))
  TOT_OUT=$((TOT_OUT + S_OUT))
  # Distribution-mode: capture this session's USD via cost_of_turn so geo/fast
  # multipliers apply identically to per-session quantiles and the grand total.
  if [[ "$DIST_MODE" -eq 1 ]]; then
    s_usd=$(cost_models::cost_of_turn "$_model_for_cost" \
      "$S_CR" "$S_CW5" "$S_CW1" "$S_FI" "$S_OUT" \
      "${_DIST_EXTRA_FLAGS[@]+"${_DIST_EXTRA_FLAGS[@]}"}")
    PER_SESSION_USD+=("$s_usd")
  fi
done

# ---------------------------------------------------------------------------
# Compute costs per primitive (each primitive × its price)
# ---------------------------------------------------------------------------
p_cr=$(cost_models::price "$_model_for_cost" cache_read)
p_cw5=$(cost_models::price "$_model_for_cost" cache_write_5m)
p_cw1=$(cost_models::price "$_model_for_cost" cache_write_1h)
p_fi=$(cost_models::price "$_model_for_cost" base_in)
p_out=$(cost_models::price "$_model_for_cost" base_out)

# Per-primitive breakdown rows (informational): each aggregated primitive priced
# at the default model. cost_of_turn one call each, rest zero. EXTRA_FLAGS_ARR
# was built before the parse loop.
USD_CR=$(cost_models::cost_of_turn "$_model_for_cost" "$TOT_CR" 0 0 0 0 "${EXTRA_FLAGS_ARR[@]+"${EXTRA_FLAGS_ARR[@]}"}")
USD_CW5=$(cost_models::cost_of_turn "$_model_for_cost" 0 "$TOT_CW5" 0 0 0 "${EXTRA_FLAGS_ARR[@]+"${EXTRA_FLAGS_ARR[@]}"}")
USD_CW1=$(cost_models::cost_of_turn "$_model_for_cost" 0 0 "$TOT_CW1" 0 0 "${EXTRA_FLAGS_ARR[@]+"${EXTRA_FLAGS_ARR[@]}"}")
USD_FI=$(cost_models::cost_of_turn "$_model_for_cost" 0 0 0 "$TOT_FI" 0 "${EXTRA_FLAGS_ARR[@]+"${EXTRA_FLAGS_ARR[@]}"}")
USD_OUT=$(cost_models::cost_of_turn "$_model_for_cost" 0 0 0 0 "$TOT_OUT" "${EXTRA_FLAGS_ARR[@]+"${EXTRA_FLAGS_ARR[@]}"}")

# Authoritative total = sum of per-turn costs, each priced at its own
# .message.model (E19-004). For single-model transcripts this equals the
# breakdown sum exactly; for mixed-model transcripts it is the correct figure.
# Re-format through awk so an empty transcript (TURN_COUNT=0) still emits the
# canonical "0.000000" shape rather than a bare "0".
USD_TOTAL=$(awk -v t="$PER_TURN_USD" 'BEGIN{printf "%.6f", t}')

# Session ID for display
SESSION_ID="${SESSION_UUID:-${TRANSCRIPT_PATHS[0]##*/}}"
SESSION_ID="${SESSION_ID%.jsonl}"

# ---------------------------------------------------------------------------
# Distribution (--distribution): order stats over per-session USD totals.
# Reports count, min, p25, median, p75, p95, max - answering "is my last-N
# average dominated by one runaway session?" (dossier §S7: cost is right-
# skewed; mean alone is undisciplined). Quantiles use linear interpolation;
# `sort -n` is POSIX so this stays portable across mawk/gawk.
# ---------------------------------------------------------------------------
DIST_N=0
DIST_MIN="0.000000"; DIST_P25="0.000000"; DIST_MEDIAN="0.000000"
DIST_P75="0.000000"; DIST_P95="0.000000"; DIST_MAX="0.000000"
if [[ "$DIST_MODE" -eq 1 ]] && [[ "${#PER_SESSION_USD[@]}" -gt 0 ]]; then
  _dist_stats=$(printf '%s\n' "${PER_SESSION_USD[@]}" | LC_ALL=C sort -n | LC_ALL=C awk '
    function quant(p,   idx, lo, frac) {
      if (n <= 1) return v[1]
      idx = (n-1)*p + 1
      lo = int(idx)
      if (lo >= n) return v[n]
      frac = idx - lo
      return v[lo] + frac*(v[lo+1]-v[lo])
    }
    { v[NR]=$1+0 }
    END {
      n=NR
      if (n==0) { print "0\t0\t0\t0\t0\t0\t0"; exit }
      printf "%d\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\n",
        n, v[1], quant(0.25), quant(0.50), quant(0.75), quant(0.95), v[n]
    }')
  IFS=$'\t' read -r DIST_N DIST_MIN DIST_P25 DIST_MEDIAN DIST_P75 DIST_P95 DIST_MAX <<<"$_dist_stats"
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ "$JSON_MODE" -eq 1 ]]; then
  if [[ "$DIST_MODE" -eq 1 ]]; then
    jq -n \
      --arg session_id "$SESSION_ID" \
      --arg model "$_model_display" \
      --argjson cache_read "$TOT_CR" \
      --argjson cache_write_5m "$TOT_CW5" \
      --argjson cache_write_1h "$TOT_CW1" \
      --argjson fresh_input "$TOT_FI" \
      --argjson output "$TOT_OUT" \
      --argjson total_usd "$USD_TOTAL" \
      --argjson cost_usd "$USD_TOTAL" \
      --argjson turns "$TURN_COUNT" \
      --argjson dist_count "$DIST_N" \
      --argjson dist_min "$DIST_MIN" \
      --argjson dist_p25 "$DIST_P25" \
      --argjson dist_median "$DIST_MEDIAN" \
      --argjson dist_p75 "$DIST_P75" \
      --argjson dist_p95 "$DIST_P95" \
      --argjson dist_max "$DIST_MAX" \
      --arg disclaimer "$CC6_DISCLAIMER" \
      '{
        session_id: $session_id,
        model: $model,
        primitives: {
          cache_read: $cache_read,
          cache_write_5m: $cache_write_5m,
          cache_write_1h: $cache_write_1h,
          fresh_input: $fresh_input,
          output: $output
        },
        total_usd: $total_usd,
        cost_usd: $cost_usd,
        turns: $turns,
        distribution: {
          count: $dist_count,
          min: $dist_min,
          p25: $dist_p25,
          median: $dist_median,
          p75: $dist_p75,
          p95: $dist_p95,
          max: $dist_max,
          total_usd: $total_usd
        },
        disclaimer: $disclaimer
      }'
  else
    jq -n \
      --arg session_id "$SESSION_ID" \
      --arg model "$_model_display" \
      --argjson cache_read "$TOT_CR" \
      --argjson cache_write_5m "$TOT_CW5" \
      --argjson cache_write_1h "$TOT_CW1" \
      --argjson fresh_input "$TOT_FI" \
      --argjson output "$TOT_OUT" \
      --argjson total_usd "$USD_TOTAL" \
      --argjson cost_usd "$USD_TOTAL" \
      --argjson turns "$TURN_COUNT" \
      --arg disclaimer "$CC6_DISCLAIMER" \
      '{
        session_id: $session_id,
        model: $model,
        primitives: {
          cache_read: $cache_read,
          cache_write_5m: $cache_write_5m,
          cache_write_1h: $cache_write_1h,
          fresh_input: $fresh_input,
          output: $output
        },
        total_usd: $total_usd,
        cost_usd: $cost_usd,
        turns: $turns,
        disclaimer: $disclaimer
      }'
  fi
else
  # Human-readable
  SEP="─────────────────────────────────────────────────────"
  printf 'baton cost - session %s on %s\n' "$SESSION_ID" "$_model_display"
  printf '%s\n' "$SEP"
  printf '%-16s %12d tok    $%s\n' "cache_read"    "$TOT_CR"  "$USD_CR"
  printf '%-16s %12d tok    $%s\n' "cache_write_5m" "$TOT_CW5" "$USD_CW5"
  printf '%-16s %12d tok    $%s\n' "cache_write_1h" "$TOT_CW1" "$USD_CW1"
  printf '%-16s %12d tok    $%s\n' "fresh_input"   "$TOT_FI"  "$USD_FI"
  printf '%-16s %12d tok    $%s\n' " output"       "$TOT_OUT" "$USD_OUT"
  printf '%s\n' "$SEP"
  printf 'TOTAL                          $%s\n' "$USD_TOTAL"
  if [[ "$DIST_MODE" -eq 1 ]] && [[ "$DIST_N" -gt 0 ]]; then
    printf '%s\n' "$SEP"
    printf 'Distribution across %d session(s):\n' "$DIST_N"
    printf '  min     $%s\n' "$DIST_MIN"
    printf '  p25     $%s\n' "$DIST_P25"
    printf '  median  $%s\n' "$DIST_MEDIAN"
    printf '  p75     $%s\n' "$DIST_P75"
    printf '  p95     $%s\n' "$DIST_P95"
    printf '  max     $%s\n' "$DIST_MAX"
    printf '  (cost is right-skewed; report median+p95 alongside TOTAL - dossier §S7)\n'
  fi
  printf '\n%s\n' "$CC6_DISCLAIMER"
fi
