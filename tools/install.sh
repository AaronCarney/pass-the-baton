#!/bin/bash
# install.sh - baton OSS installer.
# Modes:
#   bash install.sh                              # interactive (default; reads /dev/tty)
#   bash install.sh --non-interactive --target <proj-dir>
# Validates deps, walks the 5 first-time-setup prompts (interactive mode),
# calls merge-settings.sh, install-cron.sh, and appends .baton/ to the
# target project's .gitignore.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_DIR="$(cd "$REPO_DIR/.." && pwd -P)"

INTERACTIVE=1
[ ! -t 0 ] && INTERACTIVE=0
TARGET="${BATON_PROJECT_DIR:-$PWD}"
SETTINGS="$HOME/.claude/settings.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --interactive)     INTERACTIVE=1; shift ;;
    --non-interactive) INTERACTIVE=0; shift ;;
    --target)          TARGET="$2"; shift 2 ;;
    --settings)        SETTINGS="$2"; shift 2 ;;
    *) echo "usage: install.sh [--interactive|--non-interactive] [--target <dir>] [--settings <file>]"; exit 2 ;;
  esac
done

echo "=== baton installer ==="
echo "Repo:    $REPO_DIR"
echo "Target:  $TARGET"

# 1. Dep check.
MISSING=()
for cmd in jq flock grep find md5sum bash; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: missing required commands: ${MISSING[*]}"; exit 1
fi

# Optional analysis-tool dep check (does not block install). Each tool below
# unlocks an additional CLI surface; missing deps surface as a one-line note.
OPTIONAL_MISSING=()
command -v duckdb >/dev/null 2>&1 || OPTIONAL_MISSING+=("duckdb (tools/query.sh - DuckDB SQL over hook-events.jsonl)")
command -v bc     >/dev/null 2>&1 || OPTIONAL_MISSING+=("bc (lib/recommend-threshold-sweep.sh - tools/recommend.sh dependency)")
command -v python3 >/dev/null 2>&1 || OPTIONAL_MISSING+=("python3 + 'pip install -r requirements.txt' (tools/recommend.sh, tools/cost-compare.sh, hierarchical/bootstrap stats)")
if [ "${#OPTIONAL_MISSING[@]}" -gt 0 ]; then
  echo "" >&2
  echo "NOTE: optional analysis tools missing - core install will proceed, but the following CLI surfaces will not work until you install them:" >&2
  for m in "${OPTIONAL_MISSING[@]}"; do echo "  - $m" >&2; done
  echo "" >&2
fi

# 2. Bash 4+ check.
if ! ((BASH_VERSINFO[0] >= 4)); then
  echo "ERROR: bash 4.0+ required (found ${BASH_VERSION})"; exit 1
fi

# E7-T7: NFS detection
# Warn (do not refuse) when $XDG_STATE_HOME resolves onto a networked filesystem.
# Mirrors tools/doctor.sh fs-type probe; matches nfs/nfs4/cifs/smbfs. Walks up
# to nearest existing ancestor so a non-existent state dir still probes correctly.
_ccp_probe_state="${XDG_STATE_HOME:-$HOME/.local/state}"
while [ -n "$_ccp_probe_state" ] && [ ! -d "$_ccp_probe_state" ]; do
  _ccp_probe_state="$(dirname "$_ccp_probe_state")"
  [ "$_ccp_probe_state" = "/" ] && break
done
_ccp_fstype="$(stat -f -c %T "$_ccp_probe_state" 2>/dev/null || echo unknown)"
case "$_ccp_fstype" in
  nfs|nfs4|cifs|smbfs)
    echo "WARN: \$XDG_STATE_HOME (${XDG_STATE_HOME:-$HOME/.local/state}) is on $_ccp_fstype. flock semantics over networked filesystems are not reliable on all clients. See docs/telemetry.md. Continuing." >&2
    ;;
esac
unset _ccp_probe_state _ccp_fstype

# 3. First-time-setup prompts (interactive only).
#    These 5 blocks are the CANONICAL SOURCE for the prompt-sync sub-gate.
#    docs/install.md and .claude/skills/install-baton/SKILL.md must
#    render these prompts verbatim. Edit them here first; T14 enforces.
ask() {
  local var="$1" def="$2" prompt="$3" val=""
  if [ "$INTERACTIVE" = "1" ]; then
    printf '%s' "$prompt"
    printf '\n  Default: %s\n  > ' "$def"
    read -r val </dev/tty || val=""
  fi
  [ -z "$val" ] && val="$def"
  printf '%s=%s\n' "$var" "$val"
}

if [ "$INTERACTIVE" = "1" ]; then
  echo ""
  echo "=== First-time setup - 5 prompts ==="
  echo "Press Enter to accept each default."
  echo ""
fi

# >>> PROMPT-SYNC-BEGIN
P1_TEXT='Where should checkpoint state live? (BATON_DIR)
  This is the directory holding workstreams/, terminals/, and progress/.'
P1_DEFAULT="$TARGET/.baton"

P2_TEXT='Where should progress files live? (BATON_PROGRESS_DIR)
  Resume injects the most recent file from here at SessionStart.'
P2_DEFAULT="$P1_DEFAULT/progress"

P3_TEXT='Where should pruned workstreams be archived? (BATON_ARCHIVE_DIR)
  Idle >7d records move here. Recoverable via /resume.'
P3_DEFAULT="$HOME/.local/share/baton"

P4_TEXT='What is the project root cron should operate on? (BATON_PROJECT_DIR)
  Cleanup-cron runs out-of-shell; needs this fixed at install time.'
P4_DEFAULT="$TARGET"

P5_TEXT='Optional: how should this terminal name its workstream? (BATON_DISPLAY_NAME)
  Examples - basename: "${PWD##*/}"   git branch: "$(git symbolic-ref --short HEAD 2>/dev/null)"
  Leave blank for the auto-generated timestamp name.'
P5_DEFAULT=""
# <<< PROMPT-SYNC-END

if [ "$INTERACTIVE" = "1" ]; then
  BATON_DIR_ANS=$(ask BATON_DIR "$P1_DEFAULT" "$P1_TEXT")
  BATON_PROGRESS_DIR_ANS=$(ask BATON_PROGRESS_DIR "$P2_DEFAULT" "$P2_TEXT")
  BATON_ARCHIVE_DIR_ANS=$(ask BATON_ARCHIVE_DIR "$P3_DEFAULT" "$P3_TEXT")
  BATON_PROJECT_DIR_ANS=$(ask BATON_PROJECT_DIR "$P4_DEFAULT" "$P4_TEXT")
  BATON_DISPLAY_NAME_ANS=$(ask BATON_DISPLAY_NAME "$P5_DEFAULT" "$P5_TEXT")
else
  BATON_DIR_ANS="BATON_DIR=${BATON_DIR:-$P1_DEFAULT}"
  BATON_PROGRESS_DIR_ANS="BATON_PROGRESS_DIR=${BATON_PROGRESS_DIR:-$P2_DEFAULT}"
  BATON_ARCHIVE_DIR_ANS="BATON_ARCHIVE_DIR=${BATON_ARCHIVE_DIR:-$P3_DEFAULT}"
  BATON_PROJECT_DIR_ANS="BATON_PROJECT_DIR=${BATON_PROJECT_DIR:-$P4_DEFAULT}"
  BATON_DISPLAY_NAME_ANS="BATON_DISPLAY_NAME=${BATON_DISPLAY_NAME:-$P5_DEFAULT}"
fi

# Export so install-cron picks them up.
# Use bash word-splitting-safe declare to handle paths with spaces.
_apply_ans() {
  local ans="$1" var val
  var="${ans%%=*}"; val="${ans#*=}"
  printf -v "$var" '%s' "$val"
  export "$var"
}
_apply_ans "$BATON_DIR_ANS"
_apply_ans "$BATON_PROGRESS_DIR_ANS"
_apply_ans "$BATON_ARCHIVE_DIR_ANS"
_apply_ans "$BATON_PROJECT_DIR_ANS"
_apply_ans "$BATON_DISPLAY_NAME_ANS"

# 4. Statusline shim.
SHIM_SRC="$REPO_DIR/assets/baton-pct.sh"
SHIM_DEST_DIR="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
SHIM_DEST="$SHIM_DEST_DIR/baton-pct.sh"
mkdir -p "$SHIM_DEST_DIR"
if [ ! -f "$SHIM_DEST" ]; then
  cp "$SHIM_SRC" "$SHIM_DEST"
  chmod +x "$SHIM_DEST"
fi

# 5. Merge settings.json.
mkdir -p "$(dirname "$SETTINGS")"
bash "$REPO_DIR/tools/merge-settings.sh" "$SETTINGS"

# 6. Append .baton/ to target .gitignore (idempotent).
GITIGNORE="$TARGET/.gitignore"
mkdir -p "$TARGET"
touch "$GITIGNORE"
if ! grep -qE '^\.baton/?$' "$GITIGNORE"; then
  # Ensure the file ends in a newline so we don't fuse our line onto the
  # previous one (a no-final-newline .gitignore otherwise becomes
  # "lastline.baton/" - corrupting the prior rule and our own).
  if [ -s "$GITIGNORE" ] && [ "$(tail -c1 "$GITIGNORE" | od -An -tx1 | tr -d ' \n')" != "0a" ]; then
    printf '\n' >> "$GITIGNORE"
  fi
  echo ".baton/" >> "$GITIGNORE"
fi

# E7-T4: logrotate install
# Copy share/logrotate.d/baton to /etc/logrotate.d/ on Linux when
# logrotate is detected. Idempotent (skips if dest exists). Silent on macOS or
# when logrotate is absent. Non-root with unwritable dest → print sudo hint.
install_logrotate_snippet() {
  local src="$REPO_DIR/share/logrotate.d/baton"
  local dest_dir="${BATON_LOGROTATE_DEST_DIR:-/etc/logrotate.d}"
  local dest="$dest_dir/baton"
  [ -f "$src" ] || { echo "logrotate: snippet source missing, skipping"; return 0; }
  [ "$(uname -s)" = "Linux" ] || { echo "logrotate: not Linux, skipping"; return 0; }
  command -v logrotate >/dev/null 2>&1 || { echo "logrotate: command not found, skipping"; return 0; }
  if [ -e "$dest" ]; then
    echo "logrotate: $dest already present, skipping (idempotent)"
    return 0
  fi
  if [ -w "$dest_dir" ] 2>/dev/null || { [ ! -e "$dest_dir" ] && mkdir -p "$dest_dir" 2>/dev/null; }; then
    cp "$src" "$dest" && echo "logrotate: installed $dest"
  else
    echo "logrotate: $dest_dir not writable; install manually:"
    echo "  sudo cp $src $dest"
  fi
}
install_logrotate_snippet

# E8-T6: post-tool-batch hook register begin
# Register PostToolBatch cost telemetry hook in ~/.claude/settings.json.
# Idempotent - re-running does not duplicate the entry.
_ptb_settings="$SETTINGS"
_ptb_prefix="${INSTALL_PREFIX:-$REPO_DIR}"
_ptb_cmd="bash $_ptb_prefix/.claude/hooks/post-tool-batch.sh"
mkdir -p "$(dirname "$_ptb_settings")"
[ -f "$_ptb_settings" ] || printf '{}' > "$_ptb_settings"
jq --arg cmd "$_ptb_cmd" '
  .hooks.PostToolBatch //= [] |
  if any(.hooks.PostToolBatch[]?; .hooks[0]?.command == $cmd) then .
  else .hooks.PostToolBatch += [{
    hooks: [{type: "command", command: $cmd, timeout: 5}]
  }]
  end
' "$_ptb_settings" > "$_ptb_settings.tmp" && mv "$_ptb_settings.tmp" "$_ptb_settings"
chmod 0644 "$_ptb_settings"
printf 'baton: registered PostToolBatch hook in %s\n' "$_ptb_settings" >&2
unset _ptb_settings _ptb_prefix _ptb_cmd
# E8-T6: post-tool-batch hook register end

# SubagentStop hook register begin
# Register SubagentStop per-subagent cost telemetry hook in ~/.claude/settings.json.
# Idempotent - re-running does not duplicate the entry.
_ssc_settings="$SETTINGS"
_ssc_prefix="${INSTALL_PREFIX:-$REPO_DIR}"
_ssc_cmd="bash $_ssc_prefix/.claude/hooks/post-subagent-cost.sh"
mkdir -p "$(dirname "$_ssc_settings")"
[ -f "$_ssc_settings" ] || printf '{}' > "$_ssc_settings"
jq --arg cmd "$_ssc_cmd" '
  .hooks.SubagentStop //= [] |
  if any(.hooks.SubagentStop[]?; .hooks[0]?.command == $cmd) then .
  else .hooks.SubagentStop += [{
    hooks: [{type: "command", command: $cmd, timeout: 5}]
  }]
  end
' "$_ssc_settings" > "$_ssc_settings.tmp" && mv "$_ssc_settings.tmp" "$_ssc_settings"
chmod 0644 "$_ssc_settings"
printf 'baton: registered SubagentStop hook in %s\n' "$_ssc_settings" >&2
unset _ssc_settings _ssc_prefix _ssc_cmd
# SubagentStop hook register end

# tool-timing hook register begin
# Register tool-timing PostToolUse hook in ~/.claude/settings.json.
# Idempotent. Hook is OFF by default - emission gated on BATON_TIMING=1.
# Matcher is empty (all tools); coexists with the checkpoint-write-trigger
# PostToolUse entry which has matcher "Write|Edit|MultiEdit".
_tt_settings="$SETTINGS"
_tt_prefix="${INSTALL_PREFIX:-$REPO_DIR}"
_tt_cmd="bash $_tt_prefix/.claude/hooks/tool-timing.sh"
mkdir -p "$(dirname "$_tt_settings")"
[ -f "$_tt_settings" ] || printf '{}' > "$_tt_settings"
jq --arg cmd "$_tt_cmd" '
  .hooks.PostToolUse //= [] |
  if any(.hooks.PostToolUse[]?; .hooks[0]?.command == $cmd) then .
  else .hooks.PostToolUse += [{
    hooks: [{type: "command", command: $cmd, timeout: 5}]
  }]
  end
' "$_tt_settings" > "$_tt_settings.tmp" && mv "$_tt_settings.tmp" "$_tt_settings"
chmod 0644 "$_tt_settings"
printf 'baton: registered tool-timing hook (off by default; set BATON_TIMING=1 to enable) in %s\n' "$_tt_settings" >&2
unset _tt_settings _tt_prefix _tt_cmd
# tool-timing hook register end

# 7. Install cron wrapper.
bash "$REPO_DIR/tools/install-cron.sh" --dry-run

echo ""
echo "=== Install complete ==="
echo "Verify with: bash $REPO_DIR/tools/verify-install.sh"
