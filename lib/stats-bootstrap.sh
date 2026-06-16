#!/usr/bin/env bash
# lib/stats-bootstrap.sh - bootstrap CI engine (bash API, Python compute tier).
# Subcommands: bca | studentized | block | block-length-auto
set -uo pipefail
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO="$(cd "$_SD/.." && pwd)"
_PY="$_REPO/tools/_stats_bootstrap.py"

stats_bootstrap::_check_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo 'stats-bootstrap: python3 not found. Install Python 3.10+ and run: pip install -r requirements.txt' >&2
    return 2
  fi
  if ! python3 -c 'import numpy, scipy' 2>/dev/null; then
    echo 'stats-bootstrap: numpy/scipy not importable. Run: pip install -r requirements.txt' >&2
    return 2
  fi
}

stats_bootstrap::bca() {
  stats_bootstrap::_check_python || return 2
  local input="${1:--}" n="${2:-5000}" alpha="${3:-0.05}"
  python3 "$_PY" bca --input "$input" --n-resamples "$n" --alpha "$alpha" ${SEED:+--seed "$SEED"}
}

stats_bootstrap::studentized() {
  stats_bootstrap::_check_python || return 2
  local input="${1:--}" n="${2:-5000}" alpha="${3:-0.05}"
  python3 "$_PY" studentized --input "$input" --n-resamples "$n" --alpha "$alpha" ${SEED:+--seed "$SEED"}
}

stats_bootstrap::block() {
  stats_bootstrap::_check_python || return 2
  local input="${1:--}" n="${2:-5000}" alpha="${3:-0.05}" b="${4:-}"
  python3 "$_PY" block --input "$input" --n-resamples "$n" --alpha "$alpha" ${SEED:+--seed "$SEED"} ${b:+--block-length "$b"}
}

stats_bootstrap::block_length_auto() {
  stats_bootstrap::_check_python || return 2
  local input="${1:--}"
  python3 "$_PY" block-length-auto --input "$input"
}

# F6: production default n_resamples=10000 per L0 A5 line 69.
stats_bootstrap::cluster() {
  stats_bootstrap::_check_python || return 2
  local input="${1:--}" cluster_key="${2:-session_id}" value_key="${3:-value}" n="${4:-10000}" alpha="${5:-0.05}"
  python3 "$_PY" cluster --input "$input" --cluster-key "$cluster_key" --value-key "$value_key" --n-resamples "$n" --alpha "$alpha" ${SEED:+--seed "$SEED"}
}

stats_bootstrap::cuped() {
  stats_bootstrap::_check_python || return 2
  local input="${1:--}" covariate_keys="${2:?cuped requires comma-separated covariate keys}" value_key="${3:-value}"
  python3 "$_PY" cuped --input "$input" --covariate-keys "$covariate_keys" --value-key "$value_key"
}

stats_bootstrap::studentized_log() {
  stats_bootstrap::_check_python || return 2
  local input="${1:--}" n="${2:-10000}" alpha="${3:-0.05}"
  python3 "$_PY" studentized --input "$input" --n-resamples "$n" --alpha "$alpha" --log ${SEED:+--seed "$SEED"}
}

_main() {
  case "${1:-}" in
    --help|-h|'')
      cat <<'EOF'
Usage: lib/stats-bootstrap.sh SUBCOMMAND [OPTIONS]

Subcommands:
  bca                  BCa bootstrap CI (default; bias-corrected accelerated)
  studentized          Studentized bootstrap (for heteroskedastic data)
  block                Stationary block bootstrap (Politis & Romano 1994) for time-correlated data
  block-length-auto    Politis & White (2004) auto-selected block length
  cluster              Cluster bootstrap (session-level resample) for hierarchical data
  cuped                CUPED variance reduction via multi-covariate OLS (Deng et al. KDD 2013)

Options:
  --input PATH         JSONL input (one float or {"value": float} per line); - for stdin (default)
  --n-resamples N      Number of bootstrap resamples (default 5000; production default 10000)
  --alpha A            Significance level (default 0.05 → 95% CI)
  --seed S             RNG seed (omit for non-reproducible)
  --block-length B     For block subcommand (omit for auto)
  --log                Apply np.log to inputs before resampling; exp() back on point + CI bounds
  --cluster-key K      Row field to use as cluster identifier (default: session_id)
  --value-key K        Row field for the numeric outcome value (default: value)
  --covariate-keys K   Comma-separated covariate field names (required for cuped)
EOF
      return 0
      ;;
    bca|studentized|block|block-length-auto|cluster|cuped)
      stats_bootstrap::_check_python || return 2
      python3 "$_PY" "$@"
      ;;
    *)
      echo "stats-bootstrap: unknown subcommand '$1'" >&2
      return 1
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _main "$@"
fi
