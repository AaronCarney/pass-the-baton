#!/bin/bash
# E-B: prove the checkpoint GATE reads the configured threshold (config.json +
# env BATON_PCT_THRESHOLD), and that the PreToolUse telemetry `threshold` field
# equals the gate value. Drives context-checkpoint.sh end-to-end.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/context-checkpoint.sh"
FAIL=0

_run() { # _run <session_id> <pct> -> echoes hook stdout
  local sid="$1" pct="$2"
  echo "$pct" > "/tmp/claude-context-pct-$sid"
  rm -f "/tmp/claude-context-triggered-$sid" "/tmp/baton-done-$sid"
  local input; input=$(jq -n --arg s "$sid" --arg c "$CWD" '{session_id:$s, cwd:$c, tool_name:"Edit"}')
  printf '%s' "$input" | bash "$HOOK" 2>/dev/null
}
_clean() { rm -f /tmp/claude-context-pct-"$1" /tmp/claude-context-triggered-"$1" /tmp/baton-pending-"$1" /tmp/baton-done-"$1"; }

# ---- A) config.json threshold_pct = 40 ----
CWD=$(mktemp -d); mkdir -p "$CWD/share/templates" "$CWD/.config/baton"
echo '# stub free' > "$CWD/share/templates/free.md"
echo '{"template":"free","threshold_pct":"40"}' > "$CWD/.config/baton/config.json"
export CLAUDE_PROJECT_DIR="$CWD" XDG_CONFIG_HOME="$CWD/.config"
unset BATON_PCT_THRESHOLD
if _run cfgA-lo 39 | grep -q 'CHECKPOINT TRIGGERED'; then echo "FAIL A1: pct 39 < cfg 40 must NOT trigger"; FAIL=1; fi
_clean cfgA-lo
if _run cfgA-hi 40 | grep -q 'CHECKPOINT TRIGGERED'; then :; else echo "FAIL A2: pct 40 == cfg 40 must trigger"; FAIL=1; fi
_clean cfgA-hi
unset CLAUDE_PROJECT_DIR XDG_CONFIG_HOME
rm -rf "$CWD"

# ---- B) env BATON_PCT_THRESHOLD = 50 beats config (config says 40) ----
CWD=$(mktemp -d); mkdir -p "$CWD/share/templates" "$CWD/.config/baton"
echo '# stub free' > "$CWD/share/templates/free.md"
echo '{"template":"free","threshold_pct":"40"}' > "$CWD/.config/baton/config.json"
export CLAUDE_PROJECT_DIR="$CWD" XDG_CONFIG_HOME="$CWD/.config" BATON_PCT_THRESHOLD=50
if _run envB-lo 49 | grep -q 'CHECKPOINT TRIGGERED'; then echo "FAIL B1: pct 49 < env 50 must NOT trigger"; FAIL=1; fi
_clean envB-lo
if _run envB-hi 50 | grep -q 'CHECKPOINT TRIGGERED'; then :; else echo "FAIL B2: pct 50 == env 50 must trigger"; FAIL=1; fi
_clean envB-hi
unset CLAUDE_PROJECT_DIR XDG_CONFIG_HOME BATON_PCT_THRESHOLD
rm -rf "$CWD"

# ---- C) telemetry threshold field == gate value (config 40) ----
CWD=$(mktemp -d); mkdir -p "$CWD/share/templates" "$CWD/.config/baton"
echo '# stub free' > "$CWD/share/templates/free.md"
echo '{"template":"free","threshold_pct":"40"}' > "$CWD/.config/baton/config.json"
export CLAUDE_PROJECT_DIR="$CWD" XDG_CONFIG_HOME="$CWD/.config" XDG_STATE_HOME="$CWD/state" BATON_COLLECT=1
unset BATON_PCT_THRESHOLD
_run telC 39 >/dev/null   # below gate, but EXIT-trap still emits PreToolUse with threshold
LOG="$CWD/state/baton/hook-events.jsonl"
thr=$(grep -h '"event":"PreToolUse"' "$LOG" 2>/dev/null | tail -1 | jq -r '.data.threshold')
if [ "$thr" = "40" ]; then :; else echo "FAIL C: telemetry threshold ($thr) != gate value 40"; FAIL=1; fi
_clean telC
unset CLAUDE_PROJECT_DIR XDG_CONFIG_HOME XDG_STATE_HOME BATON_COLLECT
rm -rf "$CWD"

# ---- D) subagent gate (line 60) honors configured threshold (config 40) ----
CWD=$(mktemp -d); mkdir -p "$CWD/share/templates" "$CWD/.config/baton"
echo '# stub free' > "$CWD/share/templates/free.md"
echo '{"template":"free","threshold_pct":"40"}' > "$CWD/.config/baton/config.json"
export CLAUDE_PROJECT_DIR="$CWD" XDG_CONFIG_HOME="$CWD/.config" CLAUDE_TERMINAL_ID=eb-subagent-test
unset BATON_PCT_THRESHOLD
TH=$(printf '%s' "${USER}:eb-subagent-test" | md5sum | cut -d' ' -f1)
PSID=eb-parent-sid
echo "$PSID" > "/tmp/claude-parent-sid-${TH}"
rm -f "/tmp/baton-done-${PSID}"
_sub() { # _sub <agent_session_id> <parent_pct> -> hook stdout
  local asid="$1" ppct="$2"
  echo "$ppct" > "/tmp/claude-context-pct-${PSID}"
  rm -f "/tmp/claude-subagent-checkpoint-${asid}"
  local input; input=$(jq -n --arg s "$asid" --arg c "$CWD" '{session_id:$s, cwd:$c, tool_name:"Edit", agent_id:"sub-agent"}')
  printf '%s' "$input" | bash "$HOOK" 2>/dev/null
}
if _sub subD-lo 39 | grep -q 'Parent context'; then echo "FAIL D1: subagent parent pct 39 < cfg 40 must NOT warn"; FAIL=1; fi
if _sub subD-hi 40 | grep -q 'Parent context'; then :; else echo "FAIL D2: subagent parent pct 40 == cfg 40 must warn"; FAIL=1; fi
rm -f "/tmp/claude-parent-sid-${TH}" "/tmp/claude-context-pct-${PSID}" /tmp/claude-subagent-checkpoint-subD-*
unset CLAUDE_PROJECT_DIR XDG_CONFIG_HOME CLAUDE_TERMINAL_ID
rm -rf "$CWD"

if [ "$FAIL" = 0 ]; then echo "PASS test-threshold-knob-gate.sh"; else exit 1; fi
