set -u
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SS="$HOOKS_DIR/session-start.sh"
source "$HOOKS_DIR/lib/workstream-lib.sh"
PASS=0; FAIL=0
assert(){ if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

# Local helper: run session-start in an isolated project sandbox. Mirrors
# test-workstream-hooks.sh:65 (run_session_start) but is defined here - no shared
# harness fn exists. Echoes the resolved terminal-record path.
_run_ss() { # $1=term_id $2=sid ; TMUX/TMUX_PANE inherited from caller env
  local term="$1" sid="$2" proj; proj=$(mktemp -d)
  mkdir -p "$proj/docs/sessions/.tracking/terminals" "$proj/projects"
  USER=u CLAUDE_TERMINAL_ID="$term" CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$proj/docs/sessions/.tracking" \
    bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$proj\"}" >/dev/null 2>&1
  local th; th=$(USER=u CLAUDE_TERMINAL_ID="$term" term_hash)
  echo "$proj/docs/sessions/.tracking/terminals/${th}.json"
}

# Case A: inside tmux -> pane stamped
TF=$(TMUX=/tmp/fake-tmux,1,0 TMUX_PANE='%7' _run_ss A sid-a-$$)
_pane=$(jq -r '.tmux_pane // empty' "$TF")
assert "tmux-pane-stamped" "[ '$_pane' = '%7' ]"

# Case B: no tmux -> field absent. MUST scrub TMUX/TMUX_PANE explicitly: this suite
# may itself run inside a tmux pane, so ambient $TMUX would leak in and session-start
# would stamp .tmux_pane, false-failing this assert. `TMUX=` (empty) reads as no-tmux
# via session-start's `[ -n "${TMUX:-}" ]` guard.
TF2=$(TMUX= TMUX_PANE= _run_ss B sid-b-$$)
_pane=$(jq -r '.tmux_pane // "ABSENT"' "$TF2")
assert "no-tmux-pane-absent" "[ '$_pane' = 'ABSENT' ]"

echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
