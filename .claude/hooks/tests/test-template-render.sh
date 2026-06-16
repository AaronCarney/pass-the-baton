#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/template-render.sh"
FAIL=0

# Test 1: substitutes <<BRANCH>>, <<HEAD_SHA>>, <<WORKSPACE_PATH>>, <<WORKSTREAM_ID>>
TMP=$(mktemp -d)
git -C "$TMP" init -q
git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
git -C "$TMP" checkout -q -b feature-x

cat > "$TMP/template.md" <<'EOF'
## Position
- Workspace: `<<WORKSPACE_PATH>>`
- Branch: `<<BRANCH>>`
- HEAD: `<<HEAD_SHA>>`
- Workstream: `<<WORKSTREAM_ID>>`
EOF

mkdir -p "$TMP/.baton/workstreams"
cat > "$TMP/.baton/workstreams/ws-1.json" <<'EOF'
{"workstream": "ws-1", "display_name": "my proj", "phase": "implementation"}
EOF

out=$(tpl::render_progress_file "$TMP/template.md" "ws-1" "$TMP")
echo "$out" | grep -q 'Branch: `feature-x`' || { echo "FAIL t1: BRANCH not substituted: $out"; FAIL=1; }
echo "$out" | grep -qE 'HEAD: `[a-f0-9]{7,}`' || { echo "FAIL t1: HEAD_SHA not substituted: $out"; FAIL=1; }
echo "$out" | grep -q "Workspace: \`$TMP\`" || { echo "FAIL t1: WORKSPACE_PATH not substituted: $out"; FAIL=1; }
echo "$out" | grep -q 'Workstream: `ws-1`' || { echo "FAIL t1: WORKSTREAM_ID not substituted: $out"; FAIL=1; }
rm -rf "$TMP"

# Test 2: leaves MODEL-AUTHORED placeholders untouched
TMP=$(mktemp -d)
git -C "$TMP" init -q
git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
cat > "$TMP/template.md" <<'EOF'
## What's Next
<<WHATS_NEXT>>
## Position
- Branch: `<<BRANCH>>`
EOF
mkdir -p "$TMP/.baton/workstreams"
echo '{"workstream":"ws-1"}' > "$TMP/.baton/workstreams/ws-1.json"
out=$(tpl::render_progress_file "$TMP/template.md" "ws-1" "$TMP")
echo "$out" | grep -q '<<WHATS_NEXT>>' || { echo "FAIL t2: model-authored placeholder should be preserved: $out"; FAIL=1; }
echo "$out" | grep -qv '<<BRANCH>>' || { echo "FAIL t2: hook-filled BRANCH should be substituted"; FAIL=1; }
rm -rf "$TMP"

# Test 3: Git log and status substituted
TMP=$(mktemp -d)
git -C "$TMP" init -q
git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "first commit"
cat > "$TMP/template.md" <<'EOF'
## Git State
```
$ git log --oneline -10
<<GIT_LOG>>

$ git status -s
<<GIT_STATUS>>
```
EOF
mkdir -p "$TMP/.baton/workstreams"
echo '{"workstream":"ws-1"}' > "$TMP/.baton/workstreams/ws-1.json"
out=$(tpl::render_progress_file "$TMP/template.md" "ws-1" "$TMP")
echo "$out" | grep -q 'first commit' || { echo "FAIL t3: GIT_LOG not substituted: $out"; FAIL=1; }
rm -rf "$TMP"

# Test 4: <<ARCHIVED_CHECKBOXES>> substituted to literal "None yet" on first checkpoint
# (no prior progress file). Avoids leaving an unfilled placeholder for V8 to reject.
TMP=$(mktemp -d)
git -C "$TMP" init -q
git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
cat > "$TMP/template.md" <<'EOF'
## Archived

<<ARCHIVED_CHECKBOXES>>
EOF
mkdir -p "$TMP/.baton/workstreams"
echo '{"workstream":"ws-1"}' > "$TMP/.baton/workstreams/ws-1.json"
out=$(tpl::render_progress_file "$TMP/template.md" "ws-1" "$TMP")
echo "$out" | grep -qv '<<ARCHIVED_CHECKBOXES>>' || { echo "FAIL t4: ARCHIVED_CHECKBOXES placeholder should be substituted, not survive: $out"; FAIL=1; }
echo "$out" | grep -q 'None yet' || { echo "FAIL t4: ARCHIVED_CHECKBOXES on first checkpoint should be 'None yet': $out"; FAIL=1; }
rm -rf "$TMP"

# Test 5: <<ARCHIVED_CHECKBOXES>> substituted from prior file's ## Archived section body when one exists.
TMP=$(mktemp -d)
git -C "$TMP" init -q
git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
cat > "$TMP/template.md" <<'EOF'
## Archived

<<ARCHIVED_CHECKBOXES>>
EOF
mkdir -p "$TMP/.baton/workstreams"
echo '{"workstream":"ws-1"}' > "$TMP/.baton/workstreams/ws-1.json"
cat > "$TMP/prior-progress.md" <<'EOF'
## Archived

- [x] T1 - earlier work
- [x] T2 - more earlier work

## Constraints/Blockers

None
EOF
ROLLOFF_PRIOR_PROGRESS="$TMP/prior-progress.md" out=$(tpl::render_progress_file "$TMP/template.md" "ws-1" "$TMP")
echo "$out" | grep -q '\[x\] T1 - earlier work' || { echo "FAIL t5: should carry prior archived items: $out"; FAIL=1; }
echo "$out" | grep -q '<<ARCHIVED_CHECKBOXES>>' && { echo "FAIL t5: placeholder should be substituted: $out"; FAIL=1; }
rm -rf "$TMP"

# Test 6: BATON_DIR override - workstream record is read from custom tracking dir
TMP=$(mktemp -d)
CUSTOM_TRACKING="$TMP/custom-tracking"
git -C "$TMP" init -q
git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
cat > "$TMP/template.md" <<'EOF'
## Position
- Workstream: `<<WORKSTREAM_ID>>`
- Display: `<<DISPLAY_NAME>>`
EOF
mkdir -p "$CUSTOM_TRACKING/workstreams"
cat > "$CUSTOM_TRACKING/workstreams/ws-custom.json" <<'EOF'
{"workstream": "ws-custom", "display_name": "custom-display", "phase": "planning"}
EOF
BATON_DIR="$CUSTOM_TRACKING" out=$(tpl::render_progress_file "$TMP/template.md" "ws-custom" "$TMP")
echo "$out" | grep -q 'Workstream: `ws-custom`' || { echo "FAIL t6: BATON_DIR override: WORKSTREAM_ID not found: $out"; FAIL=1; }
echo "$out" | grep -q 'Display: `custom-display`' || { echo "FAIL t6: BATON_DIR override: DISPLAY_NAME not from custom tracking: $out"; FAIL=1; }
# Verify fallback dir (.baton) does NOT exist - only custom one was created
[ ! -d "$TMP/.baton" ] || { echo "FAIL t6: BATON_DIR override should not create .baton default dir"; FAIL=1; }
unset BATON_DIR
rm -rf "$TMP"

if [ "$FAIL" = "0" ]; then echo "PASS test-template-render.sh"; else exit 1; fi
