#!/usr/bin/env bash
# Every shipped slash command must be documented in tracked docs.
# /off and /snooze once shipped with zero mentions while /renew had three;
# nothing caught it until a reviewer did. This is that check.
set -u
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

cd "$REPO" || exit 1

for f in commands/*.md; do
  [ -e "$f" ] || continue
  cmd="$(basename "$f" .md)"
  ok "command /$cmd is documented in tracked docs" \
    "grep -rqF 'pass-the-baton:$cmd' README.md docs/*.md"
done

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
