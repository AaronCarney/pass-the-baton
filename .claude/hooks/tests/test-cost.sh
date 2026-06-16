#!/bin/bash
# Unit tests for tools/cost.sh - transcript cost estimator.
# Usage: bash .claude/hooks/tests/test-cost.sh

export LC_ALL=C
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/tools/cost.sh"
COST_MODELS_LIB="$REPO_ROOT/lib/cost-models.sh"
TOKENS_LIB="$REPO_ROOT/lib/tokens.sh"

PASS=0
FAIL=0
FAILED_CASES=()

# shellcheck disable=SC1090
source "$COST_MODELS_LIB"
# shellcheck disable=SC1090
source "$TOKENS_LIB"

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS+1))
    echo "  PASS  $name"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name")
    echo "  FAIL  $name"
  fi
}

# ── fixture helpers ──────────────────────────────────────────────────────────

make_transcript() {
  # make_transcript <path> <json-turns...>
  # Writes each turn as a separate JSONL line.
  local path="$1"; shift
  : > "$path"
  for turn in "$@"; do
    printf '%s\n' "$turn" >> "$path"
  done
}

# Compute expected cost in test prologue using awk from PRICE constants
price_for() {
  # price_for <model> <primitive>
  cost_models::price "$1" "$2"
}

expected_cost() {
  # expected_cost <model> <cr> <cw5> <cw1> <fi> <out>
  cost_models::cost_of_turn "$@"
}

# ── Test setup ────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

TRANSCRIPT_DIR="$TMPDIR_TEST/transcripts"
mkdir -p "$TRANSCRIPT_DIR/proj-abc"

# ── Cycle 1: Single-turn cache_read only (opus-4-7) ──────────────────────────
echo "## single-turn cache_read (opus-4-7)"

{
  t="$TRANSCRIPT_DIR/proj-abc/single-cr.jsonl"
  make_transcript "$t" \
    '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":1000000,"input_tokens":0,"output_tokens":0},"model":"claude-opus-4-7"}}'

  out=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model claude-opus-4-7 2>/dev/null)
  p_cr=$(price_for claude-opus-4-7 cache_read)
  exp=$(awk -v p="$p_cr" 'BEGIN{printf "%.6f", 1000000*p/1000000}')

  assert "single cache_read: row shows 1000000 tok" \
    "printf '%s' \"\$out\" | grep -E 'cache_read.*1000000'"
  assert "single cache_read: row shows correct USD" \
    "printf '%s' \"\$out\" | grep -E 'cache_read.*\\\$'"
  assert "single cache_read: TOTAL equals price-table value" \
    "printf '%s' \"\$out\" | grep -E 'TOTAL.*\\\$'"
  # Verify exact numeric match
  total_line=$(printf '%s' "$out" | grep 'TOTAL')
  total_usd=$(printf '%s' "$total_line" | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  assert "single cache_read: TOTAL = $exp" \
    "[ '$total_usd' = '$exp' ]"
}

# ── Cycle 2: Each primitive in isolation at 1M tokens ────────────────────────
echo
echo "## per-primitive isolation (five tests)"

MODEL_ISO="claude-sonnet-4-6"

for prim in cache_read cache_write_5m cache_write_1h fresh_input output; do
  t="$TMPDIR_TEST/iso-${prim}.jsonl"

  case "$prim" in
    cache_read)
      turn='{"type":"assistant","message":{"usage":{"cache_read_input_tokens":1000000,"input_tokens":0,"output_tokens":0}}}'
      p_val=$(price_for "$MODEL_ISO" cache_read)
      args=(0 0 0 0 0); args[0]=1000000
      exp=$(awk -v p="$p_val" 'BEGIN{printf "%.6f", p}')
      ;;
    cache_write_5m)
      turn='{"type":"assistant","message":{"usage":{"cache_creation_input_tokens":1000000,"input_tokens":0,"output_tokens":0}}}'
      p_val=$(price_for "$MODEL_ISO" cache_write_5m)
      exp=$(awk -v p="$p_val" 'BEGIN{printf "%.6f", p}')
      ;;
    cache_write_1h)
      turn='{"type":"assistant","message":{"usage":{"cache_creation_input_tokens":0,"ephemeral_1h_input_tokens":1000000,"input_tokens":0,"output_tokens":0}}}'
      p_val=$(price_for "$MODEL_ISO" cache_write_1h)
      exp=$(awk -v p="$p_val" 'BEGIN{printf "%.6f", p}')
      ;;
    fresh_input)
      turn='{"type":"assistant","message":{"usage":{"input_tokens":1000000,"output_tokens":0}}}'
      p_val=$(price_for "$MODEL_ISO" base_in)
      exp=$(awk -v p="$p_val" 'BEGIN{printf "%.6f", p}')
      ;;
    output)
      turn='{"type":"assistant","message":{"usage":{"input_tokens":0,"output_tokens":1000000}}}'
      p_val=$(price_for "$MODEL_ISO" base_out)
      exp=$(awk -v p="$p_val" 'BEGIN{printf "%.6f", p}')
      ;;
  esac

  make_transcript "$t" "$turn"
  total_usd=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model "$MODEL_ISO" 2>/dev/null \
    | grep 'TOTAL' | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  assert "isolation $prim: TOTAL=$exp" \
    "[ '$total_usd' = '$exp' ]"
done

# ── Cycle 2b: ephemeral_5m extraction (regression: zeroing it must be caught) ─
echo
echo "## ephemeral_5m_input_tokens extraction (sonnet-4-6)"
{
  # Turn sets ephemeral_5m (1M) with ephemeral_1h present-but-zero so the
  # dual-name branch is active. The 5m cost must land in cache_write_5m.
  # Guards cost.sh's (.ephemeral_5m_input_tokens // 0) read: replacing it with
  # a literal 0 silently zeroed all 5m-cache cost on any 1h-present record and
  # passed the whole suite (no fixture ever set ephemeral_5m). See E8 RE-REVIEW-3.
  t="$TMPDIR_TEST/ephemeral5m.jsonl"
  turn='{"type":"assistant","message":{"usage":{"ephemeral_5m_input_tokens":1000000,"ephemeral_1h_input_tokens":0,"input_tokens":0,"output_tokens":0}}}'
  p_val=$(price_for "$MODEL_ISO" cache_write_5m)
  exp=$(awk -v p="$p_val" 'BEGIN{printf "%.6f", p}')
  make_transcript "$t" "$turn"
  total_usd=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model "$MODEL_ISO" 2>/dev/null \
    | grep 'TOTAL' | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  assert "ephemeral_5m priced as cache_write_5m: TOTAL=$exp (got $total_usd)" \
    "[ '$total_usd' = '$exp' ]"
}

# ── Cycle 3: Multi-turn mixed primitives ─────────────────────────────────────
echo
echo "## multi-turn mixed primitives (sonnet-4-6)"

{
  MODEL_MIX="claude-sonnet-4-6"
  t="$TMPDIR_TEST/mixed.jsonl"
  # 3 turns: cache_read=12000, cache_creation=8000, input=500, output=1500 each
  turn='{"type":"assistant","message":{"usage":{"cache_read_input_tokens":12000,"cache_creation_input_tokens":8000,"input_tokens":500,"output_tokens":1500}}}'
  make_transcript "$t" "$turn" "$turn" "$turn"

  p_cr=$(price_for "$MODEL_MIX" cache_read)
  p_cw5=$(price_for "$MODEL_MIX" cache_write_5m)
  p_fi=$(price_for "$MODEL_MIX" base_in)
  p_out=$(price_for "$MODEL_MIX" base_out)

  # Expected: 3 × (12000×p_cr + 8000×p_cw5 + 500×p_fi + 1500×p_out) / 1e6
  exp=$(awk -v cr=36000 -v cw5=24000 -v fi=1500 -v out=4500 \
    -v p_cr="$p_cr" -v p_cw5="$p_cw5" -v p_fi="$p_fi" -v p_out="$p_out" \
    'BEGIN{printf "%.6f", (cr*p_cr + cw5*p_cw5 + fi*p_fi + out*p_out)/1000000}')

  total_usd=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model "$MODEL_MIX" 2>/dev/null \
    | grep 'TOTAL' | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  assert "mixed-turns: TOTAL matches first-principles awk ($exp)" \
    "[ '$total_usd' = '$exp' ]"
}

# ── Cycle 3b: FIX-1 malformed JSONL line must not zero later turns ────────────
echo
echo "## malformed-line resilience (FIX-1 regression)"

{
  MODEL_MAL="claude-opus-4-7"
  t="$TMPDIR_TEST/malformed.jsonl"
  good='{"type":"assistant","message":{"usage":{"input_tokens":0,"output_tokens":1000000}}}'
  # valid turn, corrupt/partial line, valid turn - pre-fix this aborted jq and
  # silently zeroed every turn after the bad line.
  : > "$t"
  printf '%s\n' "$good" >> "$t"
  printf '%s\n' '{"type":"assistant","message":{"usage":{"output_tokens":' >> "$t"
  printf '%s\n' "$good" >> "$t"

  p_out=$(price_for "$MODEL_MAL" base_out)
  exp=$(awk -v out=2000000 -v p="$p_out" 'BEGIN{printf "%.6f", out*p/1000000}')
  total_usd=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model "$MODEL_MAL" 2>/dev/null \
    | grep 'TOTAL' | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  assert "malformed line skipped, both valid turns counted ($exp)" \
    "[ '$total_usd' = '$exp' ]"
}

# ── Cycle 4: --self-check ────────────────────────────────────────────────────
echo
echo "## --self-check (clean)"

{
  self_out=$(bash "$SCRIPT" --self-check 2>&1)
  rc=$?
  assert "--self-check exits 0" "[ '$rc' = '0' ]"
  assert "--self-check output contains PRICING_VERIFIED_DATE" \
    "printf '%s' \"\$self_out\" | grep -q 'PRICING_VERIFIED_DATE'"
  assert "--self-check output contains age=" \
    "printf '%s' \"\$self_out\" | grep -q 'age='"
}

# ── Cycle 5: --self-check with broken cost_of_turn ───────────────────────────
echo
echo "## --self-check detects arithmetic bug"

{
  broken_lib="$TMPDIR_TEST/cost-models-broken.sh"
  cp "$COST_MODELS_LIB" "$broken_lib"
  # Inject *2 on the output term so cost(2N) != 2*cost(N) - breaks linearity
  sed -i 's/out\*p_out/out*p_out*2/' "$broken_lib"

  broken_out=$(BATON_COST_MODELS_PATH="$broken_lib" bash "$SCRIPT" --self-check 2>&1)
  rc=$?
  assert "--self-check: broken lib exits nonzero" "[ '$rc' -ne 0 ]"

  # Uniform divisor mutation: all identity checks (linearity/additivity/ratio/
  # zero) are scale-invariant and pass anyway. Only the absolute price anchors
  # catch this. Regression guard for FIX-5.
  divisor_lib="$TMPDIR_TEST/cost-models-divisor.sh"
  cp "$COST_MODELS_LIB" "$divisor_lib"
  sed -i 's#/ 1000000#/ 2000000#' "$divisor_lib"
  divisor_out=$(BATON_COST_MODELS_PATH="$divisor_lib" bash "$SCRIPT" --self-check 2>&1)
  rc=$?
  assert "--self-check: divisor mutation exits nonzero" "[ '$rc' -ne 0 ]"
  assert "--self-check: divisor mutation fails a price anchor" \
    "printf '%s' \"\$divisor_out\" | grep -q 'FAIL  price anchor'"
}

# ── Cycle 6: --verify guard ───────────────────────────────────────────────────
echo
echo "## --verify guard"

{
  stderr_out=$(bash "$SCRIPT" --verify 2>&1 1>/dev/null)
  rc=$?
  assert "--verify without --corpus exits 2" "[ '$rc' = '2' ]"
  assert "--verify without --corpus: stderr has '--corpus required'" \
    "printf '%s' \"\$stderr_out\" | grep -q -- '--corpus required'"
}

# ── Cycle 7: --verify --corpus invokes calibrate ─────────────────────────────
echo
echo "## --verify --corpus delegates to calibrate"

{
  corpus_dir="$TMPDIR_TEST/corpus-verify"
  mkdir -p "$corpus_dir"
  printf 'x%.0s' {1..320} > "$corpus_dir/sample.sh"

  ratios_file="$TMPDIR_TEST/ratios-verify.sh"

  out=$(ANTHROPIC_API_KEY="dummy" \
        CALIBRATE_MOCK_TOKENS=100 \
        BATON_TOKEN_RATIOS="$ratios_file" \
        bash "$SCRIPT" --verify --corpus "$corpus_dir" --model claude-sonnet-4-6 2>&1)
  rc=$?
  assert "--verify --corpus: exits 0" "[ '$rc' = '0' ]"
  assert "--verify --corpus: shows old-vs-new ratios" \
    "printf '%s' \"\$out\" | grep -qiE 'BYTES_PER_TOKEN|ratio|->'"
}

# ── Cycle 8: --json output ────────────────────────────────────────────────────
echo
echo "## --json output"

{
  t="$TMPDIR_TEST/json-test.jsonl"
  make_transcript "$t" \
    '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":500000,"input_tokens":1000,"output_tokens":2000}}}'

  json_out=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model claude-sonnet-4-6 --json 2>/dev/null)
  rc=$?
  assert "--json: exits 0" "[ '$rc' = '0' ]"
  assert "--json: valid JSON with total_usd > 0" \
    "printf '%s' \"\$json_out\" | jq -e '.total_usd > 0' >/dev/null 2>&1"
  assert "--json: disclaimer field present" \
    "printf '%s' \"\$json_out\" | jq -e '.disclaimer | length > 0' >/dev/null 2>&1"
  assert "--json: disclaimer contains CC6 text" \
    "printf '%s' \"\$json_out\" | jq -r '.disclaimer' | grep -q 'Token counts are an estimate'"
  # FIX-4 regression: distinctive interior substrings, not just the prefix.
  assert "--json: disclaimer has ~5% and ~35% figures" \
    "printf '%s' \"\$json_out\" | jq -r '.disclaimer' | grep -q '~5%' && printf '%s' \"\$json_out\" | jq -r '.disclaimer' | grep -q '~35%'"
  assert "--json: disclaimer has 'bash tools/cost.sh --verify'" \
    "printf '%s' \"\$json_out\" | jq -r '.disclaimer' | grep -qF 'bash tools/cost.sh --verify'"
}

# ── Cycle 9: human-readable output shape ─────────────────────────────────────
echo
echo "## human-readable output shape"

{
  t="$TMPDIR_TEST/shape-test.jsonl"
  make_transcript "$t" \
    '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":100,"cache_creation_input_tokens":200,"input_tokens":300,"output_tokens":400}}}'

  out=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model claude-sonnet-4-6 2>/dev/null)
  assert "human output: cache_read row present" \
    "printf '%s' \"\$out\" | grep -q 'cache_read'"
  assert "human output: cache_write_5m row present" \
    "printf '%s' \"\$out\" | grep -q 'cache_write_5m'"
  assert "human output: cache_write_1h row present" \
    "printf '%s' \"\$out\" | grep -q 'cache_write_1h'"
  assert "human output: fresh_input row present" \
    "printf '%s' \"\$out\" | grep -q 'fresh_input'"
  assert "human output: output row present" \
    "printf '%s' \"\$out\" | grep -q '[[:space:]]output[[:space:]]'"
  assert "human output: TOTAL row present" \
    "printf '%s' \"\$out\" | grep -q 'TOTAL'"
  assert "human output: CC6 disclaimer present" \
    "printf '%s' \"\$out\" | grep -q 'Token counts are an estimate'"
  # FIX-4 regression: verbatim interior, not just the prefix.
  assert "human output: CC6 has ~5% and ~35% figures" \
    "printf '%s' \"\$out\" | grep -q '~5%' && printf '%s' \"\$out\" | grep -q '~35%'"
  assert "human output: CC6 has 'bash tools/cost.sh --verify'" \
    "printf '%s' \"\$out\" | grep -qF 'bash tools/cost.sh --verify'"
}

# ── Cycle 10: model alias / pinned / bogus ────────────────────────────────────
echo
echo "## model validation"

{
  t="$TMPDIR_TEST/model-test.jsonl"
  make_transcript "$t" \
    '{"type":"assistant","message":{"usage":{"output_tokens":100}}}'

  stderr_alias=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model claude-sonnet-4-6 2>&1 1>/dev/null)
  assert "--model alias: stderr contains 'alias'" \
    "printf '%s' \"\$stderr_alias\" | grep -q 'alias'"
  assert "--model alias: stderr contains 'pinned'" \
    "printf '%s' \"\$stderr_alias\" | grep -q 'pinned'"

  # FIX-8 regression: a pinned ID must price via its derived alias and emit a
  # correct TOTAL. The old test discarded stdout and only grepped (empty)
  # stderr, so a hard exit-2 abort passed vacuously.
  pinned_out=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model claude-sonnet-4-6-20260101 2>/dev/null)
  pinned_rc=$?
  pinned_total=$(printf '%s' "$pinned_out" | grep 'TOTAL' | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  p_out=$(price_for claude-sonnet-4-6 base_out)
  exp_pinned=$(awk -v out=100 -v p="$p_out" 'BEGIN{printf "%.6f", out*p/1000000}')
  assert "--model pinned: exits 0" "[ '$pinned_rc' = '0' ]"
  assert "--model pinned: TOTAL priced via derived alias ($exp_pinned)" \
    "[ '$pinned_total' = '$exp_pinned' ]"
  stderr_pinned=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model claude-sonnet-4-6-20260101 2>&1 1>/dev/null)
  assert "--model pinned: no alias warning in stderr" \
    "! printf '%s' \"\$stderr_pinned\" | grep -q 'alias'"

  stderr_bogus=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model bogus-model 2>&1 1>/dev/null)
  rc_bogus=$?
  assert "--model bogus: exits 2" "[ '$rc_bogus' = '2' ]"
  assert "--model bogus: stderr contains 'unknown model'" \
    "printf '%s' \"\$stderr_bogus\" | grep -qi 'unknown model'"
}

# ── Cycle 11: geo + fast multipliers ─────────────────────────────────────────
echo
echo "## geo and fast multipliers"

{
  t="$TMPDIR_TEST/mult-test.jsonl"
  make_transcript "$t" \
    '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":100000,"output_tokens":1000}}}'

  base_usd=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model claude-sonnet-4-6 2>/dev/null \
    | grep 'TOTAL' | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  geo_usd=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model claude-sonnet-4-6 --geo us 2>/dev/null \
    | grep 'TOTAL' | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  exp_geo=$(awk -v b="$base_usd" 'BEGIN{printf "%.6f", b * 1.10}')
  assert "--geo us applies ×1.10 to total" \
    "[ '$geo_usd' = '$exp_geo' ]"

  t_opus="$TMPDIR_TEST/fast-test.jsonl"
  make_transcript "$t_opus" \
    '{"type":"assistant","message":{"usage":{"output_tokens":1000}}}'

  base_fast=$(BATON_TRANSCRIPT_PATH="$t_opus" bash "$SCRIPT" --model claude-opus-4-7 2>/dev/null \
    | grep 'TOTAL' | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  fast_usd=$(BATON_TRANSCRIPT_PATH="$t_opus" bash "$SCRIPT" --model claude-opus-4-7 --fast 2>/dev/null \
    | grep 'TOTAL' | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  exp_fast=$(awk -v b="$base_fast" 'BEGIN{printf "%.6f", b * 6.00}')
  assert "--fast --model opus-4-7 applies ×6.00" \
    "[ '$fast_usd' = '$exp_fast' ]"

  # --fast rejected for sonnet
  stderr_fast_rej=$(BATON_TRANSCRIPT_PATH="$t" bash "$SCRIPT" --model claude-sonnet-4-6 --fast 2>&1 1>/dev/null)
  rc_fast_rej=$?
  assert "--fast --model sonnet exits 2" "[ '$rc_fast_rej' = '2' ]"
}

# ── Cycle 12: missing transcript / empty transcript ──────────────────────────
echo
echo "## missing and empty transcript"

{
  stderr_miss=$(BATON_TRANSCRIPT_PATH="/nonexistent/path/foo.jsonl" bash "$SCRIPT" --model claude-sonnet-4-6 2>&1 1>/dev/null)
  rc_miss=$?
  assert "missing transcript: exits 2" "[ '$rc_miss' = '2' ]"
  assert "missing transcript: stderr contains 'transcript'" \
    "printf '%s' \"\$stderr_miss\" | grep -qi 'transcript'"

  t_empty="$TMPDIR_TEST/empty.jsonl"
  : > "$t_empty"
  total_empty=$(BATON_TRANSCRIPT_PATH="$t_empty" bash "$SCRIPT" --model claude-sonnet-4-6 2>/dev/null \
    | grep 'TOTAL' | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  assert "empty transcript: TOTAL = 0.000000" \
    "[ '$total_empty' = '0.000000' ]"
}

# ── Cycle 13: --last N aggregation ───────────────────────────────────────────
echo
echo "## --last N aggregation"

{
  last_dir="$TMPDIR_TEST/last-test"
  mkdir -p "$last_dir"
  # Create 3 transcript files with deterministic timestamps
  for i in 1 2 3; do
    tf="$last_dir/session-00${i}.jsonl"
    make_transcript "$tf" \
      '{"type":"assistant","message":{"usage":{"output_tokens":1000}}}'
    touch -t "20260510010${i}" "$tf"
  done

  # Single transcript cost
  single_usd=$(BATON_TRANSCRIPT_PATH="$last_dir/session-001.jsonl" bash "$SCRIPT" --model claude-sonnet-4-6 2>/dev/null \
    | grep 'TOTAL' | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  exp_3=$(awk -v s="$single_usd" 'BEGIN{printf "%.6f", s*3}')

  last_usd=$(BATON_TRANSCRIPT_DIR="$last_dir" bash "$SCRIPT" --model claude-sonnet-4-6 --last 3 2>/dev/null \
    | grep 'TOTAL' | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
  assert "--last 3 aggregates 3 transcripts (total = 3× single)" \
    "[ '$last_usd' = '$exp_3' ]"
}

# ── Cycle 13b: --distribution quantile reporting ─────────────────────────────
echo
echo "## --distribution over --last N"

{
  dist_dir="$TMPDIR_TEST/dist-test"
  mkdir -p "$dist_dir"
  # 5 transcripts with deliberately uneven output_tokens so quantiles differ
  # meaningfully: 1k, 2k, 3k, 4k, 5k. Sorted USD: monotone increasing.
  i=0
  for tok in 1000 2000 3000 4000 5000; do
    i=$((i+1))
    tf="$dist_dir/session-00${i}.jsonl"
    make_transcript "$tf" \
      "{\"type\":\"assistant\",\"message\":{\"usage\":{\"output_tokens\":${tok}}}}"
    touch -t "20260510010${i}" "$tf"
  done

  # JSON output exposes distribution block when --distribution is set.
  dj=$(BATON_TRANSCRIPT_DIR="$dist_dir" bash "$SCRIPT" \
    --model claude-sonnet-4-6 --last 5 --distribution --json 2>/dev/null)
  assert "--distribution: json parses" \
    "printf '%s' \"\$dj\" | jq -e . >/dev/null 2>&1"
  assert "--distribution: count == 5" \
    "[ \"\$(printf '%s' \"\$dj\" | jq -r '.distribution.count')\" = '5' ]"
  # Sorted USD list for 1k..5k output tokens at sonnet-4-6 base_out=15.00:
  # per-session = tok × 15 / 1e6 → 0.015, 0.030, 0.045, 0.060, 0.075
  # min=0.015, p25=0.030, median=0.045, p75=0.060, p95=0.072, max=0.075
  # Numeric equality via jq (jq -r on a %.6f-formatted JSON number emits the
  # padded string '0.015000', which doesn't string-equal '0.015' - use ==).
  assert "--distribution: min == smallest session (0.015)" \
    "printf '%s' \"\$dj\" | jq -e '.distribution.min == 0.015' >/dev/null 2>&1"
  assert "--distribution: median == middle session (0.045)" \
    "printf '%s' \"\$dj\" | jq -e '.distribution.median == 0.045' >/dev/null 2>&1"
  assert "--distribution: max == largest session (0.075)" \
    "printf '%s' \"\$dj\" | jq -e '.distribution.max == 0.075' >/dev/null 2>&1"
  # min <= p25 <= median <= p75 <= p95 <= max (monotone)
  assert "--distribution: quantiles are monotone non-decreasing" \
    "printf '%s' \"\$dj\" | jq -e '
       .distribution as \$d |
       (\$d.min   <= \$d.p25)    and
       (\$d.p25   <= \$d.median) and
       (\$d.median<= \$d.p75)    and
       (\$d.p75   <= \$d.p95)    and
       (\$d.p95   <= \$d.max)
     ' >/dev/null 2>&1"
  # total_usd inside distribution == top-level total_usd (sanity, single source).
  assert "--distribution: distribution.total_usd == total_usd" \
    "printf '%s' \"\$dj\" | jq -e '.distribution.total_usd == .total_usd' >/dev/null 2>&1"
  # Regression: --distribution OFF leaves prior JSON shape untouched.
  no_dj=$(BATON_TRANSCRIPT_DIR="$dist_dir" bash "$SCRIPT" \
    --model claude-sonnet-4-6 --last 5 --json 2>/dev/null)
  assert "--distribution OFF: no distribution key in json" \
    "printf '%s' \"\$no_dj\" | jq -e 'has(\"distribution\") | not' >/dev/null 2>&1"

  # Human output includes a Distribution block when --distribution is set.
  hu=$(BATON_TRANSCRIPT_DIR="$dist_dir" bash "$SCRIPT" \
    --model claude-sonnet-4-6 --last 5 --distribution 2>/dev/null)
  assert "--distribution human: header present" \
    "printf '%s' \"\$hu\" | grep -qi 'Distribution across 5 session'"
  assert "--distribution human: median row present" \
    "printf '%s' \"\$hu\" | grep -q 'median'"
  assert "--distribution human: dossier S7 footnote present" \
    "printf '%s' \"\$hu\" | grep -qi 'right-skewed'"
  # Regression: --distribution OFF suppresses the block.
  no_hu=$(BATON_TRANSCRIPT_DIR="$dist_dir" bash "$SCRIPT" \
    --model claude-sonnet-4-6 --last 5 2>/dev/null)
  assert "--distribution OFF: human suppresses Distribution block" \
    "! printf '%s' \"\$no_hu\" | grep -qi 'Distribution across'"
}

# ── Cycle 14: no-network assertion ───────────────────────────────────────────
echo
echo "## no network"

{
  assert "no curl/wget/nc/dev-tcp in tools/cost.sh" \
    "! grep -E 'curl|wget|\bnc\b|/dev/tcp' '$SCRIPT'"
}

# ── Cycle 15: syntax check ────────────────────────────────────────────────────
echo
echo "## syntax"

{
  bash -n "$SCRIPT" 2>/dev/null
  rc=$?
  assert "bash -n: script is valid bash" "[ '$rc' = '0' ]"
}

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "====================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
