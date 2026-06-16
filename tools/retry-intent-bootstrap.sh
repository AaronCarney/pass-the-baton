#!/usr/bin/env bash
# tools/retry-intent-bootstrap.sh - DR-9 bootstrap labeller harness.
# Privacy carve-out: this tool DOES export prompt text; --allow-prompt-export REQUIRED.
# Output is mode-0700 directory; manifest records seed + threshold + source corpus.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TRANSCRIPTS_DIR=""
OUT_DIR=""
N_SAMPLES=100
JACCARD_THRESHOLD=0.5
ALLOW_PROMPT_EXPORT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --transcripts-dir) TRANSCRIPTS_DIR="$2"; shift 2;;
    --out) OUT_DIR="$2"; shift 2;;
    --n) N_SAMPLES="$2"; shift 2;;
    --jaccard-threshold) JACCARD_THRESHOLD="$2"; shift 2;;
    --allow-prompt-export) ALLOW_PROMPT_EXPORT=1; shift;;
    -h|--help) echo 'Usage: retry-intent-bootstrap.sh --transcripts-dir PATH --out DIR [--n 100] [--jaccard-threshold 0.5] --allow-prompt-export'; exit 0;;
    *) echo "unknown flag '$1'" >&2; exit 1;;
  esac
done

[ -n "$TRANSCRIPTS_DIR" ] && [ -d "$TRANSCRIPTS_DIR" ] || { echo 'retry-intent-bootstrap: --transcripts-dir required' >&2; exit 1; }
[ -n "$OUT_DIR" ] || { echo 'retry-intent-bootstrap: --out required' >&2; exit 1; }

if [ "$ALLOW_PROMPT_EXPORT" -ne 1 ]; then
  echo 'retry-intent-bootstrap: --allow-prompt-export REQUIRED (prompt text is exported)' >&2
  exit 2
fi

# Mode-0700 OUTDIR per privacy posture.
umask 0177
mkdir -p "$OUT_DIR"
chmod 0700 "$OUT_DIR"

CSV="$OUT_DIR/bootstrap.csv"
MANIFEST="$OUT_DIR/bootstrap-manifest.json"

# Walk transcripts; collect (transcript_path, line_idx, prompt_text) for user-prompt-submit-ish lines.
detect_retries() {
  local f="$1"
  jq -r 'select(.type == "user" and (.message.role // "") == "user") | .message.content[0].text // empty' "$f" 2>/dev/null | nl -ba
}

rng_jaccard() {
  # args: tokens_json_a tokens_json_b -> float similarity to stdout
  jq -cn --argjson a "$1" --argjson b "$2" '
    ($a | length) as $la | ($b | length) as $lb
    | (($a + $b) | unique | length) as $u
    | (($a - ($a - $b)) | length) as $i
    | if $u == 0 then 0 else ($i / $u) end
  '
}

tokenize() {
  printf '%s' "$1" \
    | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' ' ' | tr ' ' '\n' \
    | awk 'length($0)>0' | sort -u | jq -R . | jq -cs .
}

: > "$CSV.tmp"
printf 'trajectory_id,prompt_text,human_a,human_b,judge_label\n' > "$CSV.tmp"

total_collected=0
while IFS= read -r f; do
  [ "$total_collected" -ge "$N_SAMPLES" ] && break
  ring=()
  while IFS=$'\t' read -r idx prompt; do
    [ -z "$prompt" ] && continue
    tok=$(tokenize "$prompt")
    max_sim=0
    for prior in "${ring[@]}"; do
      sim=$(rng_jaccard "$tok" "$prior")
      awk -v m="$max_sim" -v s="$sim" 'BEGIN{exit !(s>m)}' && max_sim="$sim"
    done
    is_retry=$(awk -v s="$max_sim" -v t="$JACCARD_THRESHOLD" 'BEGIN{exit !(s>=t)}'; echo $?)
    if [ "$is_retry" = "0" ]; then
      traj_id="$(basename "$f" .jsonl)-$idx"
      # CSV-quote prompt: replace " with ""
      esc=$(printf '%s' "$prompt" | sed 's/"/""/g')
      printf '%s,"%s",,,\n' "$traj_id" "$esc" >> "$CSV.tmp"
      total_collected=$((total_collected+1))
      [ "$total_collected" -ge "$N_SAMPLES" ] && break
    fi
    ring+=("$tok")
    # Keep last 3 priors.
    if [ "${#ring[@]}" -gt 3 ]; then ring=("${ring[@]:1}"); fi
  done < <(detect_retries "$f")
done < <(find "$TRANSCRIPTS_DIR" -name '*.jsonl' -type f | sort)

mv "$CSV.tmp" "$CSV"
chmod 0600 "$CSV"

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -cn \
  --argjson n "$total_collected" \
  --arg corpus "$TRANSCRIPTS_DIR" \
  --argjson thr "$JACCARD_THRESHOLD" \
  --arg ts "$now" \
  '{n_samples: $n, source_corpus: $corpus, jaccard_threshold: $thr, timestamp: $ts, allow_prompt_export: true}' > "$MANIFEST"
chmod 0600 "$MANIFEST"

echo "$CSV"
exit 0
