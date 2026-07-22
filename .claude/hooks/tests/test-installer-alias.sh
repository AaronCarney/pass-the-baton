#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
INSTALL="$REPO/tools/install.sh"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; fi; }

# Opt-in run: alias installed + mode persisted.
T1=$(mktemp -d)
env -i HOME="$T1/home" PATH="$PATH" \
    XDG_CONFIG_HOME="$T1/cfg" BATON_LOGROTATE_DEST_DIR="$T1/lr" \
    BATON_ENABLE_AUTOCONTINUE=yes \
    bash "$INSTALL" --non-interactive --target "$T1/proj" --settings "$T1/settings.json" \
    >/dev/null 2>&1 || true
# Capture persisted config values first: command-substitution inside an ok()
# assertion string runs at argument-build time, where the escaped quotes around
# the path would reach jq as literal chars and mis-open the file. Read into vars.
T1_ACM=$(jq -r '.auto_continue_mode' "$T1/cfg/baton/config.json" 2>/dev/null)
T1_LA=$(jq -r '.launch_alias' "$T1/cfg/baton/config.json" 2>/dev/null)
ok "opt-in writes baton alias to ~/.bashrc" "grep -q \"alias baton='bash \" \"$T1/home/.bashrc\"" # publish-home-ok
ok "opt-in persists auto_continue_mode=relaunch" "[ \"$T1_ACM\" = relaunch ]"
ok "opt-in alias target is tools/baton-run.sh" "grep -qE \"alias baton='bash .*/tools/baton-run.sh'\" \"$T1/home/.bashrc\"" # publish-home-ok
ok "opt-in persists launch_alias=baton" "[ \"$T1_LA\" = baton ]"
rm -rf "$T1"

# Default run (no opt-in): clean no-op, no alias block.
T2=$(mktemp -d)
env -i HOME="$T2/home" PATH="$PATH" \
    XDG_CONFIG_HOME="$T2/cfg" BATON_LOGROTATE_DEST_DIR="$T2/lr" \
    bash "$INSTALL" --non-interactive --target "$T2/proj" --settings "$T2/settings.json" \
    >/dev/null 2>&1 || true
ok "no opt-in: no baton alias block" "! grep -rq 'baton launch alias' \"$T2/home\" 2>/dev/null"
rm -rf "$T2"

# --- P6 decoupling: alias install must not clobber a preselected driver ---

# (a) Fresh install, no prior mode -> seeds relaunch AND writes the baton alias.
T3=$(mktemp -d)
env -i HOME="$T3/home" PATH="$PATH" \
    XDG_CONFIG_HOME="$T3/cfg" BATON_LOGROTATE_DEST_DIR="$T3/lr" \
    BATON_ENABLE_AUTOCONTINUE=yes \
    bash "$INSTALL" --non-interactive --target "$T3/proj" --settings "$T3/settings.json" \
    >/dev/null 2>&1 || true
T3_ACM=$(jq -r '.auto_continue_mode' "$T3/cfg/baton/config.json" 2>/dev/null)
ok "fresh install seeds relaunch" "[ \"$T3_ACM\" = relaunch ]"
ok "fresh install writes baton alias" "grep -qE \"alias baton='bash .*/tools/baton-run.sh'\" \"$T3/home/.bashrc\"" # publish-home-ok
rm -rf "$T3"

# (b) Preselected tmux -> alias opt-in preserves it (not overwritten to relaunch).
T4=$(mktemp -d)
mkdir -p "$T4/cfg/baton"
printf '{"auto_continue_mode":"tmux"}\n' > "$T4/cfg/baton/config.json"
env -i HOME="$T4/home" PATH="$PATH" \
    XDG_CONFIG_HOME="$T4/cfg" BATON_LOGROTATE_DEST_DIR="$T4/lr" \
    BATON_ENABLE_AUTOCONTINUE=yes \
    bash "$INSTALL" --non-interactive --target "$T4/proj" --settings "$T4/settings.json" \
    >/dev/null 2>&1 || true
T4_ACM=$(jq -r '.auto_continue_mode' "$T4/cfg/baton/config.json" 2>/dev/null)
ok "preselected tmux preserved on alias opt-in" "[ \"$T4_ACM\" = tmux ]"
ok "preselected tmux still installs baton alias" "grep -qE \"alias baton='bash .*/tools/baton-run.sh'\" \"$T4/home/.bashrc\"" # publish-home-ok
rm -rf "$T4"

# (c) No opt-in -> driver untouched (no auto_continue_mode key written).
T5=$(mktemp -d)
env -i HOME="$T5/home" PATH="$PATH" \
    XDG_CONFIG_HOME="$T5/cfg" BATON_LOGROTATE_DEST_DIR="$T5/lr" \
    bash "$INSTALL" --non-interactive --target "$T5/proj" --settings "$T5/settings.json" \
    >/dev/null 2>&1 || true
T5_ACM=$(jq -r '.auto_continue_mode // empty' "$T5/cfg/baton/config.json" 2>/dev/null)
ok "opt-out writes no auto_continue_mode key" "[ -z \"$T5_ACM\" ]"
rm -rf "$T5"

# (d) Legacy BATON_AUTO_CONTINUE=1 resolves to effective tmux -> relaunch NOT reseeded.
T6=$(mktemp -d)
env -i HOME="$T6/home" PATH="$PATH" \
    XDG_CONFIG_HOME="$T6/cfg" BATON_LOGROTATE_DEST_DIR="$T6/lr" \
    BATON_AUTO_CONTINUE=1 BATON_ENABLE_AUTOCONTINUE=yes \
    bash "$INSTALL" --non-interactive --target "$T6/proj" --settings "$T6/settings.json" \
    >/dev/null 2>&1 || true
T6_ACM=$(jq -r '.auto_continue_mode // empty' "$T6/cfg/baton/config.json" 2>/dev/null)
ok "legacy BATON_AUTO_CONTINUE=1 not reseeded to relaunch" "[ \"$T6_ACM\" != relaunch ]"
rm -rf "$T6"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
