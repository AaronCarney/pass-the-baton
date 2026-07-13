#!/usr/bin/env bash
# lib/recommend-paired-deltas.sh - paired-compare driver for method-pair deltas.
# Wires tools/paired-compare.sh into the recommend pipeline.
#
# Public surface:
#   recommend_paired::all_pairs ARMS_DIR
#     Enumerate arm-*.jsonl in ARMS_DIR (LC_ALL=C sort), invoke paired-compare.sh
#     for each unordered pair, emit JSON object keyed by 'a-vs-b' pair name.
#     C-018 sentinel: if REPLAY_HARNESS_NONZERO_ARMS==0, emit error + return 1.
set -euo pipefail

_RPAD_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

recommend_paired::all_pairs() {
  local arms_dir="$1"

  # C-018 sentinel gate - honored unconditionally (defense-in-depth).
  if [ "${REPLAY_HARNESS_NONZERO_ARMS:-}" = "0" ]; then
    echo "all-zero replay-harness output - degenerate corpus" >&2
    return 1
  fi

  # Enumerate arm files deterministically.
  local arm_files=()
  while IFS= read -r f; do
    arm_files+=("$f")
  done < <(LC_ALL=C find "$arms_dir" -maxdepth 1 -name 'arm-*.jsonl' | LC_ALL=C sort)

  local n_arms="${#arm_files[@]}"
  if [ "$n_arms" -lt 2 ]; then
    echo "{}"
    return 0
  fi

  # Build JSON object for all unordered pairs.
  local pairs_json="{}"
  local i j
  for (( i=0; i<n_arms-1; i++ )); do
    for (( j=i+1; j<n_arms; j++ )); do
      local fa="${arm_files[$i]}"
      local fb="${arm_files[$j]}"
      local name_a name_b
      name_a=$(basename "$fa" .jsonl | sed 's/^arm-//')
      name_b=$(basename "$fb" .jsonl | sed 's/^arm-//')
      local pair_key="${name_a}-vs-${name_b}"

      # Invoke paired-compare.sh; output shape: {subset, log_diffs, clean:{...}, fired:null}
      local pc_out
      pc_out=$(bash "$_RPAD_REPO/tools/paired-compare.sh" \
        --arm-a "$fa" --arm-b "$fb" --key slug --json --subset clean \
        --seed "${SEED:-${STATS_DEFAULT_SEED:-42}}" 2>/dev/null)

      # Extract .clean block (already the consumer-facing shape).
      # On zero-overlap, paired-compare.sh emits {error:"..."} with no .clean key.
      local clean_block
      clean_block=$(echo "$pc_out" | jq 'if has("clean") then .clean else {n_paired:0,mean_diff:null,wilcoxon:null,ci:null,missing_from_a:[],missing_from_b:[]} end')

      # Wrap as {clean: ...} for consumer key path .clean.<sub-field>.
      local wrapped
      wrapped=$(jq -n --argjson r "$clean_block" '{clean:$r}')

      pairs_json=$(jq -n \
        --argjson acc "$pairs_json" \
        --arg key "$pair_key" \
        --argjson val "$wrapped" \
        '$acc + {($key): $val}')
    done
  done

  echo "$pairs_json"
}
