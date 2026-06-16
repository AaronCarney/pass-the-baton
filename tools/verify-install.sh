#!/bin/bash
# verify-install.sh - end-to-end install verification.
#   --settings <path>          : settings.json to inspect (default ~/.claude/settings.json)
#   --skip-suite               : do not run the full v2 test suite (still checks settings + statusline tick)
#   --pre-commit-only          : run only the S2 smoke (E1 path) - fast pre-commit gate
#   --idempotency-check        : re-run install.sh and confirm zero mutation
#   --target <dir>             : project dir for --idempotency-check
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"

SETTINGS="$HOME/.claude/settings.json"
SKIP_SUITE=0
PRE_COMMIT=0
IDEM=0
TARGET="$PWD"

while [ $# -gt 0 ]; do
  case "$1" in
    --settings)           SETTINGS="$2"; shift 2 ;;
    --skip-suite)         SKIP_SUITE=1; shift ;;
    --pre-commit-only)    PRE_COMMIT=1; shift ;;
    --idempotency-check)  IDEM=1; shift ;;
    --target)             TARGET="$2"; shift 2 ;;
    *) echo "usage: verify-install.sh [--settings <path>] [--skip-suite] [--pre-commit-only] [--idempotency-check --target <dir>]"; exit 2 ;;
  esac
done

FAIL=0
check() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    echo "  OK   $name"
  else
    echo "  FAIL $name"
    FAIL=$((FAIL+1))
  fi
}

# 1. settings.json shape.
for EV in SessionStart PreToolUse PostToolUse SessionEnd UserPromptSubmit; do
  check "settings.json has $EV hook" \
    "[ -f '$SETTINGS' ] && jq -e --arg ev '$EV' '.hooks[\$ev] | map(.hooks[].command) | map(test(\"checkpoint|session-start|cleanup-on-exit|project-detect\")) | any' '$SETTINGS' >/dev/null 2>&1"
done

# 2. Pre-commit-only fast path: just confirm hook script files exist + are bash.
if [ "$PRE_COMMIT" = "1" ]; then
  for SH in session-start.sh context-checkpoint.sh checkpoint-write-trigger.sh cleanup-on-exit.sh project-detect.sh; do
    check "$SH executable" "head -1 '$REPO_DIR/.claude/hooks/$SH' | grep -q '^#!.*bash'"
  done
  [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi

# 3. Idempotency re-run (does not need a real Claude Code env).
#    True idempotency requires bit-identical settings.json after a second
#    install - exit code alone would mask duplicate registrations or jq
#    key-order changes.
if [ "$IDEM" = "1" ]; then
  if [ ! -f "$SETTINGS" ]; then
    echo "  FAIL idempotency: $SETTINGS missing - run install.sh first"
    FAIL=$((FAIL+1))
  else
    _idem_pre=$(md5sum "$SETTINGS" | awk '{print $1}')
    if ! bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$SETTINGS" --target "$TARGET" >/dev/null 2>&1; then
      echo "  FAIL idempotency: re-install exited non-zero"
      FAIL=$((FAIL+1))
    else
      _idem_post=$(md5sum "$SETTINGS" | awk '{print $1}')
      if [ "$_idem_pre" = "$_idem_post" ]; then
        echo "  OK   idempotency: settings.json bit-identical after re-install ($_idem_pre)"
      else
        echo "  FAIL idempotency: settings.json changed ($_idem_pre -> $_idem_post)"
        FAIL=$((FAIL+1))
      fi
    fi
    unset _idem_pre _idem_post
  fi
fi

# 4. Full suite (unless --skip-suite).
if [ "$SKIP_SUITE" = "0" ]; then
  for SCRIPT in test-workstream-hooks.sh test-restore-workstream.sh test-resume.sh test-install-tools.sh test-prompt-sync.sh; do
    SP="$REPO_DIR/.claude/hooks/tests/$SCRIPT"
    if [ ! -f "$SP" ]; then continue; fi
    if bash "$SP" 2>&1 | grep -qE '\b0 failed\b'; then
      echo "  OK   suite $SCRIPT"
    else
      echo "  FAIL suite $SCRIPT"
      FAIL=$((FAIL+1))
    fi
  done
fi

if [ "$FAIL" -gt 0 ]; then
  echo "verify-install: $FAIL check(s) failed"; exit 1
fi
echo "verify-install: all checks passed"
exit 0
