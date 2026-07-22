#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
LIB="$REPO/lib/shell-alias.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
# shellcheck source=/dev/null
source "$LIB"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; fi; }

# --- alias_name_valid: distinct rc per rejection reason ---
alias_name_valid baton; rc=$?;        ok "plain name accepted"      "[ $rc -eq 0 ]"
alias_name_valid ""; rc=$?;           ok "empty rejected rc1"       "[ $rc -eq 1 ]"
alias_name_valid 'bad name'; rc=$?;   ok "space rejected rc2"       "[ $rc -eq 2 ]"
alias_name_valid 'foo/bar'; rc=$?;    ok "slash rejected rc2"       "[ $rc -eq 2 ]"
alias_name_valid '1abc'; rc=$?;       ok "leading digit rejected"   "[ $rc -eq 2 ]"
alias_name_valid cd; rc=$?;           ok "builtin rejected rc3"     "[ $rc -eq 3 ]"
alias_name_valid for; rc=$?;          ok "keyword rejected rc4"     "[ $rc -eq 4 ]"

mkdir -p "$TMP/bin"; printf '#!/bin/sh\ntrue\n' > "$TMP/bin/myshadow"; chmod +x "$TMP/bin/myshadow"
PATH="$TMP/bin:$PATH" alias_name_valid myshadow; rc=$?;          ok "PATH shadow rejected rc5" "[ $rc -eq 5 ]"
PATH="$TMP/bin:$PATH" alias_name_valid myshadow myshadow; rc=$?; ok "reclaim sentinel allows" "[ $rc -eq 0 ]"

# --- alias_rc_files ---
rm -f "$HOME/.bashrc" "$HOME/.zshrc"
out=$(alias_rc_files)
ok "no rc files: creates and prints ~/.bashrc" "[ \"$out\" = \"$HOME/.bashrc\" ] && [ -f \"$HOME/.bashrc\" ]"
: > "$HOME/.zshrc"
out=$(alias_rc_files | tr '\n' ' ')
ok "both rc files printed" "printf '%s' \"$out\" | grep -q '.bashrc' && printf '%s' \"$out\" | grep -q '.zshrc'"

# --- alias_write: idempotent marker-guarded block ---
RC="$TMP/rc1"; printf 'export FOO=1\n' > "$RC"
alias_write baton 'bash /x/tools/baton-run.sh' "$RC"
ok "block written" "grep -q \"alias baton='bash /x/tools/baton-run.sh'\" \"$RC\""
ok "prior content preserved" "grep -q 'export FOO=1' \"$RC\""
alias_write baton 'bash /x/tools/baton-run.sh' "$RC"
n=$(grep -c '>>> baton launch alias >>>' "$RC")
ok "idempotent: exactly one marker block" "[ \"$n\" -eq 1 ]"

alias_write baton 'bash /y/tools/baton-run.sh' "$RC"
n=$(grep -c '>>> baton launch alias >>>' "$RC")
ok "rewrite keeps one block" "[ \"$n\" -eq 1 ]"
ok "rewrite updates target" "grep -q \"alias baton='bash /y/tools/baton-run.sh'\" \"$RC\""
ok "old target gone" "! grep -q '/x/tools/baton-run.sh' \"$RC\""

# --- single-quote in target: alias body must stay valid ---
RCQ="$TMP/rcq"; : > "$RCQ"
alias_write baton "bash /home/o'brien/tools/baton-run.sh" "$RCQ" # publish-home-ok
ok "apostrophe target: escaped form written" "grep -qF \"alias baton='bash /home/o'\\\\''brien/tools/baton-run.sh'\" \"$RCQ\"" # publish-home-ok
# shellcheck source=/dev/null
( unset -f alias_name_valid alias_rc_files alias_write; unalias baton 2>/dev/null; . "$RCQ" && [ "$(alias baton)" = "alias baton='bash /home/o'\\''brien/tools/baton-run.sh'" ] ) # publish-home-ok
ok "apostrophe target: rc sources without error" "[ $? -eq 0 ]"

# --- symlinked rc: rewrite must preserve the symlink ---
RCREAL="$TMP/rcreal"; RCLINK="$TMP/rclink"
printf 'export BAZ=3\n' > "$RCREAL"; ln -s "$RCREAL" "$RCLINK"
alias_write baton 'bash /a/tools/baton-run.sh' "$RCLINK"   # create block
alias_write baton 'bash /b/tools/baton-run.sh' "$RCLINK"   # rewrite in place
ok "symlink rc: still a symlink after rewrite" "[ -L \"$RCLINK\" ]"
ok "symlink rc: rewrite reached real file" "grep -q '/b/tools/baton-run.sh' \"$RCREAL\""

# --- trailing-newline guard: no-final-newline rc must not fuse ---
RC2="$TMP/rc2"; printf 'export BAR=2' > "$RC2"   # deliberately no trailing newline
alias_write baton 'bash /z/tools/baton-run.sh' "$RC2"
ok "no-newline rc: prior line intact" "grep -qx 'export BAR=2' \"$RC2\""
ok "no-newline rc: marker on own line" "grep -qx '# >>> baton launch alias >>>' \"$RC2\""


echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
