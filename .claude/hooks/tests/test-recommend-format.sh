#!/usr/bin/env bash
# Tests for lib/recommend-format.sh - human + JSON output renderer
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO/lib/recommend-format.sh"

source "$LIB"

PASS=0; FAIL=0
_pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

# ── AGG1: full data - all winners non-null, argmax=34, crossing, no_sig_diff=false ──
AGG=$(cat <<'EOF'
{
  "winners": {"cost": "compact", "time": "clear-only", "outcome": "compact"},
  "per_method": {
    "cost": {"compact": {"median": 0.01, "ci": {"lower": 0.009, "upper": 0.011}}},
    "time": {"clear-only": {"median": 120, "ci": {"lower": 110, "upper": 130}}},
    "outcome": {"compact": {"success_rate": 0.85, "ci": {"lower": 0.80, "upper": 0.90}}}
  },
  "paired_deltas": {
    "compact-vs-clear-only": {
      "clean": {
        "n_paired": 30,
        "mean_diff": -0.002,
        "ci": {"lower": -0.004, "upper": -0.0001},
        "wilcoxon": {"statistic": 120, "p_value": 0.04}
      }
    }
  },
  "threshold_sweep": {
    "argmax": 34,
    "candidates": [{"pct": 34, "savings": 0.05}],
    "savings_vs_22_at_argmax": 0.05,
    "ci": {"lower": 0.03, "upper": 0.07}
  },
  "caveats": {
    "data_age_crossing": true,
    "crossings": [{"model": "claude-sonnet-4-6", "date": "2026-02-17"}],
    "outcome_data_insufficient": false,
    "no_significant_difference": false,
    "cost_producer_degenerate": false
  },
  "window": {"from": "2025-12-15", "to": "2026-05-29", "post_e16_days": 29},
  "session_count": 47
}
EOF
)

# ── AGG2: outcome insufficient, data_age_crossing=false ──
AGG2=$(cat <<'EOF'
{
  "winners": {"cost": "compact", "time": "clear-only", "outcome": null},
  "per_method": {
    "cost": {"compact": {"median": 0.01, "ci": {"lower": 0.009, "upper": 0.011}}},
    "time": {"clear-only": {"median": 120, "ci": {"lower": 110, "upper": 130}}},
    "outcome": {}
  },
  "paired_deltas": {},
  "threshold_sweep": {
    "argmax": 28,
    "candidates": [],
    "savings_vs_22_at_argmax": 0.02,
    "ci": null
  },
  "caveats": {
    "data_age_crossing": false,
    "crossings": [],
    "outcome_data_insufficient": true,
    "no_significant_difference": false,
    "cost_producer_degenerate": false
  },
  "window": {"from": "2026-05-05", "to": "2026-05-29", "post_e16_days": 13},
  "session_count": 10
}
EOF
)

# ── AGG3: paired deltas straddling zero - no_significant_difference=true ──
AGG3=$(cat <<'EOF'
{
  "winners": {"cost": "compact", "time": "clear-only", "outcome": "compact"},
  "per_method": {
    "cost": {"compact": {"median": 0.01, "ci": {"lower": 0.009, "upper": 0.011}}},
    "time": {"clear-only": {"median": 120, "ci": {"lower": 110, "upper": 130}}},
    "outcome": {"compact": {"success_rate": 0.85, "ci": {"lower": 0.80, "upper": 0.90}}}
  },
  "paired_deltas": {
    "compact-vs-clear-only": {
      "clean": {
        "n_paired": 20,
        "mean_diff": -0.001,
        "ci": {"lower": -0.005, "upper": 0.003},
        "wilcoxon": {"statistic": 95, "p_value": 0.30}
      }
    }
  },
  "threshold_sweep": {
    "argmax": 25,
    "candidates": [],
    "savings_vs_22_at_argmax": 0.01,
    "ci": null
  },
  "caveats": {
    "data_age_crossing": false,
    "crossings": [],
    "outcome_data_insufficient": false,
    "no_significant_difference": true,
    "cost_producer_degenerate": false
  },
  "window": {"from": "2026-01-01", "to": "2026-05-29", "post_e16_days": 29},
  "session_count": 20
}
EOF
)

# ── Human mode: AGG1 ────────────────────────────────────────────────────────
human=$(printf '%s' "$AGG" | recommend::format human)

# (a) preamble with session count
printf '%s' "$human" | grep -q 'Recommendation based on 47 sessions over' \
  && _pass "(a) preamble contains 'Recommendation based on 47 sessions over'" \
  || _fail "(a) preamble missing; got: $human"

# (b) cost-winner method name
printf '%s' "$human" | grep -qi 'compact' \
  && _pass "(b) cost-winner 'compact' present" \
  || _fail "(b) cost-winner 'compact' missing; got: $human"

# (c) time-winner method name
printf '%s' "$human" | grep -qi 'clear-only' \
  && _pass "(c) time-winner 'clear-only' present" \
  || _fail "(c) time-winner 'clear-only' missing; got: $human"

# (d) outcome-winner method name
printf '%s' "$human" | grep -qi 'compact' \
  && _pass "(d) outcome-winner method present" \
  || _fail "(d) outcome-winner method missing; got: $human"

# (e) BATON_PCT_THRESHOLD followed by 34
printf '%s' "$human" | grep -q 'BATON_PCT_THRESHOLD' \
  && printf '%s' "$human" | grep -q '34' \
  && _pass "(e) BATON_PCT_THRESHOLD and 34 present" \
  || _fail "(e) BATON_PCT_THRESHOLD/34 missing; got: $human"

# (f) crossing's model-id
printf '%s' "$human" | grep -q 'claude-sonnet-4-6' \
  && _pass "(f) crossing model-id 'claude-sonnet-4-6' present" \
  || _fail "(f) crossing model-id missing; got: $human"

# (g) NO crossing caveat line when data_age_crossing=false (AGG2)
human2=$(printf '%s' "$AGG2" | recommend::format human)
printf '%s' "$human2" | grep -q 'Caveat: telemetry window crosses' \
  && _fail "(g) crossing caveat present when data_age_crossing=false" \
  || _pass "(g) crossing caveat absent when data_age_crossing=false"

# (h) 'N more days needed' literal with N = 30 - post_e16_days (AGG2: 30-13=17)
printf '%s' "$human2" | grep -q '17 more days needed' \
  && _pass "(h) '17 more days needed' present in AGG2" \
  || _fail "(h) 'N more days needed' literal missing; got: $human2"

# (i) outcome-winner section absent/null when insufficient (AGG2)
printf '%s' "$human2" | grep -qi 'outcome.*compact' \
  && _fail "(i) outcome winner 'compact' present when insufficient (should be absent)" \
  || _pass "(i) outcome winner absent when outcome_data_insufficient"

# (j) 'no significant difference' when no_significant_difference=true (AGG3)
human3=$(printf '%s' "$AGG3" | recommend::format human)
printf '%s' "$human3" | grep -qi 'no significant difference' \
  && _pass "(j) 'no significant difference' present in AGG3" \
  || _fail "(j) 'no significant difference' missing; got: $human3"

# ── JSON mode ──────────────────────────────────────────────────────────────
json_out=$(printf '%s' "$AGG" | recommend::format json)

# (k) valid JSON
printf '%s' "$json_out" | jq '.' >/dev/null 2>&1 \
  && _pass "(k) json mode emits valid JSON" \
  || _fail "(k) json mode not valid JSON; got: $json_out"

# (l) carries required top-level keys
printf '%s' "$json_out" | jq -e '.winners' >/dev/null 2>&1 \
  && _pass "(l) json carries .winners" \
  || _fail "(l) json missing .winners"
printf '%s' "$json_out" | jq -e '.threshold_sweep' >/dev/null 2>&1 \
  && _pass "(l) json carries .threshold_sweep" \
  || _fail "(l) json missing .threshold_sweep"
printf '%s' "$json_out" | jq -e '.paired_deltas' >/dev/null 2>&1 \
  && _pass "(l) json carries .paired_deltas" \
  || _fail "(l) json missing .paired_deltas"
printf '%s' "$json_out" | jq -e '.per_method' >/dev/null 2>&1 \
  && _pass "(l) json carries .per_method" \
  || _fail "(l) json missing .per_method"

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
