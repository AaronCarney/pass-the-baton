#!/usr/bin/env bash
# Single source of truth for the threshold-sweep grid consumed by
# cost-compare.sh and cost-sweep-corpus.sh. Idempotent (:=) for re-source safety.
: "${BATON_SWEEP_THRESHOLDS:=10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 50 never}"
