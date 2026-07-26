#!/usr/bin/env bash
# tool-policy classification tests.
set -u
HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
source "$HOOKS/lib/tool-policy.sh"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

for t in Read Grep Glob LS NotebookRead TodoWrite WebFetch WebSearch; do
  ok "$t is read-only" "toolpolicy::is_readonly $t"
  ok "$t classifies allow" "[ \"$(toolpolicy::classify $t)\" = allow ]"
done
for t in Write Edit MultiEdit Bash Task NotebookEdit; do
  ok "$t is not read-only" "! toolpolicy::is_readonly $t"
  ok "$t classifies gate" "[ \"$(toolpolicy::classify $t)\" = gate ]"
done
# announcement names both halves
A="$(toolpolicy::announce)"
ok "announce mentions read-only" "printf '%s' \"$A\" | grep -qi 'read-only'"
ok "announce mentions gated" "printf '%s' \"$A\" | grep -qi 'gated'"
# empty / unknown tool name defaults to gate (fail-closed)
ok "empty name gates" "[ \"$(toolpolicy::classify '')\" = gate ]"
ok "unknown name gates" "[ \"$(toolpolicy::classify Frobnicate)\" = gate ]"
echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
