#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/template-resolve.sh"
FAIL=0

# Test 1: env var takes precedence over config
TMP=$(mktemp -d)
mkdir -p "$TMP/share/templates" "$TMP/.config/baton" "$TMP/custom"
echo '# shipped free' > "$TMP/share/templates/free.md"
echo '# custom' > "$TMP/custom/myproject.md"
echo '{"template": "free"}' > "$TMP/.config/baton/config.json"
XDG_CONFIG_HOME="$TMP/.config" BATON_TEMPLATE_PATH="$TMP/custom/myproject.md" actual=$(tpl::resolve_active_template "$TMP")
[ "$actual" = "$TMP/custom/myproject.md" ] || { echo "FAIL t1: env var should win: got $actual"; FAIL=1; }
rm -rf "$TMP"

# Test 2: config templates_dir + template name resolves
TMP=$(mktemp -d)
mkdir -p "$TMP/share/templates" "$TMP/.config/baton" "$TMP/custom"
echo '# shipped' > "$TMP/share/templates/free.md"
echo '# task custom' > "$TMP/custom/task.md"
cat > "$TMP/.config/baton/config.json" <<EOF
{"template": "task", "templates_dir": "$TMP/custom"}
EOF
XDG_CONFIG_HOME="$TMP/.config" actual=$(tpl::resolve_active_template "$TMP")
[ "$actual" = "$TMP/custom/task.md" ] || { echo "FAIL t2: templates_dir resolution: got $actual"; FAIL=1; }
rm -rf "$TMP"

# Test 3: shipped default for known template id
TMP=$(mktemp -d)
mkdir -p "$TMP/share/templates" "$TMP/.config/baton"
echo '# shipped factory' > "$TMP/share/templates/factory.md"
echo '{"template": "factory"}' > "$TMP/.config/baton/config.json"
XDG_CONFIG_HOME="$TMP/.config" actual=$(tpl::resolve_active_template "$TMP")
[ "$actual" = "$TMP/share/templates/factory.md" ] || { echo "FAIL t3: shipped factory: got $actual"; FAIL=1; }
rm -rf "$TMP"

# Test 4: missing config + missing template falls back to free.md
TMP=$(mktemp -d)
mkdir -p "$TMP/share/templates"
echo '# shipped free' > "$TMP/share/templates/free.md"
actual=$(tpl::resolve_active_template "$TMP")
[ "$actual" = "$TMP/share/templates/free.md" ] || { echo "FAIL t4: ultimate fallback should be shipped free.md: got $actual"; FAIL=1; }
rm -rf "$TMP"

# Test 5: symlinked-consumer pattern - project_dir has NO share/ directory, lib must
# fall back to its OWN repo's shipped templates. Repro of the symlinked-consumer
# bug where CLAUDE_PROJECT_DIR=<workspace-root> (no share/) but hooks are sourced
# from a symlinked checkpoint repo whose share/templates/ has the real templates.
LIB_REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP=$(mktemp -d)  # deliberately NO share/templates/
actual=$(tpl::resolve_active_template "$TMP")
[ "$actual" = "$LIB_REPO/share/templates/free.md" ] || { echo "FAIL t5: lib-repo fallback when project_dir has no share/: got $actual (expected $LIB_REPO/share/templates/free.md)"; FAIL=1; }
[ -f "$actual" ] || { echo "FAIL t5: resolved path must point at an existing file: $actual"; FAIL=1; }
rm -rf "$TMP"

# Test 6: symlinked-consumer pattern + non-default template id via config. Confirms
# the rung-4 fallback honors the configured template_id, not just free.md.
TMP=$(mktemp -d)
mkdir -p "$TMP/.config/baton"  # no share/templates/
echo '{"template": "task"}' > "$TMP/.config/baton/config.json"
actual=$(XDG_CONFIG_HOME="$TMP/.config" tpl::resolve_active_template "$TMP")
[ "$actual" = "$LIB_REPO/share/templates/task.md" ] || { echo "FAIL t6: lib-repo fallback for non-default template: got $actual"; FAIL=1; }
[ -f "$actual" ] || { echo "FAIL t6: resolved path must point at an existing file: $actual"; FAIL=1; }
rm -rf "$TMP"

if [ "$FAIL" = "0" ]; then echo "PASS test-template-resolve.sh"; else exit 1; fi
