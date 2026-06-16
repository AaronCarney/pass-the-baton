#!/bin/bash
# Tests for the lint pipeline applied to rendered progress files.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/lints.sh"

FAIL=0
TMP=$(mktemp -d)

# Setup a minimal free.md template + manifest in TMP
mkdir -p "$TMP/templates"
cat > "$TMP/templates/free.md" <<'EOF'
## Session Directive
> **MANDATORY:** Copy this directive forward verbatim when you write the next checkpoint.
>
> **Your assignment:** the What's Next section is your literal task list.

## What's Next

<<WHATS_NEXT>>

## Constraints/Blockers

<<CONSTRAINTS_BLOCKERS>>
EOF

cat > "$TMP/templates/free.json" <<'EOF'
{
  "template_id": "free",
  "template_version": 1,
  "required_sections": ["Session Directive", "What's Next", "Constraints/Blockers"],
  "lints": {"V1": {"enabled": true, "target": "Session Directive"}, "V7": {"enabled": false}, "V8": {"enabled": true, "pattern": "<<[A-Z_]+>>"}}
}
EOF

# Test 1: V8 fires on unfilled placeholder
cat > "$TMP/progress-bad-placeholder.md" <<'EOF'
## Session Directive
> **MANDATORY:** Copy this directive forward verbatim when you write the next checkpoint.
>
> **Your assignment:** the What's Next section is your literal task list.

## What's Next

<<WHATS_NEXT>>

## Constraints/Blockers

None
EOF
result=$(lint::v8 "$TMP/progress-bad-placeholder.md" "$TMP/templates/free.json" 2>&1) || true
echo "$result" | grep -q '<<WHATS_NEXT>>' || { echo "FAIL t1: V8 should report unfilled placeholder: $result"; FAIL=1; }

# Test 2: V8 passes when no placeholders remain
cat > "$TMP/progress-clean.md" <<'EOF'
## Session Directive
> **MANDATORY:** Copy this directive forward verbatim when you write the next checkpoint.
>
> **Your assignment:** the What's Next section is your literal task list.

## What's Next

Resume work on lib/foo.sh:42

## Constraints/Blockers

None
EOF
lint::v8 "$TMP/progress-clean.md" "$TMP/templates/free.json" >/dev/null 2>&1 || { echo "FAIL t2: V8 should pass on clean file"; FAIL=1; }

# Test 3: V1 fires on directive drift (paraphrased)
cat > "$TMP/progress-drift.md" <<'EOF'
## Session Directive
> Mandatory: copy this forward.
>
> Your assignment is the What's Next section.

## What's Next

Resume work on lib/foo.sh:42

## Constraints/Blockers

None
EOF
result=$(lint::v1 "$TMP/progress-drift.md" "$TMP/templates/free.md" 2>&1) || true
echo "$result" | grep -qi 'directive' || { echo "FAIL t3: V1 should report directive drift: $result"; FAIL=1; }

# Test 4: V1 passes on verbatim directive
lint::v1 "$TMP/progress-clean.md" "$TMP/templates/free.md" >/dev/null 2>&1 || { echo "FAIL t4: V1 should pass on verbatim copy"; FAIL=1; }

# Test 5: V7 sub-lint enforces ≥1 file:line in What's Next (factory-style)
cat > "$TMP/templates/factory.json" <<'EOF'
{
  "template_id": "factory",
  "template_version": 1,
  "lints": {"V7": {"enabled": true, "sub_lints": {"whats_next_file_ref": {"section": "What's Next", "pattern": "[A-Za-z0-9_/.-]+:[0-9]+", "min_matches": 1}}}, "V1": {"enabled": false}, "V8": {"enabled": false}}
}
EOF
cat > "$TMP/progress-vague.md" <<'EOF'
## What's Next

Continue the refactor.

EOF
result=$(lint::v7 "$TMP/progress-vague.md" "$TMP/templates/factory.json" 2>&1) || true
echo "$result" | grep -qi 'file.*line' || { echo "FAIL t5: V7 should report missing file:line reference: $result"; FAIL=1; }

# Test 6: V7 passes when file:line present
cat > "$TMP/progress-specific.md" <<'EOF'
## What's Next

Resume at lib/foo.sh:42 and finalize the auth refactor.
EOF
lint::v7 "$TMP/progress-specific.md" "$TMP/templates/factory.json" >/dev/null 2>&1 || { echo "FAIL t6: V7 should pass when file:line present"; FAIL=1; }

# Test 7: Bad-faith-resistant message - names the property, not the field name
result=$(lint::v7 "$TMP/progress-vague.md" "$TMP/templates/factory.json" 2>&1) || true
echo "$result" | grep -qi 'whats_next_file_ref' && { echo "FAIL t7: lint message must NOT name the lint field; should describe the property"; FAIL=1; }
echo "$result" | grep -qi 'specific.*file\|file.*specific\|concrete' || { echo "FAIL t7: lint message should describe the underlying property required"; FAIL=1; }

# Test 8: V8 ignores placeholder syntax inside HTML instructional comments.
# Regression for the template-comment false-positive - instructional comments
# referencing the <<UPPER_CASE>> convention must not trip V8 when copied forward.
cat > "$TMP/progress-with-comment.md" <<'EOF'
<!--
Placeholder convention:
  <<UPPER_CASE>>     - gets substituted at write time.
  V8 lint rejects any progress file containing an unfilled <<...>> placeholder.
-->

## Session Directive
> **MANDATORY:** Copy this directive forward verbatim when you write the next checkpoint.
>
> **Your assignment:** the What's Next section is your literal task list.

## What's Next

Resume work on lib/foo.sh:42

## Constraints/Blockers

None
EOF
lint::v8 "$TMP/progress-with-comment.md" "$TMP/templates/free.json" >/dev/null 2>&1 || { echo "FAIL t8: V8 must skip placeholder syntax inside HTML comments"; FAIL=1; }

# Test 9: V8 still fires on REAL body placeholders even when comments are also
# present. Hardening must not weaken the check on actual unfilled tokens.
cat > "$TMP/progress-comment-and-real.md" <<'EOF'
<!--
Placeholder convention: <<UPPER_CASE>> - gets substituted at write time.
-->

## What's Next

<<WHATS_NEXT>>
EOF
result=$(lint::v8 "$TMP/progress-comment-and-real.md" "$TMP/templates/free.json" 2>&1) || true
echo "$result" | grep -q '<<WHATS_NEXT>>' || { echo "FAIL t9: V8 must still report unfilled body placeholders when HTML comments are present: $result"; FAIL=1; }
# Tokens list is the line(s) immediately after the "still contains" header, before the blank line.
reported_tokens=$(echo "$result" | awk '/still contains unfilled placeholder tokens:/{flag=1; next} /^$/{flag=0} flag')
echo "$reported_tokens" | grep -q '<<UPPER_CASE>>' && { echo "FAIL t9: V8 must NOT list comment-only tokens in the rejected-tokens list: [$reported_tokens]"; FAIL=1; }

rm -rf "$TMP"
if [ "$FAIL" = "0" ]; then echo "PASS test-lints.sh"; else exit 1; fi
