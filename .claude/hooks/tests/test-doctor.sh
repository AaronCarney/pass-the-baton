#!/bin/bash
# Unit tests for tools/doctor.sh (E7-T6).
# Mocks `stat` via a PATH-prepended shim so FS-type detection is testable without root.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
DOCTOR="$REPO_DIR/tools/doctor.sh"

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

# Build a `stat` shim. If invoked with `-f -c %T <path>` returns FAKE_FSTYPE.
# Otherwise delegates to the real /usr/bin/stat so mode/parent-dir checks still work.
make_stat_shim() {
  local dir="$1" fstype="$2"
  mkdir -p "$dir"
  cat >"$dir/stat" <<EOF
#!/bin/bash
if [ "\$1" = "-f" ] && [ "\$2" = "-c" ] && [ "\$3" = "%T" ]; then
  echo "$fstype"
  exit 0
fi
exec /usr/bin/stat "\$@"
EOF
  chmod +x "$dir/stat"
}

# Builds a `crontab` shim on PATH. $body is the heredoc'd output for `crontab -l`.
make_crontab_shim() {
  local dir="$1" body="$2"
  mkdir -p "$dir"
  cat >"$dir/crontab" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-l" ]; then
$body
  exit 0
fi
EOF
  chmod +x "$dir/crontab"
}

# Neutralizes the E19 backstop checks for FS/log-focused cases: wires a crontab
# with the cleanup-cron-wrapper line and a settings.json carrying the statusLine
# shim, so those benign cases keep their exit-0 expectation. Caller passes the
# settings path via BATON_DOCTOR_SETTINGS when invoking doctor.
wire_backstops() {
  local shim="$1" settings="$2"
  make_crontab_shim "$shim" "  echo '0 3 */2 * * bash /home/test/baton/tools/cleanup-cron-wrapper.sh'"
  printf '{"statusLine":{"command":"bash /home/test/baton/assets/baton-pct.sh $SESSION_ID"}}\n' > "$settings"
}

echo "## tools/doctor.sh"

# --- FS-type: tmpfs (benign) → exit 0, no NFS warning ----------------------
run_fs_tmpfs_ok() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "tmpfs"
  local log="$d/missing.jsonl"  # missing log is fine
  local settings="$d/settings.json"; wire_backstops "$shim" "$settings"
  local out
  out=$(BATON_EVENT_LOG="$log" BATON_DOCTOR_SETTINGS="$settings" \
    PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  local rc=$?
  assert "FS-TMPFS: exit 0 on tmpfs" "[ $rc -eq 0 ]"
  assert "FS-TMPFS: no NFS warning emitted" \
    "! echo \"\$out\" | grep -qE 'flock semantics may be unreliable'"
  unset out
  rm -rf "$d"
}
run_fs_tmpfs_ok

# --- FS-type: nfs → warn + exit 1 ------------------------------------------
run_fs_nfs_warn() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "nfs"
  local log="$d/log.jsonl"
  local out
  out=$(BATON_EVENT_LOG="$log" PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  local rc=$?
  assert "FS-NFS: warns about flock semantics" \
    "echo \"\$out\" | grep -qE 'WARN:.*nfs.*flock semantics may be unreliable'"
  assert "FS-NFS: references docs/telemetry.md" \
    "echo \"\$out\" | grep -qE 'docs/telemetry.md'"
  assert "FS-NFS: exit 1 when warning fires" "[ $rc -eq 1 ]"
  rm -rf "$d"
}
run_fs_nfs_warn

# --- FS-type: cifs → warn --------------------------------------------------
run_fs_cifs_warn() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "cifs"
  local out
  out=$(BATON_EVENT_LOG="$d/log.jsonl" PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  local rc=$?
  assert "FS-CIFS: warns about flock semantics" \
    "echo \"\$out\" | grep -qE 'WARN:.*cifs.*flock semantics may be unreliable'"
  assert "FS-CIFS: exit 1" "[ $rc -eq 1 ]"
  rm -rf "$d"
}
run_fs_cifs_warn

# --- FS-type: smbfs → warn -------------------------------------------------
run_fs_smbfs_warn() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "smbfs"
  local out
  out=$(BATON_EVENT_LOG="$d/log.jsonl" PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  local rc=$?
  assert "FS-SMBFS: warns about flock semantics" \
    "echo \"\$out\" | grep -qE 'WARN:.*smbfs.*flock semantics may be unreliable'"
  assert "FS-SMBFS: exit 1" "[ $rc -eq 1 ]"
  rm -rf "$d"
}
run_fs_smbfs_warn

# --- Missing log file: "no log yet", exit 0 --------------------------------
run_missing_log() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "tmpfs"
  local log="$d/nope.jsonl"
  local settings="$d/settings.json"; wire_backstops "$shim" "$settings"
  local out
  out=$(BATON_EVENT_LOG="$log" BATON_DOCTOR_SETTINGS="$settings" \
    PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  local rc=$?
  assert "MISSING-LOG: reports 'no log yet'" \
    "echo \"\$out\" | grep -qi 'no log yet'"
  assert "MISSING-LOG: exit 0 (no warnings)" "[ $rc -eq 0 ]"
  rm -rf "$d"
}
run_missing_log

# --- Log mode 0644 → warn --------------------------------------------------
run_mode_0644_warn() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "tmpfs"
  local log="$d/log.jsonl"
  : > "$log"; chmod 0644 "$log"
  local out
  out=$(BATON_EVENT_LOG="$log" PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  local rc=$?
  assert "MODE-0644: warns with 'expected 600'" \
    "echo \"\$out\" | grep -qE 'WARN:.*log mode.*644.*expected 600'"
  assert "MODE-0644: exit 1" "[ $rc -eq 1 ]"
  rm -rf "$d"
}
run_mode_0644_warn

# --- Log mode 0600 → no warning --------------------------------------------
run_mode_0600_ok() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "tmpfs"
  local log="$d/log.jsonl"
  : > "$log"; chmod 0600 "$log"
  local settings="$d/settings.json"; wire_backstops "$shim" "$settings"
  local out
  out=$(BATON_EVENT_LOG="$log" BATON_DOCTOR_SETTINGS="$settings" \
    PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  local rc=$?
  assert "MODE-0600: no mode warning" \
    "! echo \"\$out\" | grep -qE 'WARN:.*log mode'"
  assert "MODE-0600: exit 0" "[ $rc -eq 0 ]"
  rm -rf "$d"
}
run_mode_0600_ok

# --- Resolution: prints resolved absolute log path -------------------------
run_prints_resolved_path() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "tmpfs"
  local log="$d/log.jsonl"
  local out
  out=$(BATON_EVENT_LOG="$log" PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  assert "RESOLVE: prints the resolved log path" \
    "echo \"\$out\" | grep -qF '$log'"
  assert "RESOLVE: prints a summary line" \
    "echo \"\$out\" | grep -qiE '^(summary|doctor):'"
  rm -rf "$d"
}
run_prints_resolved_path

# --- E19 T8: crontab backstop check ----------------------------------------
run_crontab_missing_warn() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "tmpfs"
  make_crontab_shim "$shim" "  echo '# user crontab without baton'
  echo '0 0 * * * /usr/bin/some-other-job'"
  local out rc
  out=$(BATON_EVENT_LOG="$d/nope.jsonl" PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  rc=$?
  assert "CRON-MISSING: warns wrapper missing" \
    "echo \"\$out\" | grep -qE 'cleanup-cron-wrapper.*(missing|not found)'"
  assert "CRON-MISSING: exit 1 (WARN)" "[ $rc -ne 0 ]"
  rm -rf "$d"
}
run_crontab_missing_warn

run_crontab_present_ok() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "tmpfs"
  make_crontab_shim "$shim" "  echo '0 3 */2 * * bash /home/test/baton/tools/cleanup-cron-wrapper.sh'"
  local out
  out=$(BATON_EVENT_LOG="$d/nope.jsonl" PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  assert "CRON-PRESENT: no wrapper-missing warning" \
    "! echo \"\$out\" | grep -qE 'cleanup-cron-wrapper.*missing'"
  rm -rf "$d"
}
run_crontab_present_ok

run_crontab_unavailable_skipped() {
  local d; d=$(mktemp -d)
  # PATH with only the stat shim (no crontab) - but doctor needs jq/date/stat.
  # Provide a minimal real toolset by symlinking into shim dir, then omit crontab.
  local shim="$d/bin"; mkdir -p "$shim"
  make_stat_shim "$shim" "tmpfs"
  for t in bash jq date dirname grep awk cat printf env sh; do
    p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$shim/$t" 2>/dev/null || true
  done
  local out
  out=$(BATON_EVENT_LOG="$d/nope.jsonl" PATH="$shim" bash "$DOCTOR" 2>&1)
  assert "CRON-UNAVAIL: reports crontab not available" \
    "echo \"\$out\" | grep -qF 'crontab not available'"
  assert "CRON-UNAVAIL: no wrapper-missing warning" \
    "! echo \"\$out\" | grep -qE 'cleanup-cron-wrapper.*missing'"
  rm -rf "$d"
}
run_crontab_unavailable_skipped

# --- E19 T8: statusline shim backstop check --------------------------------
run_statusline_missing_warn() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "tmpfs"
  local settings="$d/settings.json"
  printf '{"someKey":"value"}\n' > "$settings"
  local out
  out=$(BATON_EVENT_LOG="$d/nope.jsonl" BATON_DOCTOR_SETTINGS="$settings" \
    PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  assert "STATUSLINE-MISSING: warns shim missing" \
    "echo \"\$out\" | grep -qE '(baton-pct.sh.*missing|statusLine.*missing|does not reference baton-pct.sh)'"
  rm -rf "$d"
}
run_statusline_missing_warn

run_statusline_malformed_warn() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "tmpfs"
  local settings="$d/settings.json"
  printf 'not json at all {{{' > "$settings"
  local out rc
  out=$(BATON_EVENT_LOG="$d/nope.jsonl" BATON_DOCTOR_SETTINGS="$settings" \
    PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  rc=$?
  # Explicit not-valid-JSON diagnostic.
  assert "STATUSLINE-MALFORMED: emits not-valid-JSON WARN" \
    "echo \"\$out\" | grep -qF 'not valid JSON'"
  # Survival: doctor reached the summary line, did not abort.
  assert "STATUSLINE-MALFORMED: reached doctor summary" \
    "echo \"\$out\" | grep -qE '^(summary|doctor):'"
  assert "STATUSLINE-MALFORMED: exit 1 (WARN)" "[ $rc -ne 0 ]"
  rm -rf "$d"
}
run_statusline_malformed_warn

run_statusline_present_ok() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; make_stat_shim "$shim" "tmpfs"
  local settings="$d/settings.json"
  printf '{"statusLine":{"command":"bash /home/test/baton/assets/baton-pct.sh $SESSION_ID"}}\n' > "$settings"
  local out
  out=$(BATON_EVENT_LOG="$d/nope.jsonl" BATON_DOCTOR_SETTINGS="$settings" \
    PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  assert "STATUSLINE-PRESENT: no shim-missing warning" \
    "! echo \"\$out\" | grep -qE 'baton-pct.sh.*missing|does not reference baton-pct.sh'"
  rm -rf "$d"
}
run_statusline_present_ok

echo ""
echo "====================================="
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
