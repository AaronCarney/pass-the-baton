#!/usr/bin/env bash
# Single source of truth for the OS-cron cleanup cadence. Sourced by
# install-cron.sh (writes the paste snippet) and uninstall.sh (prints the
# matching removal snippet) so the two can never drift. Idempotent (:=) so
# re-sourcing in one process is safe. This is the FIXED OS-cron cadence and is
# independent of BATON_SWEEP_INTERVAL_HOURS (the in-process self-throttle).
: "${BATON_CRON_SCHEDULE:=0 0 */2 * *}"
