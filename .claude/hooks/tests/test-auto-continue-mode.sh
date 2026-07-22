#!/usr/bin/env bash
# E6-T1: BATON_AUTO_CONTINUE_MODE (off|tmux|relaunch) is the single selector for the
# two mutually-exclusive auto-continue drivers. Covers the full resolved-value table
# from the design's Decision 5: env > config.json > legacy BATON_AUTO_CONTINUE=1
# ("tmux") > compiled default ("off"), plus fail-safe on an unrecognized value, the
# dashboard round-trip, and dashboard-vs-gate agreement (lib/config.sh:6-10).
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# Source ONCE in THIS shell (test-config-lib.sh:4 idiom) so `_mode` resolves against
# the resolver under test. NOT `bash -c 'source lib/config.sh; ...'`: config.sh assigns
# BATON_DEFAULT_* with a plain `=`, so a re-sourcing child would clobber an env override
# and default-constant-is-load-bearing would fail as a harness bug, not a resolver bug.
# shellcheck source=../../../lib/config.sh
source "$REPO/lib/config.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Sandbox the config layer (test-config-lib.sh:5-8) BEFORE any write, or _cfg::set
# below clobbers the runner's real ~/.config/baton/config.json.
export XDG_CONFIG_HOME="$TMP/config"
mkdir -p "$XDG_CONFIG_HOME/baton"

PASS=0; FAIL=0; FAILED_CASES=()
assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS+1)); echo "  PASS  $name"
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"
  fi
}

_mode() { _cfg::auto_continue_mode; }
_cfg_write() { _cfg::set "$1" "$2"; }
# _cfg_write persists to the sandbox config.json and nothing here removes it. Every
# case below that expects a DEFAULT must clear the layer first or it inherits the
# previous case's write and fails against a correct resolver. Precedent:
# test-config-lib.sh:13-14 and :82.
_cfg_clear() { rm -f "$XDG_CONFIG_HOME/baton/config.json"; unset BATON_AUTO_CONTINUE_MODE; }

# --- env layer + legacy back-compat ---
_cfg_clear
assert "legacy-1-means-tmux"  "[ "$(BATON_AUTO_CONTINUE=1 _mode)" = tmux ]"
assert "legacy-unset-means-off" "[ "$(_mode)" = off ]"
assert "legacy-0-means-off"   "[ "$(BATON_AUTO_CONTINUE=0 _mode)" = off ]"
assert "mode-relaunch-wins"   "[ "$(BATON_AUTO_CONTINUE=1 BATON_AUTO_CONTINUE_MODE=relaunch _mode)" = relaunch ]"
assert "mode-off-kills"       "[ "$(BATON_AUTO_CONTINUE=1 BATON_AUTO_CONTINUE_MODE=off _mode)" = off ]"
# garbage is not a mode - fail SAFE (off), never fire a driver on a typo
assert "garbage-is-off"       "[ "$(BATON_AUTO_CONTINUE_MODE=bogus _mode)" = off ]"
# the compiled default is the ONLY source of the default answer: change it, the gate moves
assert "default-constant-is-load-bearing" "[ "$(BATON_DEFAULT_AUTO_CONTINUE_MODE=tmux _mode)" = tmux ]"

# --- config.json layer (sandboxed XDG_CONFIG_HOME) ---
# _cfg::get has three layers and the asserts above exercise only env: a resolver that
# silently ignored config.json would keep them all green while the dashboard did nothing.
_cfg_clear
_cfg_write auto_continue_mode relaunch
assert "config-layer-wins-over-default" "[ "$(_mode)" = relaunch ]"
# PRECEDENCE (design Decision 5, resolved-value table): the legacy boolean is only
# consulted when MODE resolves EMPTY. A persisted mode is not empty, so config WINS.
assert "config-beats-legacy-flag" "[ "$(BATON_AUTO_CONTINUE=1 _mode)" = relaunch ]"
assert "env-beats-config" "[ "$(BATON_AUTO_CONTINUE_MODE=tmux _mode)" = tmux ]"
_cfg_write auto_continue_mode bogus
assert "config-garbage-is-off" "[ "$(_mode)" = off ]"

# --- dashboard round-trip ---
assert "set_one-rejects-garbage" "! bash '$REPO/tools/baton-dashboard.sh' set auto_continue_mode=bogus >/dev/null 2>&1"
# $(_mode) is single-quoted so `eval` resolves it AFTER the write, not while the assert
# argument is being built (which would read the previous case's persisted `bogus`).
assert "set_one-roundtrip" "bash '$REPO/tools/baton-dashboard.sh' set auto_continue_mode=relaunch >/dev/null && [ \"\$(_mode)\" = relaunch ]"
# `set --help` lists keys from a HARDCODED string, so a new key stays invisible there
# until added by hand. Nothing else in this suite would notice the omission.
# Captured, not piped: `set --help` takes the unknown-key path and exits 1 by design,
# and under `set -o pipefail` that rc would sink the pipeline even on a grep match.
_help_out=$(bash "$REPO/tools/baton-dashboard.sh" set --help 2>&1 || true)
assert "help-lists-mode" "echo '$_help_out' | grep -q auto_continue_mode"

# --- dashboard-vs-gate agreement (lib/config.sh:6-10: these can never disagree) ---
# With ONLY the legacy flag set the gate says tmux, so the dashboard must too.
# _cfg_clear is LOAD-BEARING: the round-trip above persisted `relaunch`, and config
# BEATS the legacy flag (config-beats-legacy-flag pins that deliberately). Without it
# this reads `relaunch` and sends you to "fix" a correct resolver by making the legacy
# boolean override config.json - a direct violation of Decision 5.
_cfg_clear
_dash_out=$(BATON_AUTO_CONTINUE=1 bash "$REPO/tools/baton-dashboard.sh" | grep auto_continue_mode)
assert "dashboard-agrees-with-gate-on-legacy" "echo '$_dash_out' | grep -q tmux"

# --- inline fallback in checkpoint-write-trigger.sh (lib unreachable) ---
# Duplicated precedence with no test is a drift generator: the fallback must produce
# the SAME answers as the real resolver. Extract the guard block and source it from a
# dir where ../../lib/config.sh does not exist, in a child with every _cfg:: function
# unset (lib/config.sh export -f's them, so a plain child would inherit the real ones).
sed -n '/BEGIN cfg-guard/,/END cfg-guard/p' "$REPO/.claude/hooks/checkpoint-write-trigger.sh" > "$TMP/guard.sh"
_mode_with_lib_hidden() {
  (
    unset -f _cfg::auto_continue_mode _cfg::get _cfg::path _cfg::source 2>/dev/null || true
    unset BATON_DEFAULT_AUTO_CONTINUE_MODE
    env "$@" bash -c 'set -u; source "$1/guard.sh"; _cfg::auto_continue_mode' _ "$TMP"
  )
}
_cfg_clear
assert "fallback-guard-block-extracted" "[ -s '$TMP/guard.sh' ]"
assert "fallback-legacy-1-tmux" "[ "$(_mode_with_lib_hidden BATON_AUTO_CONTINUE=1)" = tmux ]"
assert "fallback-legacy-unset-off" "[ "$(_mode_with_lib_hidden BATON_AUTO_CONTINUE=0)" = off ]"
assert "fallback-garbage-off"   "[ "$(_mode_with_lib_hidden BATON_AUTO_CONTINUE_MODE=bogus)" = off ]"
assert "fallback-mode-relaunch" "[ "$(_mode_with_lib_hidden BATON_AUTO_CONTINUE=1 BATON_AUTO_CONTINUE_MODE=relaunch)" = relaunch ]"
_cfg_write auto_continue_mode relaunch
assert "fallback-reads-config-layer" "[ "$(_mode_with_lib_hidden BATON_AUTO_CONTINUE=1)" = relaunch ]"
_cfg_clear

# --- trigger spawn gate: mutual exclusion (adapted from test-auto-continue-spawn.sh) ---
HOOKS_DIR="$REPO/.claude/hooks"
cat > "$TMP/inj.sh" <<'INJ'
#!/bin/bash
echo "$@" >> "$SPAWN_LOG"
INJ
chmod +x "$TMP/inj.sh"

_th() { printf '%s:%s' "${USER:-x}" "test-term-$$" | md5sum | cut -d' ' -f1; }

_stage() { # $1=state_dir $2=sid $3=pane
  local trk="$1/.baton"; mkdir -p "$trk/terminals" "$trk/workstreams" "$trk/progress"
  local th; th=$(_th); local prog="$trk/progress/progress-testws-abc.md"; echo stub > "$prog"
  jq -n --arg t "test-term-$$" --arg w testws --arg p "$3" --arg ts 2026-01-01T00:00:00Z \
    '{terminal_id:$t, workstream:$w, tmux_pane:$p, updated_at:$ts}' > "$trk/terminals/${th}.json"
  jq -n --arg w testws --arg p "$prog" --arg pd "$1" --arg ts 2026-01-01T00:00:00Z \
    '{workstream:$w, display_name:$w, progress_file:$p, phase:"unknown", updated_at:$ts, project_dir:$pd}' > "$trk/workstreams/testws.json"
  touch "/tmp/baton-pending-$2"; echo "/tmp/x-$2" > "/tmp/claude-session-tracking-$2"
}

_drive() { # $1=sid $2=state_dir $3=extra_exports $4=spawnlog
  _stage "$2" "$1" '%3'
  local stdin; stdin=$(jq -cn --arg s "$1" --arg c "$2" --arg f "$2/.baton/progress/progress-testws-abc.md" \
    '{session_id:$s, cwd:$c, tool_name:"Write", tool_input:{file_path:$f}}')
  (
    export XDG_STATE_HOME="$2/state" BATON_EVENT_LOG="$2/hook-events.jsonl"
    export BATON_DIR="$2/.baton" BATON_PROGRESS_DIR="$2/.baton/progress"
    export BATON_ARCHIVE_DIR="$2/archive" CLAUDE_PROJECT_DIR="$2"
    export CLAUDE_TERMINAL_ID="test-term-$$" BATON_COLLECT=1
    unset AGENT_SESSION_ID BATON_EVENT_LOG_DISABLE
    export TMUX='/tmp/fake,1,0' SPAWN_LOG="$4" BATON_AUTO_CONTINUE_BIN="$TMP/inj.sh"
    eval "$3"
    mkdir -p "$2/share/templates" && : > "$2/share/templates/free.md"
    printf '%s' "$stdin" | "$HOOKS_DIR/checkpoint-write-trigger.sh" >/dev/null 2>&1
  )
  rm -f "/tmp/baton-pending-$1" "/tmp/baton-done-$1" "/tmp/claude-session-tracking-$1"
}

SPAWN_LEGACY="$TMP/spawn.legacy"; SPAWN_RELAUNCH="$TMP/spawn.relaunch"
: > "$SPAWN_LEGACY"; : > "$SPAWN_RELAUNCH"
_drive m-legacy   "$(mktemp -d)" "export BATON_AUTO_CONTINUE=1; unset BATON_AUTO_CONTINUE_MODE" "$SPAWN_LEGACY"
_drive m-relaunch "$(mktemp -d)" "export BATON_AUTO_CONTINUE=1 BATON_AUTO_CONTINUE_MODE=relaunch" "$SPAWN_RELAUNCH"

# The spawn is detached, so poll for the positive case before asserting (else it flakes).
for _i in $(seq 1 50); do [ -s "$SPAWN_LEGACY" ] && break; sleep 0.1; done
assert "trigger-spawns-on-legacy-back-compat" "grep -qE '%[0-9]+' '$SPAWN_LEGACY'"
# Negative case: nothing to poll FOR, so a short fixed settle wait before asserting empty.
sleep 1
assert "trigger-no-spawn-when-mode-relaunch" "[ ! -s '$SPAWN_RELAUNCH' ]"

# --- config-only BATON_AUTO_CONTINUE_BIN (no env): exercise the _cfg::get migration ---
# An env-set BIN wins with or without the migration; only a config.json-set BIN that is
# actually spawned proves checkpoint-write-trigger.sh resolves _AC_BIN through _cfg::get.
_cfg_clear
cat > "$TMP/inj-cfg.sh" <<'INJ'
#!/bin/bash
echo "$@" >> "$SPAWN_LOG"
INJ
chmod +x "$TMP/inj-cfg.sh"
_cfg::set BATON_AUTO_CONTINUE_BIN "$TMP/inj-cfg.sh"
SPAWN_CFG="$TMP/spawn.cfg"; : > "$SPAWN_CFG"
CFGDIR=$(mktemp -d); _stage "$CFGDIR" c-cfg '%3'
CFGIN=$(jq -cn --arg s c-cfg --arg c "$CFGDIR" --arg f "$CFGDIR/.baton/progress/progress-testws-abc.md" '{session_id:$s, cwd:$c, tool_name:"Write", tool_input:{file_path:$f}}')
(
  export XDG_STATE_HOME="$CFGDIR/state" BATON_EVENT_LOG="$CFGDIR/hook-events.jsonl"
  export BATON_DIR="$CFGDIR/.baton" BATON_PROGRESS_DIR="$CFGDIR/.baton/progress"
  export BATON_ARCHIVE_DIR="$CFGDIR/archive" CLAUDE_PROJECT_DIR="$CFGDIR"
  export CLAUDE_TERMINAL_ID="test-term-$$" BATON_COLLECT=1
  unset AGENT_SESSION_ID BATON_EVENT_LOG_DISABLE BATON_AUTO_CONTINUE_BIN BATON_AUTO_CONTINUE_MODE
  export TMUX='/tmp/fake,1,0' SPAWN_LOG="$SPAWN_CFG" BATON_AUTO_CONTINUE=1
  mkdir -p "$CFGDIR/share/templates" && : > "$CFGDIR/share/templates/free.md"
  printf '%s' "$CFGIN" | "$HOOKS_DIR/checkpoint-write-trigger.sh" >/dev/null 2>&1
)
rm -f "/tmp/baton-pending-c-cfg" "/tmp/baton-done-c-cfg" "/tmp/claude-session-tracking-c-cfg"
for _i in $(seq 1 50); do [ -s "$SPAWN_CFG" ] && break; sleep 0.1; done
assert "config-only-BIN-spawns-config-set-injector" "grep -qE '%[0-9]+' '$SPAWN_CFG'"
_cfg_clear

echo "$PASS passed, $FAIL failed"
[ "${#FAILED_CASES[@]}" -eq 0 ] || printf 'failed: %s\n' "${FAILED_CASES[*]}" >&2
[ "$FAIL" -eq 0 ]
