#!/bin/bash
# Tests for project-context.sh resolver.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/project-context.sh"

FAIL=0

# Test 1: convention fallback finds docs/PRD.md when no config exists
TMP=$(mktemp -d)
mkdir -p "$TMP/docs"
echo "# PRD" > "$TMP/docs/PRD.md"
actual=$(pc::resolve_role "$TMP" prd)
expected="$TMP/docs/PRD.md"
[ "$actual" = "$expected" ] || { echo "FAIL t1: convention prd: got $actual, want $expected"; FAIL=1; }
rm -rf "$TMP"

# Test 2: explicit config maps a role to a custom path
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton-project" "$TMP/specs"
echo "# arch" > "$TMP/specs/architecture.md"
cat > "$TMP/.baton-project/project-context.json" <<'EOF'
{"version": 1, "roles": {"architecture": "specs/architecture.md"}, "fallback_strategy": "explicit"}
EOF
actual=$(pc::resolve_role "$TMP" architecture)
expected="$TMP/specs/architecture.md"
[ "$actual" = "$expected" ] || { echo "FAIL t2: explicit architecture: got $actual, want $expected"; FAIL=1; }
rm -rf "$TMP"

# Test 3: explicit mode does NOT fall back to convention
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton-project" "$TMP/docs"
echo "# PRD" > "$TMP/docs/PRD.md"  # convention path exists
cat > "$TMP/.baton-project/project-context.json" <<'EOF'
{"version": 1, "roles": {}, "fallback_strategy": "explicit"}
EOF
actual=$(pc::resolve_role "$TMP" prd)
[ -z "$actual" ] || { echo "FAIL t3: explicit-mode prd should not fallback: got $actual"; FAIL=1; }
rm -rf "$TMP"

# Test 4: missing files are skipped silently in render_manifest
TMP=$(mktemp -d)
mkdir -p "$TMP/docs"
echo "# PRD" > "$TMP/docs/PRD.md"
# decisions.md and ARCHITECTURE.md intentionally absent
out=$(pc::render_manifest "$TMP" factory)
echo "$out" | grep -q "PRD" || { echo "FAIL t4: should include PRD row"; FAIL=1; }
echo "$out" | grep -q "Decisions" && { echo "FAIL t4: should NOT include missing Decisions row"; FAIL=1; }
rm -rf "$TMP"

# Test 5: render_manifest output rows match the documented shape
TMP=$(mktemp -d)
mkdir -p "$TMP/docs"
echo "# PRD" > "$TMP/docs/PRD.md"
out=$(pc::render_manifest "$TMP" factory)
echo "$out" | grep -qE '^\- \*\*PRD\*\* - `docs/PRD\.md` - read if' || { echo "FAIL t5: row shape mismatch: $out"; FAIL=1; }
rm -rf "$TMP"

# Test 6: project_context_file override in global config - resolver reads from override path
TMP=$(mktemp -d)
# Create a fake XDG_CONFIG_HOME with a config that redirects the project-context file.
mkdir -p "$TMP/config/baton" "$TMP/project/specs"
cat > "$TMP/config/baton/config.json" <<EOF
{"project_context_file": "specs/project-context.json"}
EOF
echo "# architecture" > "$TMP/project/specs/architecture.md"
cat > "$TMP/project/specs/project-context.json" <<'EOF'
{"version": 1, "roles": {"architecture": "specs/architecture.md"}, "fallback_strategy": "convention"}
EOF
actual=$(XDG_CONFIG_HOME="$TMP/config" pc::resolve_role "$TMP/project" architecture)
expected="$TMP/project/specs/architecture.md"
[ "$actual" = "$expected" ] || { echo "FAIL t6: project_context_file override: got $actual, want $expected"; FAIL=1; }
rm -rf "$TMP"

if [ "$FAIL" = "0" ]; then echo "PASS test-project-context.sh"; else exit 1; fi
