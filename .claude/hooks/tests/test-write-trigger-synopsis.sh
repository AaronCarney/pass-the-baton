#!/usr/bin/env bash
# Manual-only synopsis test for checkpoint-write-trigger.sh. Drives the hook to the
# success (DONE-latch) emit WITH and WITHOUT the manual marker /tmp/baton-manual-<sid>
# and asserts the handoff synopsis request appears ONLY for manual checkpoints and
# that the manual marker is consumed on the success path. The isolated-project +
# empty-template + workstream/terminal setup mirrors test-workstream-hooks.sh
# (mkproj/seed_terminal), the sibling suite that drives THIS hook to its
# "Checkpoint save complete" payload.
set -u
HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
WT="$HOOKS/checkpoint-write-trigger.sh"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
has(){ printf '%s' "${!1}" | grep -qi "$2"; }   # $1 = NAME of the var holding output

mkproj(){
  local d; d=$(mktemp -d)
  mkdir -p "$d/docs/sessions/.tracking/workstreams" "$d/docs/sessions/.tracking/terminals" "$d/projects"
  # Empty stub template: V1 lint diffs empty-vs-empty and the write reaches the
  # success path (see test-workstream-hooks.sh T23 for why this passes the lints).
  mkdir -p "$d/share/templates" && : > "$d/share/templates/free.md"
  echo "$d"
}
seed_terminal(){  # <tracking> <term_id> <ws> <display>
  local tracking="$1" term_id="$2" ws="$3" display="${4:-}" th
  source "$HOOKS/lib/workstream-lib.sh"
  th=$(USER=u CLAUDE_TERMINAL_ID="$term_id" term_hash)
  jq -n --arg tid "$term_id" --arg ws "$ws" \
    '{terminal_id:$tid, workstream:$ws, updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  jq -n --arg ws "$ws" --arg dn "$display" \
    '{workstream:$ws, display_name:$dn, progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/${ws}.json"
}
run_ckpt(){  # <proj> <sid> <file>
  printf '{"session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"}}' "$2" "$1" "$3" \
    | USER=u CLAUDE_TERMINAL_ID=CTerm CLAUDE_PROJECT_DIR="$1" \
      BATON_DIR="$1/docs/sessions/.tracking" bash "$WT" 2>/dev/null
}

# --- Manual checkpoint: synopsis requested + marker consumed ---
PROJ=$(mkproj)
seed_terminal "$PROJ/docs/sessions/.tracking" CTerm alpha-ws alpha
SID="unit-syn-man-$$"
touch "/tmp/baton-pending-${SID}" "/tmp/baton-manual-${SID}"
F="$PROJ/docs/sessions/progress-alpha-ws-syn.md"; echo "# ok" > "$F"
# shellcheck disable=SC2034  # used via the ${!1} nameref inside the eval'd ok conditions below
out=$(run_ckpt "$PROJ" "$SID" "$F")
ok "manual reaches success emit"    "has out 'save complete'"
ok "manual requests a synopsis"     "has out 'synopsis' || has out 'summar'"
ok "manual marker consumed on save" "[ ! -f /tmp/baton-manual-${SID} ]"
rm -f "/tmp/baton-pending-${SID}" "/tmp/baton-done-${SID}" "/tmp/baton-manual-${SID}"
rm -rf "$PROJ"

# --- Automated checkpoint: terse message, NO synopsis (token-waste guard) ---
PROJ=$(mkproj)
seed_terminal "$PROJ/docs/sessions/.tracking" CTerm alpha-ws alpha
SID="unit-syn-auto-$$"
touch "/tmp/baton-pending-${SID}"            # no manual marker
F="$PROJ/docs/sessions/progress-alpha-ws-syn.md"; echo "# ok" > "$F"
# shellcheck disable=SC2034  # used via the ${!1} nameref inside the eval'd ok conditions below
out=$(run_ckpt "$PROJ" "$SID" "$F")
ok "automated reaches success emit" "has out 'save complete'"
ok "automated omits synopsis"       "! ( has out 'synopsis' || has out 'summar' )"
rm -f "/tmp/baton-pending-${SID}" "/tmp/baton-done-${SID}"
rm -rf "$PROJ"

# --- E2: manual save defers DONE and asks for consent ---
PROJ=$(mkproj)
seed_terminal "$PROJ/docs/sessions/.tracking" CTerm alpha-ws alpha
SID="unit-e2-man-$$"
touch "/tmp/baton-pending-${SID}" "/tmp/baton-manual-${SID}"
F="$PROJ/docs/sessions/progress-alpha-ws-syn.md"; echo "# ok" > "$F"
# shellcheck disable=SC2034  # read via the ${!1} nameref inside has()
out=$(run_ckpt "$PROJ" "$SID" "$F")
ok "E2 manual writes the consent marker" "[ -f /tmp/baton-consent-${SID} ]"
ok "E2 manual defers the DONE latch"     "[ ! -f /tmp/baton-done-${SID} ]"
ok "E2 manual still clears PENDING"      "[ ! -f /tmp/baton-pending-${SID} ]"
ok "E2 manual names the resolver"        "has out 'baton-consent.sh'"
ok "E2 manual names both verbs"          "has out 'keep' && has out 'clear'"
# The consent tool must be invoked by an ABSOLUTE path: the model runs this string
# with cwd = user's project, which has no tools/ under a plugin install, so a bare
# relative `tools/baton-consent.sh` fails silently. The hook resolves it from its
# own SCRIPT_DIR (tools/ two levels up), so the emit must contain that exact path.
# shellcheck disable=SC2034  # read via ${!1} nameref inside has()
EXPECTED_CONSENT="$(cd "$HOOKS/../.." && pwd)/tools/baton-consent.sh"
ok "E2 manual uses an absolute consent path" "has out \"\$EXPECTED_CONSENT\""
rm -f "/tmp/baton-pending-${SID}" "/tmp/baton-done-${SID}" \
      "/tmp/baton-manual-${SID}" "/tmp/baton-consent-${SID}"
rm -rf "$PROJ"

# --- E2: automated save is unchanged - latches DONE, writes no consent marker ---
PROJ=$(mkproj)
seed_terminal "$PROJ/docs/sessions/.tracking" CTerm alpha-ws alpha
SID="unit-e2-auto-$$"
touch "/tmp/baton-pending-${SID}"            # no manual marker
F="$PROJ/docs/sessions/progress-alpha-ws-syn.md"; echo "# ok" > "$F"
# shellcheck disable=SC2034
out=$(run_ckpt "$PROJ" "$SID" "$F")
ok "E2 automated latches DONE"          "[ -f /tmp/baton-done-${SID} ]"
ok "E2 automated writes no consent"     "[ ! -f /tmp/baton-consent-${SID} ]"
rm -f "/tmp/baton-pending-${SID}" "/tmp/baton-done-${SID}" "/tmp/baton-consent-${SID}"
rm -rf "$PROJ"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
