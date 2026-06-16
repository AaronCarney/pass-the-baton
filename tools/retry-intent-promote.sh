#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IN=""; OUT="${REPO_ROOT}/.baton/retry-intent-status.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --bootstrap-csv) IN="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    -h|--help) echo 'Usage: retry-intent-promote.sh --bootstrap-csv CSV [--out PATH]'; exit 0;;
    *) echo "unknown flag '$1'" >&2; exit 1;;
  esac
done
[ -n "$IN" ] && [ -f "$IN" ] || { echo "missing --bootstrap-csv" >&2; exit 1; }
metrics=$(python3 "$REPO_ROOT/tools/_retry_intent_kappa.py" --input "$IN")
kappa=$(echo "$metrics" | jq -r '.kappa')
acc=$(echo "$metrics" | jq -r '.accuracy')
f1=$(echo "$metrics" | jq -r '.macro_f1')
status="triage"
awk -v k="$kappa" -v a="$acc" -v f="$f1" 'BEGIN{exit !(k>=0.70 && a>=0.80 && f>=0.65)}' && status="load_bearing"
if [ "$status" = "triage" ]; then
  awk -v k="$kappa" -v a="$acc" 'BEGIN{exit !((k>=0.40 && k<0.70) || (a>=0.60 && a<0.80))}' && status="supplementary"
fi
mkdir -p "$(dirname "$OUT")"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -cn --arg s "$status" --argjson m "$metrics" --arg ts "$now" \
  '{status: $s, computed_at: $ts, gate_thresholds: {load_bearing: {kappa: 0.70, accuracy: 0.80, macro_f1: 0.65}, supplementary_min_kappa: 0.40, supplementary_min_accuracy: 0.60}} + $m' > "$OUT"
echo "$status"
