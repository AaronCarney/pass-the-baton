#!/bin/bash
# Integration tests for the multi-template system.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHARE_DIR="$SCRIPT_DIR/../../share/templates"
source "$SCRIPT_DIR/lib/lints.sh"
FAIL=0

# Test 1: All three shipped templates exist and parse as markdown
for t in free task factory; do
  [ -f "$SHARE_DIR/$t.md" ] || { echo "FAIL t1: $t.md missing"; FAIL=1; }
  [ -f "$SHARE_DIR/$t.json" ] || { echo "FAIL t1: $t.json missing"; FAIL=1; }
  grep -qE '^## Session Directive$' "$SHARE_DIR/$t.md" || { echo "FAIL t1: $t.md lacks Session Directive section"; FAIL=1; }
  grep -qE "^## What's Next$" "$SHARE_DIR/$t.md" || { echo "FAIL t1: $t.md lacks What's Next section"; FAIL=1; }
done

# Test 2: All three manifest JSONs validate against expected shape
for t in free task factory; do
  jq -e '.template_id == "'$t'" and .template_version == 1' "$SHARE_DIR/$t.json" >/dev/null || { echo "FAIL t2: $t.json template_id/version mismatch"; FAIL=1; }
  jq -e 'has("required_sections") and (.required_sections | length > 0)' "$SHARE_DIR/$t.json" >/dev/null || { echo "FAIL t2: $t.json required_sections missing/empty"; FAIL=1; }
  jq -e '.lints | has("V1") and has("V8")' "$SHARE_DIR/$t.json" >/dev/null || { echo "FAIL t2: $t.json lints.V1/V8 missing"; FAIL=1; }
done

# Test 3: factory.json has the JSON-entry sub-lints
jq -e '.lints.V7.sub_lints | has("task_state_json_entry_shape") and has("whats_next_file_ref") and has("position_branch_head")' "$SHARE_DIR/factory.json" >/dev/null || { echo "FAIL t3: factory.json missing required V7 sub-lints"; FAIL=1; }

# Test 4: V8 fires on unfilled placeholder in a rendered factory progress file
TMP=$(mktemp -d)
cp "$SHARE_DIR/factory.md" "$TMP/progress.md"  # placeholders intact
result=$(lint::v8 "$TMP/progress.md" "$SHARE_DIR/factory.json" 2>&1) && { echo "FAIL t4: V8 should fire on unfilled placeholders"; FAIL=1; }
echo "$result" | grep -qE '<<[A-Z_]+>>' || { echo "FAIL t4: V8 error should mention the unfilled tokens: $result"; FAIL=1; }
rm -rf "$TMP"

# Test 5: V1 passes on a rendered file containing the verbatim directive
TMP=$(mktemp -d)
directive=$(awk '/^## Session Directive$/{flag=1; next} /^## /{flag=0} flag' "$SHARE_DIR/free.md")
{ printf '%s\n' "## Session Directive"; printf '%s\n' "$directive"; printf '%s\n' "## What's Next"; printf '%s\n' ""; printf '%s\n' "Resume at lib/foo.sh:42"; printf '%s\n' ""; printf '%s\n' "## Constraints/Blockers"; printf '%s\n' ""; printf '%s\n' "None"; } > "$TMP/progress.md"
lint::v1 "$TMP/progress.md" "$SHARE_DIR/free.md" || { echo "FAIL t5: V1 should pass on verbatim directive"; FAIL=1; }
rm -rf "$TMP"

# Test 6: V7 absent-envelope PASSES (M4: per N5 config-loader convention, absent = v1 default).
TMP=$(mktemp -d)
cat > "$TMP/progress.md" <<'EOF'
## What's Next

Resume at lib/foo.sh:42

## Position

- Branch: main
- HEAD: abc1234

## Task State

```json
{
  "tasks_done": [{"id": "T1", "description": "this is a description of at least twenty chars"}],
  "tasks_remaining": []
}
```
EOF
lint::v7 "$TMP/progress.md" "$SHARE_DIR/factory.json" 2>&1 || { echo "FAIL t6: V7 should PASS on absent envelope (N5 default = v1)"; FAIL=1; }
rm -rf "$TMP"

# Test 6b: V7 fires on malformed-envelope (template_version non-integer)
TMP=$(mktemp -d)
cat > "$TMP/progress.md" <<'EOF'
## What's Next

Resume at lib/foo.sh:42

## Position

- Branch: main
- HEAD: abc1234

## Task State

```json
{
  "template_id": "factory",
  "template_version": "v1",
  "tasks_done": [{"id": "T1", "description": "this is a description of at least twenty chars"}],
  "tasks_remaining": []
}
```
EOF
result=$(lint::v7 "$TMP/progress.md" "$SHARE_DIR/factory.json" 2>&1) && { echo "FAIL t6b: V7 should fire on non-integer template_version"; FAIL=1; }
echo "$result" | grep -qi 'template_version\|integer' || { echo "FAIL t6b: V7 message should name the malformed field: $result"; FAIL=1; }
rm -rf "$TMP"

# Test 7: V7 task_state_json_entry_shape passes on valid envelope + valid entries
TMP=$(mktemp -d)
cat > "$TMP/progress.md" <<'EOF'
## What's Next

Resume at lib/foo.sh:42

## Position

- Branch: main
- HEAD: abc1234

## Task State

```json
{
  "template_id": "factory",
  "template_version": 1,
  "tasks_done": [{"id": "T1", "description": "this is a description of at least twenty chars"}],
  "tasks_remaining": [{"id": "T2", "description": "this is also a description of at least twenty chars"}]
}
```
EOF
lint::v7 "$TMP/progress.md" "$SHARE_DIR/factory.json" 2>&1 || { echo "FAIL t7: V7 should pass on valid envelope+entries"; FAIL=1; }
rm -rf "$TMP"

if [ "$FAIL" = "0" ]; then echo "PASS test-templates.sh"; else exit 1; fi
