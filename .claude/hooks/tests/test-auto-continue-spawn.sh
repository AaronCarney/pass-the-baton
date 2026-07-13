#!/bin/bash
# E6-T3: checkpoint-write-trigger spawns the opt-in tmux auto-continue injector.
# Tests the GATE decision (opt-in on + TMUX set + .tmux_pane present), not a real
# detached process. A shim injector records its argv so we assert the pane id from
# Task 1's terminal record reaches the spawn (the T1->T3 pane contract).
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
FAILED_CASES=()

# Lifted verbatim from test-hook-writers.sh:14,26,35.
assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS+1))
    echo "  PASS  $name"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name")
    echo "  FAIL  $name"
  fi
}

mkstate() {
  local d
  d=$(mktemp -d)
  echo "$d"
}

# Common runner: invoke a hook with given stdin, in an isolated state dir.
# Env exports done in subshell - caller passes extra exports as $4.
# Args: hook_basename, stdin_json, state_dir, extra_exports
run_hook() {
  local hook="$1" stdin_json="$2" state_dir="$3" extra_exports="${4:-}"
  local log="$state_dir/hook-events.jsonl"
  local rc_file="$state_dir/rc"
  (
    export XDG_STATE_HOME="$state_dir/state"
    export BATON_EVENT_LOG="$log"
    export BATON_DIR="$state_dir/.baton"
    export BATON_PROGRESS_DIR="$state_dir/.baton/progress"
    export BATON_ARCHIVE_DIR="$state_dir/archive"
    export CLAUDE_PROJECT_DIR="$state_dir"
    export CLAUDE_TERMINAL_ID="test-term-$$"
    export BATON_COLLECT=1
    unset AGENT_SESSION_ID
    unset BATON_EVENT_LOG_DISABLE
    [ -n "$extra_exports" ] && eval "$extra_exports"
    mkdir -p "$state_dir/.baton/progress" "$state_dir/.baton/workstreams" "$state_dir/.baton/terminals"
    # Stub template so the write-trigger's V1 lint compares empty-vs-empty.
    mkdir -p "$state_dir/share/templates" && : > "$state_dir/share/templates/free.md"
    printf '%s' "$stdin_json" | "$HOOKS_DIR/$hook" >"$state_dir/stdout" 2>"$state_dir/stderr"
    echo "$?" > "$rc_file"
  )
  cat "$rc_file"
}

TMP=$(mktemp -d)
# Injector shim: the trigger resolves it via BATON_AUTO_CONTINUE_BIN; it just
# records its argv so we can assert the pane id reached the spawn.
cat > "$TMP/inj.sh" <<'INJ'
#!/bin/bash
echo "$@" >> "$SPAWN_LOG"
INJ
chmod +x "$TMP/inj.sh"

# term-hash matches run_hook's CLAUDE_TERMINAL_ID=test-term-$$ (md5 of USER:term).
_th() { printf '%s:%s' "${USER:-x}" "test-term-$$" | md5sum | cut -d' ' -f1; }

# Seed a pending checkpoint + terminal record (pane arg '' -> omit .tmux_pane).
_stage() { # $1=state_dir $2=sid $3=pane
  local trk="$1/.baton"; mkdir -p "$trk/terminals" "$trk/workstreams" "$trk/progress"
  local th; th=$(_th); local prog="$trk/progress/progress-testws-abc.md"; echo stub > "$prog"
  if [ -n "$3" ]; then
    jq -n --arg t test-term-$$ --arg w testws --arg p "$3" --arg ts 2026-01-01T00:00:00Z \
      '{terminal_id:$t, workstream:$w, tmux_pane:$p, updated_at:$ts}' > "$trk/terminals/${th}.json"
  else
    jq -n --arg t test-term-$$ --arg w testws --arg ts 2026-01-01T00:00:00Z \
      '{terminal_id:$t, workstream:$w, updated_at:$ts}' > "$trk/terminals/${th}.json"
  fi
  jq -n --arg w testws --arg p "$prog" --arg pd "$1" --arg ts 2026-01-01T00:00:00Z \
    '{workstream:$w, display_name:$w, progress_file:$p, phase:"unknown", updated_at:$ts, project_dir:$pd}' > "$trk/workstreams/testws.json"
  touch "/tmp/baton-pending-$2"; echo "/tmp/x-$2" > "/tmp/claude-session-tracking-$2"
}

# Drive one trigger cycle. $4=opt-in $5=tmux-val $6=spawnlog
_drive() { # $1=sid $2=state_dir $3=pane $4=optin $5=tmux $6=spawnlog
  _stage "$2" "$1" "$3"
  local stdin; stdin=$(jq -cn --arg s "$1" --arg c "$2" --arg f "$2/.baton/progress/progress-testws-abc.md" \
    '{session_id:$s, cwd:$c, tool_name:"Write", tool_input:{file_path:$f}}')
  run_hook checkpoint-write-trigger.sh "$stdin" "$2" \
    "export BATON_AUTO_CONTINUE=$4; export TMUX='$5'; export SPAWN_LOG='$6'; export BATON_AUTO_CONTINUE_BIN='$TMP/inj.sh'" >/dev/null
  rm -f "/tmp/baton-pending-$1" "/tmp/baton-done-$1" "/tmp/claude-session-tracking-$1"
}

SPAWN_LOG="$TMP/spawn.on"; SPAWN_LOG_OFF="$TMP/spawn.off"; SPAWN_LOG_NOPANE="$TMP/spawn.np"
: > "$SPAWN_LOG"; : > "$SPAWN_LOG_OFF"; : > "$SPAWN_LOG_NOPANE"
_drive s-on   "$(mkstate)" '%3' 1 /tmp/fake,1,0 "$SPAWN_LOG"
_drive s-off  "$(mkstate)" '%3' 0 /tmp/fake,1,0 "$SPAWN_LOG_OFF"
_drive s-np   "$(mkstate)" ''   1 /tmp/fake,1,0 "$SPAWN_LOG_NOPANE"

# The trigger spawns the shim via `setsid ... &` (detached), so the shim's append
# to $SPAWN_LOG can land AFTER the trigger returns. Bounded-poll for the log
# to appear before asserting, else the enabled-case assert races and flakes.
for _i in $(seq 1 50); do [ -s "$SPAWN_LOG" ] && break; sleep 0.1; done

# opt-in ON + TMUX set + pane in term record -> injector invoked WITH the pane arg.
assert "spawn-when-enabled" "grep -qE '%[0-9]+' '$SPAWN_LOG'"
# Negative cases: nothing to poll FOR (asserting emptiness), so a short fixed
# settle wait is enough before checking the log stayed empty.
sleep 1
assert "no-spawn-when-optout" "[ ! -s '$SPAWN_LOG_OFF' ]"
# pane absent from record -> not invoked (even though TMUX is set + opt-in on)
assert "no-spawn-when-no-pane" "[ ! -s '$SPAWN_LOG_NOPANE' ]"

rm -rf "$TMP"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
