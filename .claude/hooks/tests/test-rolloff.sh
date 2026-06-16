#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/rolloff.sh"
FAIL=0

# Test 1: archive_checkbox moves [x] items from Task State to Archived
TMP=$(mktemp -d)
cat > "$TMP/progress.md" <<'EOF'
## Task State

- [ ] T1 - pending work
- [x] T2 - completed work
- [ ] T3 - also pending
- [x] T4 - also completed

## Archived

None yet
EOF
rolloff::archive_checkbox "$TMP/progress.md" "Task State" "Archived" "[x]"
grep -q '\[x\] T2' "$TMP/progress.md" || { echo "FAIL t1: T2 should survive in file (just moved): $(cat $TMP/progress.md)"; FAIL=1; }
# T2 and T4 should be in Archived section, not Task State
task_section=$(awk '/^## Task State$/{flag=1; next} /^## /{flag=0} flag' "$TMP/progress.md")
archived_section=$(awk '/^## Archived$/{flag=1; next} /^## /{flag=0} flag' "$TMP/progress.md")
echo "$task_section" | grep -q '\[x\] T2' && { echo "FAIL t1: T2 should have moved out of Task State"; FAIL=1; }
echo "$archived_section" | grep -q '\[x\] T2' || { echo "FAIL t1: T2 should be in Archived"; FAIL=1; }
echo "$archived_section" | grep -q '\[x\] T4' || { echo "FAIL t1: T4 should be in Archived"; FAIL=1; }
# Pending items stay
echo "$task_section" | grep -q '\[ \] T1' || { echo "FAIL t1: T1 (pending) should stay in Task State"; FAIL=1; }
rm -rf "$TMP"

# Test 2: archive_dir_template substitutes {workstream} and {epoch}
TMP=$(mktemp -d)
cd "$TMP" || exit 1
template=".baton/archive/{workstream}/{epoch}/"
result=$(rolloff::_substitute_archive_path "$template" "ws-foo" "3")
expected=".baton/archive/ws-foo/3/"
[ "$result" = "$expected" ] || { echo "FAIL t2: substitution: got $result, want $expected"; FAIL=1; }
cd - >/dev/null
rm -rf "$TMP"

# Test 3: epoch-boundary triggers full prior tasks_done archive.
# Workstream record carries previous_l1_epoch=1 (set by the last successful write-trigger
# render) and current_epoch comes in as arg=2. The R4 JSON envelope has NO l1_epoch field -
# the source of truth is the workstream record.
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton/workstreams"
echo '{"workstream":"ws-1","l1_epoch":2,"previous_l1_epoch":1}' > "$TMP/.baton/workstreams/ws-1.json"
mkdir -p "$TMP/.baton/prior"
cat > "$TMP/.baton/prior/last-progress.md" <<'EOF'
## Task State

```json
{"template_id":"factory","template_version":1,"tasks_done":[{"id":"T1","description":"old work from epoch 1"}],"tasks_remaining":[]}
```
EOF
cat > "$TMP/progress.md" <<'EOF'
## Task State

```json
{"template_id":"factory","template_version":1,"tasks_done":[],"tasks_remaining":[]}
```
EOF
rolloff::fresh_judgment_archive "$TMP/progress.md" ".baton/archive/{workstream}/{epoch}/" "true" "ws-1" 2 "$TMP/.baton/prior/last-progress.md" "$TMP"
# Archive dir for prior epoch (1) should now exist with the prior tasks_done
ls "$TMP/.baton/archive/ws-1/1/" >/dev/null 2>&1 || { echo "FAIL t3: epoch-boundary archive dir for prior epoch (1) not created"; FAIL=1; }
find "$TMP/.baton/archive/ws-1/1/" -name '*.json' | head -1 | xargs grep -l 'old work from epoch 1' >/dev/null 2>&1 || { echo "FAIL t3: epoch-boundary archive should contain prior tasks_done T1"; FAIL=1; }
rm -rf "$TMP"

# Test 4: dispatch reads strategy from manifest and invokes correct function
TMP=$(mktemp -d)
cat > "$TMP/task-manifest.json" <<'EOF'
{"template_id":"task","rolloff":{"strategy":"archive-checkbox","source_section":"Task State","target_section":"Archived","trigger":"[x]"}}
EOF
cat > "$TMP/progress.md" <<'EOF'
## Task State

- [x] done item

## Archived

None
EOF
rolloff::dispatch "$TMP/progress.md" "$TMP/task-manifest.json" "ws-1"
archived_section=$(awk '/^## Archived$/{flag=1; next} /^## /{flag=0} flag' "$TMP/progress.md")
echo "$archived_section" | grep -q 'done item' || { echo "FAIL t4: dispatch should have routed to archive_checkbox"; FAIL=1; }
rm -rf "$TMP"

# Test 5: dispatch is no-op for strategy=none
TMP=$(mktemp -d)
echo '{"rolloff":{"strategy":"none"}}' > "$TMP/free-manifest.json"
echo 'unchanged content' > "$TMP/progress.md"
rolloff::dispatch "$TMP/progress.md" "$TMP/free-manifest.json" "ws-1"
grep -q '^unchanged content$' "$TMP/progress.md" || { echo "FAIL t5: strategy=none should leave file unchanged"; FAIL=1; }
rm -rf "$TMP"

# Test 6 (MAJOR-3 integration): dispatch with strategy=fresh-judgment + ROLLOFF_PRIOR_PROGRESS
# set must diff-archive entries from the prior file that aren't in the current file.
# This exercises the production wiring path (write-trigger sets the env var, dispatch reads it)
# rather than just calling fresh_judgment_archive directly.
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton/workstreams"
echo '{"workstream":"ws-1","l1_epoch":1,"previous_l1_epoch":1}' > "$TMP/.baton/workstreams/ws-1.json"
cat > "$TMP/factory-manifest.json" <<'EOF'
{"template_id":"factory","rolloff":{"strategy":"fresh-judgment","archive_dir_template":".baton/archive/{workstream}/{epoch}/","epoch_boundary_full_archive":true}}
EOF
cat > "$TMP/prior.md" <<'EOF'
## Task State

```json
{"template_id":"factory","template_version":1,"tasks_done":[{"id":"T1","description":"prior work that drops from tasks_done"},{"id":"T2","description":"prior work that survives to current"}],"tasks_remaining":[]}
```
EOF
cat > "$TMP/progress.md" <<'EOF'
## Task State

```json
{"template_id":"factory","template_version":1,"tasks_done":[{"id":"T2","description":"prior work that survives to current"}],"tasks_remaining":[]}
```
EOF
ROLLOFF_PRIOR_PROGRESS="$TMP/prior.md" rolloff::dispatch "$TMP/progress.md" "$TMP/factory-manifest.json" "ws-1" "$TMP"
# Diff-archive (not boundary): T1 dropped from tasks_done, T2 carried - T1 should be in the archive dir under current epoch.
ls "$TMP/.baton/archive/ws-1/1/" >/dev/null 2>&1 || { echo "FAIL t6: diff-archive dir not created under current epoch"; FAIL=1; }
find "$TMP/.baton/archive/ws-1/1/" -name 'tasks-done-rollover-*.json' | head -1 | xargs grep -l '"T1"' >/dev/null 2>&1 || { echo "FAIL t6: dropped T1 entry should be in diff-archive"; FAIL=1; }
rm -rf "$TMP"

# Test 7 (m5): rolloff::dispatch persists previous_l1_epoch on the workstream record after
# dispatch. The persist is co-located with the epoch-read site so the snapshot lives in
# one lib instead of split-brain between trigger + dispatcher.
TMP=$(mktemp -d)
mkdir -p "$TMP/.baton/workstreams"
echo '{"workstream":"ws-1","l1_epoch":3}' > "$TMP/.baton/workstreams/ws-1.json"
echo '{"rolloff":{"strategy":"none"}}' > "$TMP/free-manifest.json"
echo 'irrelevant' > "$TMP/progress.md"
rolloff::dispatch "$TMP/progress.md" "$TMP/free-manifest.json" "ws-1" "$TMP"
actual=$(jq -r '.previous_l1_epoch' "$TMP/.baton/workstreams/ws-1.json")
[ "$actual" = "3" ] || { echo "FAIL t7: dispatch should persist previous_l1_epoch=3 (got $actual)"; FAIL=1; }
rm -rf "$TMP"

# Test 8: BATON_DIR override - dispatch reads workstream record from custom tracking dir
TMP=$(mktemp -d)
CUSTOM_TRACKING="$TMP/custom-tracking"
mkdir -p "$CUSTOM_TRACKING/workstreams"
echo '{"workstream":"ws-1","l1_epoch":2}' > "$CUSTOM_TRACKING/workstreams/ws-1.json"
echo '{"rolloff":{"strategy":"none"}}' > "$TMP/free-manifest.json"
echo 'irrelevant' > "$TMP/progress.md"
BATON_DIR="$CUSTOM_TRACKING" rolloff::dispatch "$TMP/progress.md" "$TMP/free-manifest.json" "ws-1" "$TMP"
# previous_l1_epoch should be persisted to the CUSTOM_TRACKING workstream record, not .baton
actual=$(jq -r '.previous_l1_epoch' "$CUSTOM_TRACKING/workstreams/ws-1.json")
[ "$actual" = "2" ] || { echo "FAIL t8: BATON_DIR override: previous_l1_epoch not persisted to custom dir (got $actual)"; FAIL=1; }
[ ! -d "$TMP/.baton" ] || { echo "FAIL t8: BATON_DIR override should not write to default .baton dir"; FAIL=1; }
unset BATON_DIR
rm -rf "$TMP"

if [ "$FAIL" = "0" ]; then echo "PASS test-rolloff.sh"; else exit 1; fi
