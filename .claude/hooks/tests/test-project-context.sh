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


# Test 7 (E7): a brand-new user-defined role produces an injected manifest row
# with NO code edit - object entry carrying label+hint+path.
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton-project" "$TMP/ops"
echo "# runbook" > "$TMP/ops/RUNBOOK.md"
cat > "$TMP/.baton-project/project-context.json" <<'EOF'
{"version":1,"fallback_strategy":"convention","roles":{"runbook":{"label":"Runbook","hint":"you need operational runbook steps","path":"ops/RUNBOOK.md"}}}
EOF
out=$(pc::render_manifest "$TMP" factory)
echo "$out" | grep -qE '^\- \*\*Runbook\*\* - `ops/RUNBOOK\.md` - read if you need operational runbook steps' || { echo "FAIL t7: user-defined role row missing/misshaped: $out"; FAIL=1; }
rm -rf "$TMP"

# Test 8 (E7): an object entry overrides a built-in role's path + label; hint falls
# back to the seed when the object omits it. Explicit mode isolates architecture.
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton-project" "$TMP/specs"
echo "# arch" > "$TMP/specs/sys.md"
cat > "$TMP/.baton-project/project-context.json" <<'EOF'
{"version":1,"fallback_strategy":"explicit","roles":{"architecture":{"label":"System Design","path":"specs/sys.md"}}}
EOF
out=$(pc::render_manifest "$TMP" factory)
echo "$out" | grep -qE '^\- \*\*System Design\*\* - `specs/sys\.md` - read if your change touches module boundaries' || { echo "FAIL t8: object override (label+path, seed hint) failed: $out"; FAIL=1; }
rm -rf "$TMP"

# Test 9 (E7): built-in roles keep their seed order and a new user role appends
# AFTER them by default (no explicit order).
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton-project" "$TMP/docs" "$TMP/ops"
echo "# prd" > "$TMP/docs/PRD.md"
echo "# dec" > "$TMP/docs/decisions.md"
echo "# rb"  > "$TMP/ops/RUNBOOK.md"
cat > "$TMP/.baton-project/project-context.json" <<'EOF'
{"version":1,"fallback_strategy":"convention","roles":{"runbook":{"label":"Runbook","hint":"h","path":"ops/RUNBOOK.md"}}}
EOF
out=$(pc::render_manifest "$TMP" factory)
order=$(echo "$out" | grep -oE '\*\*(PRD|Decisions|Runbook)\*\*' | tr -d '*' | paste -sd, -)
[ "$order" = "PRD,Decisions,Runbook" ] || { echo "FAIL t9: role order wrong: got '$order' want 'PRD,Decisions,Runbook'"; FAIL=1; }
rm -rf "$TMP"

# Test 10 (E7): an explicit `order` on a user role sorts it ahead of the built-ins.
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton-project" "$TMP/docs" "$TMP/ops"
echo "# prd" > "$TMP/docs/PRD.md"
echo "# rb"  > "$TMP/ops/RUNBOOK.md"
cat > "$TMP/.baton-project/project-context.json" <<'EOF'
{"version":1,"fallback_strategy":"convention","roles":{"runbook":{"label":"Runbook","hint":"h","path":"ops/RUNBOOK.md","order":5}}}
EOF
out=$(pc::render_manifest "$TMP" factory)
first=$(echo "$out" | head -1 | grep -oE '\*\*[A-Za-z ]+\*\*' | tr -d '*')
[ "$first" = "Runbook" ] || { echo "FAIL t10: explicit order not honored, first row label = '$first'"; FAIL=1; }
rm -rf "$TMP"

# Test 11 (E7 backward-compat): a pre-E7 bare-STRING role value (path override)
# still renders, using the built-in seed label + hint (no object needed).
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton-project" "$TMP/specs"
echo "# prd" > "$TMP/specs/product.md"
cat > "$TMP/.baton-project/project-context.json" <<'EOF'
{"version":1,"fallback_strategy":"explicit","roles":{"prd":"specs/product.md"}}
EOF
out=$(pc::render_manifest "$TMP" factory)
echo "$out" | grep -qE '^\- \*\*PRD\*\* - `specs/product\.md` - read if you need product intent' || { echo "FAIL t11: string-value backward-compat render failed: $out"; FAIL=1; }
rm -rf "$TMP"

# Test 12 (E7): a role object with NO hint renders a row WITHOUT the read-if clause.
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton-project" "$TMP/ops"
echo "# rb" > "$TMP/ops/RUNBOOK.md"
cat > "$TMP/.baton-project/project-context.json" <<'EOF'
{"version":1,"fallback_strategy":"convention","roles":{"runbook":{"label":"Runbook","path":"ops/RUNBOOK.md"}}}
EOF
out=$(pc::render_manifest "$TMP" factory)
echo "$out" | grep -qE '^\- \*\*Runbook\*\* - `ops/RUNBOOK\.md`$' || { echo "FAIL t12: hint-less role row should omit read-if clause: $out"; FAIL=1; }
echo "$out" | grep -q 'read if' && { echo "FAIL t12: hint-less role row must NOT contain a read-if clause: $out"; FAIL=1; }
rm -rf "$TMP"

# Test 13 (E7 backward-compat): an explicit path pointing to a MISSING file suppresses
# the role - render_manifest must NOT silently fall back to the convention file.
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton-project" "$TMP/docs"
echo "# PRD" > "$TMP/docs/PRD.md"
cat > "$TMP/.baton-project/project-context.json" <<'EOF'
{"version":1,"fallback_strategy":"convention","roles":{"prd":"specs/missing.md"}}
EOF
out=$(pc::render_manifest "$TMP" factory)
echo "$out" | grep -q 'PRD' && { echo "FAIL t13: missing explicit path must suppress row, not fall back to convention: $out"; FAIL=1; }
rm -rf "$TMP"

# Test 14 (E7 robustness): a malformed project-context.json degrades to the built-in
# seed (convention rows still render) instead of a silently-empty manifest.
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton-project" "$TMP/docs"
echo "# PRD" > "$TMP/docs/PRD.md"
printf '{not valid json' > "$TMP/.baton-project/project-context.json"
out=$(pc::render_manifest "$TMP" factory)
echo "$out" | grep -qE '^\- \*\*PRD\*\* - `docs/PRD\.md` - read if' || { echo "FAIL t14: malformed config should degrade to seed convention rows: $out"; FAIL=1; }
rm -rf "$TMP"

# Test 15 (E7 robustness): an EMPTY project-context.json degrades to the built-in seed
# instead of a silently-empty manifest (jq empty exits 0 on empty input; shape check catches it).
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton-project" "$TMP/docs"
echo "# PRD" > "$TMP/docs/PRD.md"
: > "$TMP/.baton-project/project-context.json"
out=$(pc::render_manifest "$TMP" factory)
echo "$out" | grep -qE '^\- \*\*PRD\*\* - `docs/PRD\.md` - read if' || { echo "FAIL t15: empty config should degrade to seed convention rows: $out"; FAIL=1; }
rm -rf "$TMP"

# Test 16 (E7 robustness): a well-formed but NON-OBJECT config (array) degrades to the
# built-in seed rather than crashing pc::_registry with a silently-empty manifest.
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton-project" "$TMP/docs"
echo "# PRD" > "$TMP/docs/PRD.md"
printf '[]' > "$TMP/.baton-project/project-context.json"
out=$(pc::render_manifest "$TMP" factory)
echo "$out" | grep -qE '^\- \*\*PRD\*\* - `docs/PRD\.md` - read if' || { echo "FAIL t16: non-object config should degrade to seed convention rows: $out"; FAIL=1; }
rm -rf "$TMP"

if [ "$FAIL" = "0" ]; then echo "PASS test-project-context.sh"; else exit 1; fi
