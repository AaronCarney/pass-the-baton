#!/usr/bin/env bash
# test-retry-intent-classifier.sh - TDD suite for DR-9 retry-intent classifier pipeline.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

PASS=0; FAIL=0

assert() {
  local label="$1"; local cmd="$2"
  if eval "$cmd"; then
    echo "  PASS: $label"; PASS=$((PASS+1))
  else
    echo "  FAIL: $label"; FAIL=$((FAIL+1))
  fi
}

echo "=== retry-intent classifier tests ==="

# ---- Step 2: existence + executable -------------------------------------------
echo "--- existence checks ---"
assert 'kappa-py exists'          "[ -f \"$REPO_ROOT/tools/_retry_intent_kappa.py\" ]"
assert 'bootstrap.sh exists'      "[ -f \"$REPO_ROOT/tools/retry-intent-bootstrap.sh\" ]"
assert 'classify.sh exists'       "[ -f \"$REPO_ROOT/tools/retry-intent-classify.sh\" ]"
assert 'promote.sh exists'        "[ -f \"$REPO_ROOT/tools/retry-intent-promote.sh\" ]"
assert 'kappa-py executable'      "[ -x \"$REPO_ROOT/tools/_retry_intent_kappa.py\" ]"
assert 'bootstrap.sh executable'  "[ -x \"$REPO_ROOT/tools/retry-intent-bootstrap.sh\" ]"
assert 'classify.sh executable'   "[ -x \"$REPO_ROOT/tools/retry-intent-classify.sh\" ]"
assert 'promote.sh executable'    "[ -x \"$REPO_ROOT/tools/retry-intent-promote.sh\" ]"

# ---- Step 8: F11 pinned kappa constants ---------------------------------------
echo "--- kappa-py fixture assertions (F11 pinned constants) ---"
FIXTURE="$REPO_ROOT/.claude/hooks/tests/fixtures/outcome-proxies/retry-intent-known-disagreement.csv"
EXPECTED_KAPPA='0.726027397260274'
EXPECTED_ACCURACY='0.75'
EXPECTED_MACRO_F1='0.7333333333333333'
EXPECTED_N_HUMAN_PAIRS=10
EXPECTED_N_AGREEMENT=8

result=$(python3 "$REPO_ROOT/tools/_retry_intent_kappa.py" --input "$FIXTURE" 2>&1)
kappa=$(echo "$result" | jq -r '.kappa')
acc=$(echo "$result" | jq -r '.accuracy')
f1=$(echo "$result" | jq -r '.macro_f1')
np=$(echo "$result" | jq -r '.n_human_pairs')
na=$(echo "$result" | jq -r '.n_agreement')

assert 'kappa == 0.726027397260274 (hand-computed)' \
  "awk -v a=\"$kappa\" -v e=\"$EXPECTED_KAPPA\" 'BEGIN{exit !(((a-e)<1e-9) && ((e-a)<1e-9))}'"
assert 'accuracy == 0.75 (hand-computed)' \
  "awk -v a=\"$acc\" -v e=\"$EXPECTED_ACCURACY\" 'BEGIN{exit !(((a-e)<1e-9) && ((e-a)<1e-9))}'"
assert 'macro_f1 == 0.7333333333333333 (hand-computed)' \
  "awk -v a=\"$f1\" -v e=\"$EXPECTED_MACRO_F1\" 'BEGIN{exit !(((a-e)<1e-9) && ((e-a)<1e-9))}'"
assert 'n_human_pairs == 10' "[ \"$np\" = \"$EXPECTED_N_HUMAN_PAIRS\" ]"
assert 'n_agreement == 8'   "[ \"$na\" = \"$EXPECTED_N_AGREEMENT\" ]"

# ---- Step 9: promote test (supplementary) ------------------------------------
echo "--- promote test ---"
EXPECTED_STATUS='supplementary'
TMP_STATE=$(mktemp -d)
trap 'rm -rf "$TMP_STATE"' EXIT

bash "$REPO_ROOT/tools/retry-intent-promote.sh" --bootstrap-csv "$FIXTURE" --out "$TMP_STATE/status.json"
promote_status=$(jq -r '.status' "$TMP_STATE/status.json" 2>/dev/null || echo "missing")
promote_kappa=$(jq -r '.kappa'  "$TMP_STATE/status.json" 2>/dev/null || echo "0")
assert 'promote exits 0' "[ -f \"$TMP_STATE/status.json\" ]"
assert "promote status = '$EXPECTED_STATUS'" "[ \"$promote_status\" = \"$EXPECTED_STATUS\" ]"
assert 'promote status.json has computed_at' "jq -e '.computed_at | test(\"^[0-9]{4}-\")' \"$TMP_STATE/status.json\" >/dev/null"
assert 'promote status.json has kappa' "awk -v k=\"$promote_kappa\" 'BEGIN{exit !(k>0)}'"
assert 'promote status.json has gate_thresholds' "jq -e '.gate_thresholds.load_bearing.kappa' \"$TMP_STATE/status.json\" >/dev/null"

# ---- Step 10: empty-CSV path → triage ----------------------------------------
echo "--- promote empty-csv path ---"
EMPTY_CSV="$TMP_STATE/empty.csv"
printf 'trajectory_id,prompt_text,human_a,human_b,judge_label\n' > "$EMPTY_CSV"
bash "$REPO_ROOT/tools/retry-intent-promote.sh" --bootstrap-csv "$EMPTY_CSV" --out "$TMP_STATE/empty-status.json"
empty_status=$(jq -r '.status' "$TMP_STATE/empty-status.json" 2>/dev/null || echo "missing")
assert 'empty-csv promote → triage' "[ \"$empty_status\" = \"triage\" ]"

# ---- Step 11: bootstrap dry-run smoke (F12 a+b) --------------------------------
echo "--- bootstrap dry-run smoke (F12) ---"
TMP_DIR="$TMP_STATE/transcripts"
TMP_OUT="$TMP_STATE/bsout"
TMP_OUT_NO_FLAG="$TMP_STATE/bsout-noflag"
mkdir -p "$TMP_DIR"

# Build 3 tiny fixture transcripts (jsonl with user messages)
for i in 1 2 3; do
  printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"sample prompt %d first attempt"}]}}\n' "$i" > "$TMP_DIR/transcript$i.jsonl"
  printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"sample prompt %d retry again"}]}}\n' "$i" >> "$TMP_DIR/transcript$i.jsonl"
done

# F12 (a) gate-without-flag fails
set +e
bash "$REPO_ROOT/tools/retry-intent-bootstrap.sh" \
  --transcripts-dir "$TMP_DIR" --out "$TMP_OUT_NO_FLAG" --n 3
rc=$?
set -e
assert 'bootstrap without --allow-prompt-export → rc!=0' "[ $rc -ne 0 ]"
assert 'bootstrap without flag → no CSV emitted' "[ ! -f \"$TMP_OUT_NO_FLAG/bootstrap.csv\" ]"

# F12 (b) mode-0700 OUTDIR after successful run
bash "$REPO_ROOT/tools/retry-intent-bootstrap.sh" \
  --transcripts-dir "$TMP_DIR" --out "$TMP_OUT" --n 3 --allow-prompt-export
mode=$(stat -c '%a' "$TMP_OUT" 2>/dev/null || stat -f '%Lp' "$TMP_OUT")
assert 'OUTDIR mode = 0700 post-bootstrap' "[ \"$mode\" = \"700\" ]"
bs_csv_mode=$(stat -c '%a' "$TMP_OUT/bootstrap.csv" 2>/dev/null || stat -f '%Lp' "$TMP_OUT/bootstrap.csv" 2>/dev/null || echo "err")
assert 'bootstrap.csv mode = 0600' "[ \"$bs_csv_mode\" = \"600\" ]"
assert 'manifest exists with allow_prompt_export:true' \
  "jq -e '.allow_prompt_export == true' \"$TMP_OUT/bootstrap-manifest.json\" >/dev/null"

# ---- Step 12: classify stub test ---------------------------------------------
echo "--- classify stub tests ---"
# gemini-flash → rc=2
set +e
bash "$REPO_ROOT/tools/retry-intent-classify.sh" --csv "$FIXTURE" --judge gemini-flash
classify_rc=$?
set -e
assert 'classify gemini-flash → rc=2' "[ $classify_rc -eq 2 ]"

# haiku without ANTHROPIC_API_KEY → error
set +e
ANTHROPIC_API_KEY='' bash "$REPO_ROOT/tools/retry-intent-classify.sh" --csv "$FIXTURE" --judge haiku 2>/tmp/classify_err.txt
classify_haiku_rc=$?
set -e
assert 'classify haiku no-key → rc!=0' "[ $classify_haiku_rc -ne 0 ]"
assert 'classify haiku no-key → clear error message' "grep -q 'ANTHROPIC_API_KEY' /tmp/classify_err.txt"

# ---- summary -----------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
