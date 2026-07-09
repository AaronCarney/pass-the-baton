#!/usr/bin/env bash
# tools/tune-threshold.sh - drive the checkpoint-threshold feedback controller (E-C).
# Observable entry point for the data-gathering / exploration phase. The controller is
# CAPABILITY-only: knobs (tune_*) and the scoring fn (tune_score_fn) come from config; this CLI
# just runs one cycle and reports it.
set -uo pipefail
_TT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/threshold-controller.sh
source "$_TT_REPO/lib/threshold-controller.sh"

usage() {
  cat <<'EOF'
Usage: tune-threshold.sh [--show | --dry-run | --once]

  --show      Print the current threshold, the selected scoring fn, and resolved knobs. No change.
  --dry-run   Measure + decide, print the proposed action. Never applies.
  --once      (default) Run one control cycle; applies only if every guard passes
              (outside deadband, inside safety band, dwell elapsed, no BATON_PCT_THRESHOLD pin).

All magnitudes are config knobs (env BATON_TUNE_* > config.json tune_* > placeholder default);
the scoring equation is the function named by tune_score_fn. Applies + tuning data only land
when event collection is ON (open an arc or set BATON_COLLECT=1).
EOF
}

MODE=once
case "${1:-}" in
  --show)    MODE=show ;;
  --dry-run) MODE=dry ;;
  --once|'') MODE=once ;;
  -h|--help) usage; exit 0 ;;
  *) echo "tune-threshold.sh: unknown arg: $1" >&2; usage >&2; exit 1 ;;
esac

# Operationalize 'collection-on for exploration': warn (never block) when events won't land.
if ! threshold_controller::collection_on; then
  echo 'tune-threshold: event collection is OFF - applies and tuning data will NOT be recorded.' >&2
  echo '                Open an arc (tools/project.sh mark-start <slug>) or set BATON_COLLECT=1.' >&2
fi

case "$MODE" in
  show)
    printf 'current threshold : %s\n' "$(checkpoint_threshold)"
    printf 'score fn          : %s\n' "$(threshold_controller::score_fn)"
    printf 'setpoint          : %s\n' "$(threshold_controller::setpoint)"
    printf 'deadband          : %s\n' "$(threshold_controller::deadband)"
    printf 'step              : %s\n' "$(threshold_controller::step)"
    printf 'safety band       : %s..%s\n' "$(threshold_controller::safety_min)" "$(threshold_controller::safety_max)"
    printf 'dwell seconds     : %s\n' "$(threshold_controller::dwell_seconds)"
    ;;
  dry)
    cur="$(checkpoint_threshold)"; sc="$(threshold_controller::score "$cur")"
    read -r action proposed <<<"$(threshold_controller::decide "$cur" "$sc")"
    printf '%s %s->%s (score=%s) [dry-run, not applied]\n' "$action" "$cur" "$proposed" "$sc"
    ;;
  once)
    threshold_controller::run_once
    ;;
esac
