#!/bin/bash
# Unit tests for installer NFS/CIFS warning (E7-T7).
# Strategy: PATH-shim `stat` to return a configurable fstype for `stat -f -c %T`;
# pass through to real stat otherwise. Run install.sh --non-interactive against
# a throwaway target, capture stderr, assert WARN behaviour.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
INSTALL_SH="$REPO_DIR/tools/install.sh"

PASSED=0
FAILED=0
FAILED_CASES=()

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASSED=$((PASSED+1)); echo "  PASS  $name"
  else
    FAILED=$((FAILED+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"
  fi
}

# Build a shim dir with a fake `stat` that returns $FAKE_FSTYPE for
# `stat -f -c %T <path>` and delegates everything else to the real stat.
make_shim_dir() {
  local fstype="$1" dir
  dir=$(mktemp -d)
  local real_stat
  real_stat=$(command -v stat)
  cat > "$dir/stat" <<EOF
#!/bin/bash
if [ "\$1" = "-f" ] && [ "\$2" = "-c" ] && [ "\$3" = "%T" ]; then
  echo "$fstype"
  exit 0
fi
exec "$real_stat" "\$@"
EOF
  chmod +x "$dir/stat"
  echo "$dir"
}

run_install() {
  local fstype="$1" target="$2" stderr_file="$3"
  local shim
  shim=$(make_shim_dir "$fstype")
  # XDG_STATE_HOME under target so the probed path lives in a real, writable dir.
  # HOME redirected so the install.sh inline-jq blocks (post-tool-batch, tool-timing)
  # land inside the throwaway target instead of polluting the developer's real
  # ~/.claude/settings.json across the 6 install invocations in this suite.
  XDG_STATE_HOME="$target/state" \
    BATON_LOGROTATE_DEST_DIR="$target/logrotate.d" \
    HOME="$target" \
    PATH="$shim:$PATH" \
    bash "$INSTALL_SH" --non-interactive --target "$target" --settings "$target/settings.json" \
      >/dev/null 2>"$stderr_file"
  local rc=$?
  rm -rf "$shim"
  return $rc
}

echo "## tools/install.sh - NFS/CIFS warning"

# Static markers.
assert "INSTALL-MARKER: E7-T7 insertion point named" \
  "grep -q 'E7-T7: NFS detection' '$INSTALL_SH'"
assert "INSTALL-DOC-LINK: docs/telemetry.md referenced" \
  "grep -q 'docs/telemetry.md' '$INSTALL_SH'"

# Scenario 1: nfs → warning printed, exit 0.
T1=$(mktemp -d); ERR1=$(mktemp); mkdir -p "$T1/state"
run_install nfs "$T1" "$ERR1"; RC1=$?
assert "NFS-WARN: exit 0 on nfs" "[ '$RC1' = '0' ]"
assert "NFS-WARN: warning text present on nfs" \
  "grep -q 'flock semantics' '$ERR1' && grep -q 'docs/telemetry.md' '$ERR1'"
assert "NFS-WARN: fstype label nfs in message" "grep -q 'nfs' '$ERR1'"
# Warning printed exactly once.
WARN_COUNT_NFS=$(grep -c '^WARN:.*flock semantics' "$ERR1" || true)
assert "NFS-WARN: warning printed exactly once on nfs" "[ '$WARN_COUNT_NFS' = '1' ]"
rm -rf "$T1" "$ERR1"

# Scenario 2: ext4 → no warning, exit 0.
T2=$(mktemp -d); ERR2=$(mktemp); mkdir -p "$T2/state"
run_install ext4 "$T2" "$ERR2"; RC2=$?
assert "EXT4-OK: exit 0 on ext4" "[ '$RC2' = '0' ]"
assert "EXT4-OK: no NFS warning on ext4" \
  "! grep -q 'flock semantics' '$ERR2'"
rm -rf "$T2" "$ERR2"

# Scenario 3: cifs → warning printed.
T3=$(mktemp -d); ERR3=$(mktemp); mkdir -p "$T3/state"
run_install cifs "$T3" "$ERR3"; RC3=$?
assert "CIFS-WARN: exit 0 on cifs" "[ '$RC3' = '0' ]"
assert "CIFS-WARN: warning text present on cifs" \
  "grep -q 'flock semantics' '$ERR3' && grep -q 'cifs' '$ERR3'"
rm -rf "$T3" "$ERR3"

# Scenario 4: re-run install - warning fires again (no suppression).
T4=$(mktemp -d); ERR4A=$(mktemp); ERR4B=$(mktemp); mkdir -p "$T4/state"
run_install nfs "$T4" "$ERR4A"; RC4A=$?
run_install nfs "$T4" "$ERR4B"; RC4B=$?
assert "RERUN: exit 0 on first run" "[ '$RC4A' = '0' ]"
assert "RERUN: exit 0 on second run" "[ '$RC4B' = '0' ]"
assert "RERUN: warning on first run" "grep -q 'flock semantics' '$ERR4A'"
assert "RERUN: warning re-fires on second run (no suppression)" \
  "grep -q 'flock semantics' '$ERR4B'"
rm -rf "$T4" "$ERR4A" "$ERR4B"

echo ""
echo "PASS $PASSED / FAIL $FAILED"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed: ${FAILED_CASES[*]}"
  exit 1
fi
exit 0
