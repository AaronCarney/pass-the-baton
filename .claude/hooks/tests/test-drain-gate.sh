#!/usr/bin/env bash
# Unit tests for lib/drain-gate.sh: marker lifecycle, count, timeout default, race.
set -u
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
LIB="$REPO/.claude/hooks/lib/drain-gate.sh"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

# Hardening (not a reproduced failure): the executor session can carry BATON_*
# overrides in its environment. drain-gate.sh sets BATON_DRAIN_TIMEOUT_SECS via
# := at source time, so an inherited override would silently pass the default
# assertions below against the wrong value. Clear it before sourcing.
unset BATON_DRAIN_TIMEOUT_SECS BATON_SNOOZE_MAX_MIN

# shellcheck source=/dev/null
source "$LIB"

SID="unit-drainlib-$$"
DIR="/tmp/baton-subagents-active-${SID}"
rm -rf "$DIR"

ok "default timeout is 360" "[ \"\${BATON_DRAIN_TIMEOUT_SECS}\" = 360 ]"
ok "clear when no dir" "drain::is_clear '$SID'"
ok "count is 0 when no dir" "[ \"\$(drain::count '$SID')\" = 0 ]"

drain::mark_start "$SID" agentA
ok "mark_start creates marker" "[ -f '$DIR/agentA' ]"
ok "count is 1" "[ \"\$(drain::count '$SID')\" = 1 ]"
ok "not clear with one active" "! drain::is_clear '$SID'"

drain::mark_start "$SID" agentB
ok "count is 2" "[ \"\$(drain::count '$SID')\" = 2 ]"

drain::mark_stop "$SID" agentA
ok "count back to 1" "[ \"\$(drain::count '$SID')\" = 1 ]"
drain::mark_stop "$SID" agentB
ok "clear after last stop" "drain::is_clear '$SID'"

# Bad ids are rejected, never written
ok "mark_start rejects bad agent id" "! drain::mark_start '$SID' 'bad;id'"
ok "mark_start rejects bad parent id" "! drain::mark_start 'bad;sid' agentC"

# Race: a mark_start whose dir is rmdir'd mid-call must still succeed.
rm -rf "$DIR"
drain::mark_start "$SID" agentR
rmdir "$DIR" 2>/dev/null
rm -f "$DIR/agentR" 2>/dev/null
rm -rf "$DIR"
ok "mark_start succeeds on a freshly reaped dir" "drain::mark_start '$SID' agentS && [ -f '$DIR/agentS' ]"

# The rmdir/create race, closed at the exact seam. The assertion above does NOT
# reach it: mkdir -p recreates the directory and the first create succeeds, so
# the retry branch never runs and it passes pre-fix. A one-shot `mkdir` shell
# function shadows the builtin inside drain::mark_start and reaps the directory
# the instant it is created, which is precisely the window a concurrent
# mark_stop hits. Interleaving two real processes does NOT reproduce it
# reliably, so it cannot serve as red-to-green evidence; this seam is
# deterministic. drain::mark_start is called with 2>/dev/null wrapping the WHOLE
# call because `: > "$dir/$aid" 2>/dev/null` applies redirections left to right,
# so the failing create writes to the still-open stderr and would otherwise
# print noise on the red run.
rm -rf "$DIR"
seam_mark_start(){
  mkdir(){ unset -f mkdir; command mkdir "$@"; local rc=$?; rm -rf "$DIR" 2>/dev/null; return $rc; }
  drain::mark_start "$SID" agentSeam 2>/dev/null
}
ok "mark_start survives the dir being reaped between mkdir and create" \
  "seam_mark_start && [ -f '$DIR/agentSeam' ]"
rm -rf "$DIR"

# hung() honours the configured timeout
rm -rf "$DIR"; drain::mark_start "$SID" agentT
touch -d '10 minutes ago' "$DIR/agentT"
ok "hung fires past default timeout" "drain::hung '$SID'"
ok "hung does not fire under a raised timeout" "BATON_DRAIN_TIMEOUT_SECS=100000 drain::hung '$SID'; [ \$? -ne 0 ]"

# The interval the raised default exists to protect. Nothing else covers it:
# the assertion at the top only READS the variable, the 10-minute fixture above
# trips under 180 and under 360 alike, and 100000 clears everything. A marker
# aged 240 seconds fails under the old default and passes under the new one, so
# this is the only assertion that tells the two apart.
rm -rf "$DIR"; drain::mark_start "$SID" agentQ
touch -d '240 seconds ago' "$DIR/agentQ"
ok "healthy subagent aged 240 seconds is not hung under the default" "! drain::hung '$SID'"

rm -rf "$DIR"
echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
