#!/bin/bash
# Unit tests for tools/calibrate-bytes-per-token.sh
# Usage: bash .claude/hooks/tests/test-calibrate.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/tools/calibrate-bytes-per-token.sh"

PASS=0
FAIL=0
FAILED_CASES=()

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

# ---- helper: run script in subshell, capture stdout/stderr/rc ----
run_calibrate() {
  # Usage: run_calibrate [env_overrides...] -- [args...]
  # Sets CALIBRATE_MOCK_TOKENS if needed
  local -a env_vars=()
  local -a args=()
  local parsing_args=0
  for arg in "$@"; do
    if [ "$arg" = "--" ]; then parsing_args=1; continue; fi
    if [ "$parsing_args" -eq 0 ]; then env_vars+=("$arg"); else args+=("$arg"); fi
  done
  env "${env_vars[@]}" bash "$SCRIPT" "${args[@]}"
}

# ---- Cycle 1: Guard clauses ----
echo "## guard clauses"

{
  stderr_out=$(ANTHROPIC_API_KEY="" bash "$SCRIPT" 2>&1 1>/dev/null)
  rc=$?
  assert "empty-key: exits 2" "[ '$rc' = '2' ]"
  assert "empty-key: stderr contains ANTHROPIC_API_KEY required" \
    "printf '%s' \"\$stderr_out\" | grep -q 'ANTHROPIC_API_KEY required'"
}

{
  tmpdir=$(mktemp -d)
  stderr_out=$(ANTHROPIC_API_KEY="dummy" bash "$SCRIPT" --corpus "$tmpdir/nonexistent" 2>&1 1>/dev/null)
  rc=$?
  assert "missing-corpus: exits 2" "[ '$rc' = '2' ]"
  assert "missing-corpus: stderr contains corpus" \
    "printf '%s' \"\$stderr_out\" | grep -qi 'corpus'"
  rm -rf "$tmpdir"
}

# ---- Cycle 2: --help ----
echo
echo "## --help"

{
  out=$(ANTHROPIC_API_KEY="dummy" bash "$SCRIPT" --help 2>&1)
  rc=$?
  assert "--help: exits 0" "[ '$rc' = '0' ]"
  assert "--help: prints usage" "printf '%s' \"\$out\" | grep -qi 'usage'"
}

# ---- Cycle 3: bash -n syntax check ----
echo
echo "## syntax"

{
  bash -n "$SCRIPT" 2>/dev/null
  rc=$?
  assert "bash -n: script is valid bash" "[ '$rc' = '0' ]"
}

# ---- Cycle 4: curl appears exactly once ----
echo
echo "## network seam"

{
  count=$(grep -c 'curl' "$SCRIPT")
  assert "curl appears exactly once in script" "[ '$count' = '1' ]"
}

# ---- Cycle 5: mocked run - output shape ----
echo
echo "## mocked output shape"

{
  tmpdir=$(mktemp -d)
  corpus="$tmpdir/corpus"
  mkdir -p "$corpus"
  # 320 bytes of content
  python3 -c "print('x' * 319)" > "$corpus/sample.sh"

  out=$(ANTHROPIC_API_KEY="dummy" CALIBRATE_MOCK_TOKENS=100 bash "$SCRIPT" --corpus "$corpus" 2>/dev/null)
  rc=$?
  assert "mocked run: exits 0" "[ '$rc' = '0' ]"
  assert "mocked run: output contains B/tok" "printf '%s' \"\$out\" | grep -q 'B/tok'"
  assert "mocked run: byte column is numeric" \
    "printf '%s' \"\$out\" | grep -E '[0-9]+ bytes' | grep -q '[0-9]'"

  rm -rf "$tmpdir"
}

# ---- Cycle 6: ratio value check (320 bytes / 100 tokens = 3.200) ----
echo
echo "## ratio value"

{
  tmpdir=$(mktemp -d)
  corpus="$tmpdir/corpus"
  mkdir -p "$corpus"
  # Exactly 320 bytes (319 x's + newline from echo)
  python3 -c "import sys; sys.stdout.write('x' * 320)" > "$corpus/fixture.sh"

  out=$(ANTHROPIC_API_KEY="dummy" CALIBRATE_MOCK_TOKENS=100 bash "$SCRIPT" --corpus "$corpus" 2>/dev/null)
  assert "ratio: 320B/100tok = 3.200" "printf '%s' \"\$out\" | grep -q '3.200'"

  rm -rf "$tmpdir"
}

# ---- Cycle 7: --write mode ----
echo
echo "## --write mode"

{
  tmpdir=$(mktemp -d)
  corpus="$tmpdir/corpus"
  mkdir -p "$corpus"
  python3 -c "import sys; sys.stdout.write('x' * 320)" > "$corpus/fixture.sh"
  ratios_file="$tmpdir/token-ratios.sh"

  ANTHROPIC_API_KEY="dummy" CALIBRATE_MOCK_TOKENS=100 BATON_TOKEN_RATIOS="$ratios_file" \
    bash "$SCRIPT" --corpus "$corpus" --write >/dev/null 2>/dev/null
  rc=$?
  assert "--write: exits 0" "[ '$rc' = '0' ]"
  assert "--write: ratios file created" "[ -f '$ratios_file' ]"
  assert "--write: ratios file is valid bash" "bash -n '$ratios_file' 2>/dev/null; [ \$? -eq 0 ]"
  assert "--write: file contains BYTES_PER_TOKEN" "grep -q 'BYTES_PER_TOKEN' '$ratios_file'"

  rm -rf "$tmpdir"
}

# ---- Cycle 8: --write emits canonical keys tokens.sh consumes (FIX-9) ----
echo
echo "## ratios file content - canonical keys, end-to-end"

{
  tmpdir=$(mktemp -d)
  corpus="$tmpdir/corpus"
  mkdir -p "$corpus"
  # A .sh file classifies as canonical content type "code" (NOT "sh").
  python3 -c "import sys; sys.stdout.write('x' * 320)" > "$corpus/fixture.sh"
  ratios_file="$tmpdir/token-ratios.sh"

  ANTHROPIC_API_KEY="dummy" CALIBRATE_MOCK_TOKENS=100 BATON_TOKEN_RATIOS="$ratios_file" \
    bash "$SCRIPT" --corpus "$corpus" --write >/dev/null 2>/dev/null

  # 320 bytes / 100 tokens → 3.2, written under the canonical CODE key.
  assert "--write: emits canonical BYTES_PER_TOKEN_CODE=3.2" \
    "grep -qE '^BYTES_PER_TOKEN_CODE=3\.2\$' '$ratios_file'"
  # Regression guard: the divergent per-extension key must NOT be produced -
  # calibrate previously wrote BYTES_PER_TOKEN_SH which no estimator reads.
  assert "--write: does NOT emit dead BYTES_PER_TOKEN_SH key" \
    "! grep -q 'BYTES_PER_TOKEN_SH=' '$ratios_file'"

  lib_tokens="$REPO_ROOT/lib/tokens.sh"
  if [ -f "$lib_tokens" ]; then
    # End-to-end: the calibrated key must actually drive _tokens::ratio_for.
    rf=$(bash -c "
      source '$lib_tokens'
      BATON_TOKEN_RATIOS='$ratios_file'
      tokens::load_ratios
      _tokens::ratio_for code
    " 2>/dev/null)
    assert "--write + tokens: calibrated CODE ratio consumed (=3.2)" \
      "[ '$rf' = '3.2' ]"
  fi

  rm -rf "$tmpdir"
}

# ---- Cycle 9: CC6 disclaimer ----
echo
echo "## CC6 disclaimer"

{
  tmpdir=$(mktemp -d)
  corpus="$tmpdir/corpus"
  mkdir -p "$corpus"
  python3 -c "import sys; sys.stdout.write('x' * 320)" > "$corpus/fixture.sh"

  out=$(ANTHROPIC_API_KEY="dummy" CALIBRATE_MOCK_TOKENS=100 bash "$SCRIPT" --corpus "$corpus" 2>/dev/null)
  assert "CC6 disclaimer: output contains 'Token counts are an estimate'" \
    "printf '%s' \"\$out\" | grep -q 'Token counts are an estimate'"

  rm -rf "$tmpdir"
}

# ---- Cycle 10: --write aggregates a TRUE median, not a pooled mean ----
# Spec line 266: "aggregate medians per content type". 3 code files, mock
# 100 tok each, sizes 100/200/900 B → per-file ratios 1.0/2.0/9.0.
# Median = 2.0; the prior pooled-mean (sum_bytes/sum_tokens = 1200/300) = 4.0.
# A regression to mean yields 4.0 and fails here. E8 RE-REVIEW-4 (FIX-15).
echo
echo "## --write median aggregation (not pooled mean)"
{
  tmpdir=$(mktemp -d)
  corpus="$tmpdir/corpus"
  mkdir -p "$corpus"
  python3 -c "open('$corpus/a.py','w').write('a'*100)"
  python3 -c "open('$corpus/b.py','w').write('b'*200)"
  python3 -c "open('$corpus/c.py','w').write('c'*900)"
  ratios_file="$tmpdir/ratios.sh"

  ANTHROPIC_API_KEY="dummy" CALIBRATE_MOCK_TOKENS=100 BATON_TOKEN_RATIOS="$ratios_file" \
    bash "$SCRIPT" --corpus "$corpus" --write >/dev/null 2>/dev/null

  assert "--write median: BYTES_PER_TOKEN_CODE=2.0 (median, not mean 4.0)" \
    "grep -qx 'BYTES_PER_TOKEN_CODE=2.0' '$ratios_file'"
  assert "--write median: not the pooled-mean value 4.0" \
    "! grep -qx 'BYTES_PER_TOKEN_CODE=4.0' '$ratios_file'"

  rm -rf "$tmpdir"
}

echo
echo "====================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
