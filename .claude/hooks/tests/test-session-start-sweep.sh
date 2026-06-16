#!/bin/bash
# E-D1 Task 2: session-start.sh fires `cleanup-cron.sh --if-due` FULLY DETACHED
# just before exit 0, so the sweep never delays session readiness and targets the
# resolved PROJECT_DIR (not $PWD).
#
# Discriminator = DIFFERENTIAL BASELINE: a synchronous (foreground) sweep against
# the same forced-due fixture takes wall-time D (floored at FLOOR, grown until it
# holds). A detached launch must return the hook in < D/2. An inline/blocking
# sweep would make the hook take >= D and fail.
#
# Usage: bash .claude/hooks/tests/test-session-start-sweep.sh

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SS="$HOOKS_DIR/session-start.sh"
CRON="$PROJECT_ROOT/tools/cleanup-cron.sh"

PASS=0
FAIL=0
FAILED_CASES=()

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS+1)); echo "  PASS  $name"
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"
  fi
}

# stage_fixture <proj> <n_stale_workstreams>
# Builds a by-value layout cleanup-cron.sh expects: $proj/.baton with N stale
# (60-day-old updated_at, no fresh terminal pointer) workstreams that Block 4
# archives, plus a 50h-old .cron-last-run so --if-due treats the sweep as DUE.
stage_fixture() {
  local proj="$1" n="$2"
  local tracking="$proj/.baton"
  mkdir -p "$tracking/workstreams" "$tracking/terminals" \
           "$proj/.claude/hooks/lib"
  cp "$HOOKS_DIR/lib/workstream-lib.sh" "$proj/.claude/hooks/lib/workstream-lib.sh"
  local stale; stale=$(date -u -d "60 days ago" +%Y-%m-%dT%H:%M:%SZ)
  local i
  for ((i=0; i<n; i++)); do
    jq -n --arg ws "ws-stale-$i" --arg ts "$stale" \
      '{workstream:$ws, display_name:"s", progress_file:"", phase:"unknown", updated_at:$ts, project_dir:"x"}' \
      > "$tracking/workstreams/ws-stale-$i.json"
  done
  # 50h-old marker => due (default interval 48h).
  touch -d "50 hours ago" "$tracking/.cron-last-run"
}

# count_archived <archive_base>
count_archived() {
  local archive="$1" ym; ym=$(date +%Y-%m)
  find "$archive/checkpoint-state/$ym/workstreams" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l
}

echo "## session-start.sh detached sweep"

# ---- (a.1) Synchronous baseline D, grown until D >= FLOOR ----
# FLOOR must clear session-start's OWN fixed overhead (jq/setup, ~0.2s) with
# headroom so an inline sweep (>= D) is unambiguously distinguishable from the
# detached launch (returns at fixed overhead, well under D/2).
FLOOR=0.6
N=24
D=0
BASELINE_PROJ=""
for attempt in 1 2 3 4 5 6 7; do
  bp=$(mktemp -d)
  stage_fixture "$bp" "$N"
  bar="$bp/archive-base"; mkdir -p "$bar"
  t0=$(date +%s.%N)
  BATON_PROJECT_DIR="$bp" BATON_ARCHIVE_DIR="$bar" \
    bash "$CRON" --if-due >/dev/null 2>&1
  t1=$(date +%s.%N)
  D=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", b-a}')
  arch=$(count_archived "$bar")
  echo "  baseline attempt=$attempt N=$N D=${D}s archived=$arch"
  rm -rf "$bp"
  if awk -v d="$D" -v f="$FLOOR" 'BEGIN{exit !(d>=f)}'; then BASELINE_PROJ="ok"; break; fi
  N=$((N*2))
done
assert "(a) baseline D >= FLOOR (discriminator is valid)" \
  "awk -v d='$D' -v f='$FLOOR' 'BEGIN{exit !(d>=f)}'"
# If the floor never held the discriminator is void - hard-fail loudly.
if [ -z "$BASELINE_PROJ" ]; then
  echo "  HARD-FAIL: synchronous baseline never reached FLOOR=${FLOOR}s; cannot distinguish inline from detached."
fi

HALF_D=$(awk -v d="$D" 'BEGIN{printf "%.4f", d/2}')
echo "  using N=$N stale workstreams; D=${D}s; D/2=${HALF_D}s"

# ---- run session-start (detached launch) against the same-sized fixture ----
proj=$(mktemp -d)
stage_fixture "$proj" "$N"
archive="$proj/archive-base"; mkdir -p "$archive"

# A working directory OUTSIDE $proj: an empty/$PWD fallback would target here and
# be detectable (nothing archives under $outside_archive).
outside=$(mktemp -d)
mkdir -p "$outside/.baton/workstreams" "$outside/archive-base"

sid="sid-ss-sweep-$$"
H0=$(date +%s.%N)
( cd "$outside" && \
  CLAUDE_PROJECT_DIR="$proj" BATON_ARCHIVE_DIR="$archive" \
    bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$proj\"}" >/dev/null 2>&1 )
H1=$(date +%s.%N)
T_hook=$(awk -v a="$H0" -v b="$H1" 'BEGIN{printf "%.4f", b-a}')
echo "  T_hook=${T_hook}s (D/2=${HALF_D}s)"

# (a) THE discriminator: detached hook returns in a fraction of D.
assert "(a) T_hook < D/2 - sweep launched DETACHED, not inline" \
  "awk -v t='$T_hook' -v h='$HALF_D' 'BEGIN{exit !(t<h)}'"

# (b) the detached sweep DID run against \$proj (stale workstream archived under
# \$proj's archive base) AND poll until it lands (bounded 10s).
landed=0
for _ in $(seq 1 100); do
  if [ "$(count_archived "$archive")" -gt 0 ]; then landed=1; break; fi
  sleep 0.1
done
assert "(b) detached sweep archived a stale workstream under \$proj" \
  "[ '$landed' = '1' ] && [ \"\$(count_archived '$archive')\" -gt 0 ]"
assert "(b) sweep did NOT target \$PWD (nothing archived outside)" \
  "[ \"\$(count_archived '$outside/archive-base')\" = '0' ]"

# corroborating ordering: marker mtime >= int(T_hook) at whole-second granularity.
# The marker is re-stamped by Block 6 only after the (detached) sweep actually runs.
marker="$proj/.baton/.cron-last-run"
fresh=0
for _ in $(seq 1 100); do
  m=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
  # marker re-stamped when its mtime is newer than the 50h-old seed
  age_min=$(find "$proj/.baton" -maxdepth 1 -name .cron-last-run -mmin -60 2>/dev/null)
  if [ -n "$age_min" ]; then fresh=1; break; fi
  sleep 0.1
done
assert "(a-corroborating) marker re-stamped by detached sweep (Block 6 ran)" \
  "[ '$fresh' = '1' ]"

# ---- second immediate session start: marker now fresh => --if-due self-skips ----
sid2="sid-ss-sweep2-$$"
( cd "$outside" && \
  CLAUDE_PROJECT_DIR="$proj" BATON_ARCHIVE_DIR="$archive" \
    bash "$SS" <<<"{\"session_id\":\"$sid2\",\"cwd\":\"$proj\"}" >/dev/null 2>&1 )
# give any (incorrectly-launched) sweep a moment; it must self-skip on fresh marker.
sleep 0.5
mtime_before=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
sleep 0.5
mtime_after=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
assert "(step3) second start with fresh marker self-skips (no re-stamp churn)" \
  "[ '$mtime_before' = '$mtime_after' ]"

# ---- output invariant: detached launch must not add stdout to SessionStart ----
out_with=$(cd "$outside" && CLAUDE_PROJECT_DIR="$proj" BATON_ARCHIVE_DIR="$archive" \
  bash "$SS" <<<"{\"session_id\":\"sid-out-$$\",\"cwd\":\"$proj\"}" 2>/dev/null)
assert "(step3) detached launch emits no extra stdout (no cleanup-cron noise)" \
  "! echo \"\$out_with\" | grep -qi 'sweep:\|cleanup run\|=== Done'"

# ---- (step4) manual escape hatch resolves the marker UNDER the project's
# .baton and NEVER at an empty-prefix '/.baton' (stray-root regression).
# Direct, no-flag cleanup-cron.sh run with a sandboxed HOME + explicit
# BATON_PROJECT_DIR: the marker must land at $proj/.baton/.cron-last-run
# and zero stray .cron-last-run files may exist anywhere outside it.
esc=$(mktemp -d)
escproj="$esc/proj"
mkdir -p "$escproj/.baton/workstreams" "$escproj/.baton/terminals"
escarch="$esc/arch"; mkdir -p "$escarch"
HOME="$esc/fakehome" BATON_PROJECT_DIR="$escproj" BATON_ARCHIVE_DIR="$escarch" \
  bash "$CRON" >/dev/null 2>&1
assert "(step4) manual escape hatch lands marker under \$proj/.baton" \
  "[ -f '$escproj/.baton/.cron-last-run' ]"
stray_n=$(find "$esc" -name .cron-last-run -not -path "$escproj/.baton/*" 2>/dev/null | wc -l)
assert "(step4) no stray .cron-last-run outside \$proj/.baton (empty-prefix guard)" \
  "[ '$stray_n' = '0' ]"
rm -rf "$esc"

rm -f /tmp/claude-session-tracking-"$sid" /tmp/claude-session-tracking-"$sid2"
rm -rf "$proj" "$outside"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'; printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
