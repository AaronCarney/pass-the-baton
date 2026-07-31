#!/usr/bin/env bash
# tools/release-gates.sh must decide the release gates by EXIT CODE, not by
# printing something a reader compares against prose. Every gate in this suite
# is exercised twice: once against a well-formed tree that must pass, and once
# against a tree broken in exactly one way that must fail. A gate that cannot
# be made to fail here is not a gate.
#
# Every negative case asserts BOTH the exit code and the gate NAME on stdout.
# The name assertion is not redundant: a broken tree usually trips more than
# one gate, so a bare exit-code check still passes when the gate under test has
# been deleted outright. The content-coverage cases assert the uncovered AREA
# as well, because the gate has four arms and the gate name alone cannot say
# which one fired.
#
# Mutation-tested at ARM granularity, not gate granularity. An earlier version
# of this suite was green while eight single-arm mutants survived: each of the
# four coverage arms, the bullet floor, gate 4's [Unreleased] arm and both of
# gate 3's mid-file awk branches could be deleted outright without turning it
# red, because good_tree carried exactly the floor's worth of bullets and every
# arm fixture therefore tripped the floor as well.
#
# A later sweep found three more survivors, now pinned by G43, G44 and G45:
# gate 4's `IN_REL -eq 0` half, gate 8's repeat-version arm, and gate 5's
# `settings-channel` alternative. Each was deletable from the shipped script
# with this suite fully green. The pattern in all three: the arm's own fixture
# was ALSO caught by a neighbouring arm, so the neighbour was doing the killing.
# A new fixture earns its place only if the arm it targets is the single term
# that can decide it.
#
# The bullet floor is pinned from BOTH sides. G9 sits exactly ON seven and
# asserts PASS bullet-floor; G28 sits one below it, with all four coverage
# areas still satisfied, and asserts FAIL bullet-floor. Either half alone
# leaves the floor's VALUE free to drift: measured against the earlier suite,
# both `-ge 6` and `-ge 9` survived it fully green. A floor drifting down stops
# requiring the three mandated items no coverage arm matches; a floor drifting
# up rejects a correctly authored seven-bullet release. Task 3 step 3 runs the
# gate script against archived HEAD before the overlay, so on the normal path
# that rejection stops the release before anything goes live; the residual is a
# change landing between that run and task 5 step 2.
#
# Usage: bash .claude/hooks/tests/test-release-gates.sh
set -u
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
GATES="$REPO/tools/release-gates.sh"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- fixture builders -------------------------------------------------
# good_tree <dir> writes a tree that must pass every gate.
#
# Its [0.5.1] section carries eleven bullets against a floor of seven. That
# margin is structural, not decorative: every coverage-arm fixture below is
# built by deleting the bullets that satisfy one arm, and without the margin
# each of those deletions would drop the section below the floor too, so the
# fixture would go red whether the arm existed or not.
#
# The section deliberately separates E5's retention vocabulary from the moved
# checkpoint write-path bullet. The write-path bullet carries "progress-file"
# and "timestamp"; a retention arm keyed to those generic words was satisfied
# by that bullet alone, so a release section with no E5 content passed.
good_tree(){
  local d=$1
  mkdir -p "$d/.claude-plugin"
  printf '{\n  "name": "pass-the-baton",\n  "version": "0.5.1"\n}\n' > "$d/.claude-plugin/plugin.json"
  cat > "$d/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Fixed
- Code alignment is still pending for the checkpoint-mode documentation.
- An unrelated item that stays behind in this release.

## [0.5.1] - 2026-07-28

### Fixed
- Commands now reach the settings-channel install.
- A partial install fails loudly instead of reporting success.
- Every checkpoint now writes to a fresh progress-file path carrying a timestamp.
- Archived progress files carry exactly one timestamp instead of a doubled pair.

### Added
- The dashboard TUI mode is documented and findable.
- The dashboard docs carry a drift guard against the scripts.
- The progress archive is pruned on a two-tier retention rule.
- Aged progress files sweep into a cold tier under progress-cold.
- BATON_PROGRESS_COLD_DAYS is registered on the config surface.

### Documentation
- The checkpoint progress templates require an attribution marker.
- The manual and automated checkpoint modes are defined correctly.

## [0.5.0] - 2026-07-25

### Added
- Subagent drain gate.
EOF
}

# meta_tree <dir> writes the same well-formed tree at a version carrying an ERE
# metacharacter. `1.0.0+build` is valid semver and `+` is the case that matters:
# spliced raw into a dynamic awk regex it stops matching the literal heading, so
# the release section derives EMPTY and every gate that reads it reports on a
# range it never located.
meta_tree(){
  local d=$1
  good_tree "$d"
  sed -i 's/0\.5\.1/1.0.0+build/g' "$d/.claude-plugin/plugin.json" "$d/CHANGELOG.md"
}

# drop <dir> <regex...> deletes whole bullets from a fixture's CHANGELOG.
drop(){
  local d=$1; shift
  local p
  for p in "$@"; do sed -i "/$p/d" "$d/CHANGELOG.md"; done
}

# ---- G1: a well-formed tree passes ------------------------------------
good_tree "$TMP/good"
bash "$GATES" --repo "$TMP/good" --version 0.5.1 >/dev/null 2>&1
ok "G1: a well-formed tree exits 0" "[ $? -eq 0 ]"
bash "$GATES" --repo "$TMP/good" --version 0.5.1 2>&1 | grep -q '^RESULT PASS'
ok "G1: and prints the RESULT PASS verdict line" "[ $? -eq 0 ]"

# ---- G2: manifest version mismatch fails ------------------------------
good_tree "$TMP/badver"
printf '{\n  "name": "pass-the-baton",\n  "version": "0.5.0"\n}\n' > "$TMP/badver/.claude-plugin/plugin.json"
bash "$GATES" --repo "$TMP/badver" --version 0.5.1 >/dev/null 2>&1
ok "G2: a manifest still reading 0.5.0 exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/badver" --version 0.5.1 2>&1 | grep -q '^FAIL manifest-version'
ok "G2: and names the manifest-version gate" "[ $? -eq 0 ]"
# The verdict line is what task 5 step 2 asserts on and what `contracts[5]`
# declares, and no case used to grep for it: replacing the whole RESULT line
# with `:` left the suite fully green (measured).
bash "$GATES" --repo "$TMP/badver" --version 0.5.1 2>&1 | grep -q '^RESULT FAIL'
ok "G2: and prints the RESULT FAIL verdict line" "[ $? -eq 0 ]"

# ---- G3: an empty subheading at end of file fails ---------------------
# Reaches gate 3's END branch: nothing follows the empty subheading.
good_tree "$TMP/emptysub"
printf '\n### Removed\n' >> "$TMP/emptysub/CHANGELOG.md"
bash "$GATES" --repo "$TMP/emptysub" --version 0.5.1 >/dev/null 2>&1
ok "G3: a subheading with no bullets exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/emptysub" --version 0.5.1 2>&1 | grep -q '^FAIL empty-subheading'
ok "G3: and names the empty-subheading gate" "[ $? -eq 0 ]"

# ---- G4: the pending note folded into the release fails ----------------
good_tree "$TMP/folded"
sed -i 's/^- Code alignment is still pending.*$/- Nothing pending./' "$TMP/folded/CHANGELOG.md"
sed -i '/^## \[0\.5\.1\] - 2026-07-28$/a\
### Fixed\n- Code alignment is still pending for the checkpoint-mode documentation.' "$TMP/folded/CHANGELOG.md"
bash "$GATES" --repo "$TMP/folded" --version 0.5.1 >/dev/null 2>&1
ok "G4: the pending note inside the release exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/folded" --version 0.5.1 2>&1 | grep -q '^FAIL pending-note'
ok "G4: and names the pending-note gate" "[ $? -eq 0 ]"

# ---- G5: heading order, release arm -----------------------------------
good_tree "$TMP/order"
sed -i 's/^## \[0\.5\.1\] - 2026-07-28$/## [0.5.2] - 2026-07-28/' "$TMP/order/CHANGELOG.md"
bash "$GATES" --repo "$TMP/order" --version 0.5.1 >/dev/null 2>&1
ok "G5: a release heading that is not the target version exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/order" --version 0.5.1 2>&1 | grep -q '^FAIL heading-order'
ok "G5: and names the heading-order gate" "[ $? -eq 0 ]"

# ---- G6: content coverage, retention arm (f32) ------------------------
# The independent mechanical assertion: the release section must carry at
# least one bullet for each of the four areas this release ships. Drop the
# retention bullets and it must fail - and with the margin above the floor it
# can only fail for that reason.
good_tree "$TMP/thin"
drop "$TMP/thin" '^- The progress archive is pruned on a two-tier retention rule\.$' \
                 '^- Aged progress files sweep into a cold tier under progress-cold\.$' \
                 '^- BATON_PROGRESS_COLD_DAYS is registered on the config surface\.$'
bash "$GATES" --repo "$TMP/thin" --version 0.5.1 >/dev/null 2>&1
ok "G6: a release section with no retention coverage exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/thin" --version 0.5.1 2>&1 | grep -qE '^FAIL content-coverage.*uncovered areas:.*retention'
ok "G6: and names the content-coverage gate and the retention area" "[ $? -eq 0 ]"

# ---- G7: a missing repo is a loud failure, not an empty pass -----------
# The name assertion is the whole point here. Without gate 0, a nonexistent
# repo still exits non-zero - incidentally, because jq reads nothing and the
# manifest gate fires. Asserting the exit code alone would score that as a
# working gate 0.
bash "$GATES" --repo "$TMP/does-not-exist" --version 0.5.1 >/dev/null 2>&1
ok "G7: a nonexistent repo exits non-zero rather than passing empty" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/does-not-exist" --version 0.5.1 2>&1 | grep -q '^FAIL inputs'
ok "G7: and names the inputs gate, not an incidental downstream one" "[ $? -eq 0 ]"
# Gate 0 exits before the script's trailing verdict line, so it carries its own
# copy of it. G2 pins the verdict on the normal gate-failure path only, and both
# gate-0 echoes were deletable with this suite fully green (measured) even
# though four cases reach them - G7, G25, G29 and G50 all assert the exit code
# and `^FAIL inputs`, and none of them looked at the verdict. A wrong --repo is
# the likeliest input fault in practice, and task 5 step 2 grades a run by
# grepping RESULT, so under that mutant it would have read a run with no verdict
# at all.
bash "$GATES" --repo "$TMP/does-not-exist" --version 0.5.1 2>&1 | grep -q '^RESULT FAIL'
ok "G7: and prints the RESULT FAIL verdict line" "[ $? -eq 0 ]"

# ---- G8: [Unreleased] must lead ---------------------------------------
# Renames the section rather than deleting it, so the SECOND heading is still
# the target version and only the [Unreleased] arm of the gate can fire.
good_tree "$TMP/nounrel"
sed -i 's/^## \[Unreleased\]$/## [Pending]/' "$TMP/nounrel/CHANGELOG.md"
bash "$GATES" --repo "$TMP/nounrel" --version 0.5.1 >/dev/null 2>&1
ok "G8: a changelog that does not lead with [Unreleased] exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/nounrel" --version 0.5.1 2>&1 | grep -q '^FAIL heading-order'
ok "G8: and names the heading-order gate" "[ $? -eq 0 ]"

# ---- G9: an E5-free release section fails -----------------------------
# The regression test for the defect this gate was rewritten to catch. Every
# E5 bullet is deleted and everything else is left intact, including the
# checkpoint write-path bullet task 2 step 4 moves in verbatim. That leaves
# exactly seven bullets - the floor - so the floor cannot fire and the only
# thing separating "E5 described" from "E5 absent" is the retention arm.
# Against a retention arm keyed to "progress file|retention" this tree passed.
good_tree "$TMP/noe5"
drop "$TMP/noe5" '^- Archived progress files carry exactly one timestamp instead of a doubled pair\.$' \
                 '^- The progress archive is pruned on a two-tier retention rule\.$' \
                 '^- Aged progress files sweep into a cold tier under progress-cold\.$' \
                 '^- BATON_PROGRESS_COLD_DAYS is registered on the config surface\.$'
bash "$GATES" --repo "$TMP/noe5" --version 0.5.1 >/dev/null 2>&1
ok "G9: a release section with no E5 content exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/noe5" --version 0.5.1 2>&1 | grep -qE '^FAIL content-coverage.*uncovered areas:.*retention'
ok "G9: and names the retention area, not the bullet floor" "[ $? -eq 0 ]"
# G9's tree sits exactly ON the floor, which makes this the upper half of the
# floor's pin: a floor raised to eight or nine turns this assertion red.
bash "$GATES" --repo "$TMP/noe5" --version 0.5.1 2>&1 | grep -q '^PASS bullet-floor'
ok "G9: and passes bullet-floor at exactly seven bullets" "[ $? -eq 0 ]"

# ---- G10: content coverage, install-channel arm -----------------------
good_tree "$TMP/nochan"
drop "$TMP/nochan" '^- Commands now reach the settings-channel install\.$'
bash "$GATES" --repo "$TMP/nochan" --version 0.5.1 >/dev/null 2>&1
ok "G10: a release section with no install-channel coverage exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/nochan" --version 0.5.1 2>&1 | grep -qE '^FAIL content-coverage.*uncovered areas:.*install-channel'
ok "G10: and names the install-channel area" "[ $? -eq 0 ]"

# ---- G11: content coverage, dashboard arm -----------------------------
good_tree "$TMP/nodash"
drop "$TMP/nodash" '^- The dashboard TUI mode is documented and findable\.$' \
                   '^- The dashboard docs carry a drift guard against the scripts\.$'
bash "$GATES" --repo "$TMP/nodash" --version 0.5.1 >/dev/null 2>&1
ok "G11: a release section with no dashboard coverage exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/nodash" --version 0.5.1 2>&1 | grep -qE '^FAIL content-coverage.*uncovered areas:.*dashboard'
ok "G11: and names the dashboard area" "[ $? -eq 0 ]"

# ---- G12: content coverage, write-path arm ----------------------------
good_tree "$TMP/nowrite"
drop "$TMP/nowrite" '^- Every checkpoint now writes to a fresh progress-file path carrying a timestamp\.$' \
                    '^- Archived progress files carry exactly one timestamp instead of a doubled pair\.$'
bash "$GATES" --repo "$TMP/nowrite" --version 0.5.1 >/dev/null 2>&1
ok "G12: a release section with no write-path coverage exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/nowrite" --version 0.5.1 2>&1 | grep -qE '^FAIL content-coverage.*uncovered areas:.*write-path'
ok "G12: and names the write-path area" "[ $? -eq 0 ]"

# ---- G13: the bullet floor is its own gate ----------------------------
# All four areas covered, too few bullets. The floor and the coverage arms
# print different gate names, so this tree must fail one and pass the other.
good_tree "$TMP/floor"
drop "$TMP/floor" '^- A partial install fails loudly instead of reporting success\.$' \
                  '^- Archived progress files carry exactly one timestamp instead of a doubled pair\.$' \
                  '^- The dashboard docs carry a drift guard against the scripts\.$' \
                  '^- Aged progress files sweep into a cold tier under progress-cold\.$' \
                  '^- BATON_PROGRESS_COLD_DAYS is registered on the config surface\.$' \
                  '^- The manual and automated checkpoint modes are defined correctly\.$'
bash "$GATES" --repo "$TMP/floor" --version 0.5.1 >/dev/null 2>&1
ok "G13: a release section below the bullet floor exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/floor" --version 0.5.1 2>&1 | grep -q '^FAIL bullet-floor'
ok "G13: and names the bullet-floor gate" "[ $? -eq 0 ]"
bash "$GATES" --repo "$TMP/floor" --version 0.5.1 2>&1 | grep -q '^PASS content-coverage'
ok "G13: and passes content-coverage, so the two verdicts are separable" "[ $? -eq 0 ]"

# ---- G14: the pending note deleted from both sections -----------------
# G4 covers gate 4's IN_REL arm. This covers the IN_UNREL arm, which no
# fixture reached: with the note gone from the file entirely, IN_UNREL is 0
# and IN_REL is 0, and only the >=1 arm can catch it.
good_tree "$TMP/nonote"
drop "$TMP/nonote" '^- Code alignment is still pending for the checkpoint-mode documentation\.$'
bash "$GATES" --repo "$TMP/nonote" --version 0.5.1 >/dev/null 2>&1
ok "G14: the pending note missing from both sections exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/nonote" --version 0.5.1 2>&1 | grep -q '^FAIL pending-note'
ok "G14: and names the pending-note gate" "[ $? -eq 0 ]"

# ---- G43: the pending note RESTATED in the release fails ---------------
# Gate 4's IN_REL arm, which no fixture reached: G4 moves the note down and G14
# deletes it, and both are caught by the >=1 [Unreleased] arm alone, so the
# `IN_REL -eq 0` half could be deleted outright with this suite still green
# (measured). That half is the one enforcing "the pending note is not folded
# into the release".
#
# The copy is REWORDED, so gate 7 - which compares exact bullet text - stays
# quiet and gate 4 is the only gate that can decide this tree. The bullet count
# goes UP to twelve, so the floor cannot fire either.
good_tree "$TMP/restated"
sed -i 's/^- The manual and automated checkpoint modes are defined correctly\.$/&\n- Code alignment is still pending for the mode docs./' "$TMP/restated/CHANGELOG.md"
bash "$GATES" --repo "$TMP/restated" --version 0.5.1 >/dev/null 2>&1
ok "G43: the pending note restated in the release exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/restated" --version 0.5.1 2>&1 | grep -q '^FAIL pending-note'
ok "G43: and names the pending-note gate" "[ $? -eq 0 ]"
bash "$GATES" --repo "$TMP/restated" --version 0.5.1 2>&1 | grep -q '^PASS duplicate-bullet'
ok "G43: and gate 7 stays quiet, so it is gate 4's IN_REL arm that fired" "[ $? -eq 0 ]"

# ---- G15: empty subheading followed by another subheading -------------
# Gate 3's mid-file `### ` awk branch. G3 only reaches the END branch.
good_tree "$TMP/midsub"
sed -i '0,/^### Added$/s//### Removed\n\n### Added/' "$TMP/midsub/CHANGELOG.md"
bash "$GATES" --repo "$TMP/midsub" --version 0.5.1 >/dev/null 2>&1
ok "G15: an empty subheading before another subheading exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/midsub" --version 0.5.1 2>&1 | grep -q '^FAIL empty-subheading'
ok "G15: and names the empty-subheading gate" "[ $? -eq 0 ]"

# ---- G16: empty subheading followed by a release heading --------------
# Gate 3's mid-file `## [` awk branch, the third and last of its three.
good_tree "$TMP/midrel"
sed -i 's/^## \[0\.5\.0\] - 2026-07-25$/### Removed\n\n## [0.5.0] - 2026-07-25/' "$TMP/midrel/CHANGELOG.md"
bash "$GATES" --repo "$TMP/midrel" --version 0.5.1 >/dev/null 2>&1
ok "G16: an empty subheading before a release heading exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/midrel" --version 0.5.1 2>&1 | grep -q '^FAIL empty-subheading'
ok "G16: and names the empty-subheading gate" "[ $? -eq 0 ]"

# ---- G17-G21: invocation errors exit 2, and never hang ----------------
# These assert exit 2 SPECIFICALLY, not merely non-zero. A trailing --repo
# used to spin the argument loop forever: `shift 2` against a one-element
# stack fails without changing $#. Under `timeout` a hang scores 124, and a
# non-zero assertion would have accepted it as a working gate. Every case is
# wrapped in `timeout 10` so a regression fails loudly instead of stalling.
timeout 10 bash "$GATES" --bogus >/dev/null 2>&1
ok "G17: an unknown flag exits 2" "[ $? -eq 2 ]"
# G49: the same arm, but as the ONLY term that can decide the run. G17 passes
# for the wrong reason - `--bogus` alone also trips the required-args check
# below the loop, so the catch-all could be replaced with `*) shift ;;` and G17
# stayed green (measured). Under that mutant a single typo, `--dat 2026-07-30`,
# was silently dropped and the run printed RESULT PASS, exit 0: a date the
# maintainer declared went ungated while reporting that it had been checked.
# Here --repo and --version are both supplied and valid, so nothing but the
# catch-all can reject this invocation.
timeout 10 bash "$GATES" --repo "$TMP/good" --version 0.5.1 --bogus >/dev/null 2>&1
ok "G49: an unknown flag alongside valid required args exits 2" "[ $? -eq 2 ]"
timeout 10 bash "$GATES" >/dev/null 2>&1
ok "G18: no arguments at all exits 2" "[ $? -eq 2 ]"
timeout 10 bash "$GATES" --repo >/dev/null 2>&1
ok "G19: a trailing --repo exits 2 rather than hanging" "[ $? -eq 2 ]"
timeout 10 bash "$GATES" --repo "$TMP/good" --version >/dev/null 2>&1
ok "G20: a trailing --version exits 2 rather than hanging" "[ $? -eq 2 ]"
timeout 10 bash "$GATES" --repo "$TMP/good" --version 0.5.1 --date >/dev/null 2>&1
ok "G21: a trailing --date exits 2 rather than hanging" "[ $? -eq 2 ]"

# ---- G41: --help is a recognised invocation, not a bad one ------------
# The usage line is documented in the script header, and asking for it the
# obvious way used to fall to the catch-all and exit 2, which a caller script
# reads as "you invoked me wrong". G17 keeps the unknown-flag path at 2.
timeout 10 bash "$GATES" --help >/dev/null 2>&1
ok "G41: --help exits 0" "[ $? -eq 0 ]"
timeout 10 bash "$GATES" -h >/dev/null 2>&1
ok "G41: and -h exits 0" "[ $? -eq 0 ]"
# The stream is pinned, not merged. On --help the usage text IS the requested
# output of a successful run, so it belongs on stdout: a caller doing
# `--help >doc.txt` used to capture an empty file. This case merged the two
# streams with 2>&1 and so could not see that. The error paths keep it on
# stderr, which is why the second assertion is here - without it, moving
# usage() to stdout wholesale would silently put diagnostics on the data stream.
timeout 10 bash "$GATES" --help 2>/dev/null | grep -q '^usage: '
ok "G41: and prints the usage line on stdout" "[ $? -eq 0 ]"
ok "G41: while a bad invocation keeps it on stderr" "[ -z \"\$(timeout 10 bash '$GATES' --bogus 2>/dev/null)\" ]"

# ---- G22: the release heading must carry a date -----------------------
# Gate 2 used to match the version prefix only, so a heading with no date at
# all - or with any date whatsoever - passed.
good_tree "$TMP/nodate"
sed -i 's/^## \[0\.5\.1\] - 2026-07-28$/## [0.5.1]/' "$TMP/nodate/CHANGELOG.md"
bash "$GATES" --repo "$TMP/nodate" --version 0.5.1 >/dev/null 2>&1
ok "G22: a release heading with no date exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/nodate" --version 0.5.1 2>&1 | grep -q '^FAIL heading-order'
ok "G22: and names the heading-order gate" "[ $? -eq 0 ]"

# ---- G23: --date pins the exact declared date -------------------------
good_tree "$TMP/wrongdate"
sed -i 's/^## \[0\.5\.1\] - 2026-07-28$/## [0.5.1] - 2026-08-01/' "$TMP/wrongdate/CHANGELOG.md"
bash "$GATES" --repo "$TMP/wrongdate" --version 0.5.1 --date 2026-07-28 >/dev/null 2>&1
ok "G23: a heading dated other than the declared date exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/wrongdate" --version 0.5.1 --date 2026-07-28 2>&1 | grep -q '^FAIL heading-order'
ok "G23: and names the heading-order gate" "[ $? -eq 0 ]"

# ---- G24: the declared date on a well-formed tree still passes --------
bash "$GATES" --repo "$TMP/good" --version 0.5.1 --date 2026-07-28 >/dev/null 2>&1
ok "G24: a well-formed tree with the declared date exits 0" "[ $? -eq 0 ]"

# ---- G25: a missing jq is named as an input fault ---------------------
# Without this arm, an absent jq leaves GOT empty and the run fails
# manifest-version, blaming the manifest for a missing tool. Gate 0 reaches
# its verdict using shell builtins only, so an empty PATH is enough to hide
# jq without hiding everything else.
mkdir -p "$TMP/nopath"
PATH="$TMP/nopath" "$BASH" "$GATES" --repo "$TMP/good" --version 0.5.1 >/dev/null 2>&1
ok "G25: a missing jq exits non-zero" "[ $? -ne 0 ]"
PATH="$TMP/nopath" "$BASH" "$GATES" --repo "$TMP/good" --version 0.5.1 2>&1 | grep -q '^FAIL inputs'
ok "G25: and names the inputs gate, not manifest-version" "[ $? -eq 0 ]"
# The jq arm is gate 0's SECOND early exit and carries its own verdict echo,
# separate from the one G7 pins. Deleting either alone left the suite green.
PATH="$TMP/nopath" "$BASH" "$GATES" --repo "$TMP/good" --version 0.5.1 2>&1 | grep -q '^RESULT FAIL'
ok "G25: and prints the RESULT FAIL verdict line" "[ $? -eq 0 ]"

# ---- G26: the mandated wording alone satisfies the retention arm ------
# Task 2 step 4 tells the author to describe E5 as a two-tier retention rule.
# A retention arm keyed to implementation vocabulary alone would reject a
# section written from that instruction. Task 3 step 3 runs the gate script
# against archived HEAD before the overlay, so on the normal path that
# rejection stops the release before anything goes live; the residual is a
# change landing between that run and task 5 step 2. This case makes the
# `two-tier` alternative load-bearing rather than decorative.
good_tree "$TMP/twotier"
drop "$TMP/twotier" '^- Aged progress files sweep into a cold tier under progress-cold\.$' \
                    '^- BATON_PROGRESS_COLD_DAYS is registered on the config surface\.$'
bash "$GATES" --repo "$TMP/twotier" --version 0.5.1 >/dev/null 2>&1
ok "G26: the plan's mandated two-tier wording alone satisfies retention" "[ $? -eq 0 ]"

# ---- G27: E5's shipped vocabulary satisfies the retention arm ----------
# The other direction: an author who writes the bullet from E5's diff rather
# than from the plan's summary must also pass.
#
# This case drops the plan's mandated wording only, so THREE of the retention
# arm's alternatives are left satisfying it - `cold tier`, `progress-cold` and
# `BATON_PROGRESS_COLD_DAYS`. It therefore pins no single alternative, and is
# deliberately not worded as though it did. The per-alternative pins are
# G39, G40, G51 and G52.
good_tree "$TMP/coldonly"
drop "$TMP/coldonly" '^- The progress archive is pruned on a two-tier retention rule\.$'
bash "$GATES" --repo "$TMP/coldonly" --version 0.5.1 >/dev/null 2>&1
ok "G27: E5's shipped implementation vocabulary satisfies retention" "[ $? -eq 0 ]"

# ---- G28: one bullet below the floor fails ----------------------------
# The floor's VALUE, not merely its existence. G9 sits exactly ON seven and
# asserts PASS bullet-floor; this tree carries six with all four coverage areas
# still satisfied and must FAIL. Both halves are load-bearing: the G9 assertion
# alone leaves a floor of six alive, this case alone leaves eight and nine.
good_tree "$TMP/sixbullets"
drop "$TMP/sixbullets" '^- A partial install fails loudly instead of reporting success\.$' \
                       '^- Archived progress files carry exactly one timestamp instead of a doubled pair\.$' \
                       '^- The dashboard docs carry a drift guard against the scripts\.$' \
                       '^- Aged progress files sweep into a cold tier under progress-cold\.$' \
                       '^- BATON_PROGRESS_COLD_DAYS is registered on the config surface\.$'
bash "$GATES" --repo "$TMP/sixbullets" --version 0.5.1 >/dev/null 2>&1
ok "G28: a release section one bullet below the floor exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/sixbullets" --version 0.5.1 2>&1 | grep -q '^FAIL bullet-floor'
ok "G28: and names the bullet-floor gate" "[ $? -eq 0 ]"
bash "$GATES" --repo "$TMP/sixbullets" --version 0.5.1 2>&1 | grep -q '^PASS content-coverage'
ok "G28: and still passes content-coverage, so it is the floor that fired" "[ $? -eq 0 ]"

# ---- G29: a manifest with no changelog is an input fault --------------
# G7 points at a directory where NEITHER input exists, so the manifest arm of
# gate 0 alone decides it and the changelog arm is never the deciding term:
# deleting that arm left the suite fully green (measured). A tree with a
# manifest and no changelog is plausible, since the manifest lives one
# directory down; without the arm it falls through to gate 2, where grep on a
# nonexistent file leaves H1/H2 empty and the run blames heading-order for a
# changelog that is not there.
good_tree "$TMP/nolog"
rm -f "$TMP/nolog/CHANGELOG.md"
bash "$GATES" --repo "$TMP/nolog" --version 0.5.1 >/dev/null 2>&1
ok "G29: a manifest with no changelog exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/nolog" --version 0.5.1 2>&1 | grep -q '^FAIL inputs'
ok "G29: and names the inputs gate, not heading-order" "[ $? -eq 0 ]"

# ---- G50: a changelog with no manifest is an input fault --------------
# The mirror of G29, and it exists for the reason written there. G7 points at a
# directory where NEITHER input exists, so the CHANGELOG arm decides it and G29
# is the only case the manifest arm can decide - except G29 removes the
# changelog, so the manifest arm was still never the deciding term: deleting
# `! -f "$MANIFEST"` left the suite fully green (measured). A tree with a
# changelog and no manifest is the likelier of the two in practice, since the
# manifest lives a directory down and is the file a cut edits; without the arm
# the run falls through to gate 1, where jq reads nothing and the verdict blames
# the manifest's CONTENTS for a manifest that is not there.
good_tree "$TMP/nomanifest"
rm -f "$TMP/nomanifest/.claude-plugin/plugin.json"
bash "$GATES" --repo "$TMP/nomanifest" --version 0.5.1 >/dev/null 2>&1
ok "G50: a changelog with no manifest exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/nomanifest" --version 0.5.1 2>&1 | grep -q '^FAIL inputs'
ok "G50: and names the inputs gate, not manifest-version" "[ $? -eq 0 ]"

# ---- G30: a bullet copied into both sections fails --------------------
# Task 2 step 4 MOVES two bullets out of [Unreleased] into the release section.
# A move performed as a copy leaves the same claim in both places, and gate 6's
# floor counts bullets, so the duplicate RAISES the count rather than lowering
# it. No other gate compares the two sections' contents.
good_tree "$TMP/dup"
sed -i 's/^- An unrelated item that stays behind in this release\.$/&\n- The dashboard TUI mode is documented and findable./' "$TMP/dup/CHANGELOG.md"
bash "$GATES" --repo "$TMP/dup" --version 0.5.1 >/dev/null 2>&1
ok "G30: a bullet appearing in both sections exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/dup" --version 0.5.1 2>&1 | grep -q '^FAIL duplicate-bullet'
ok "G30: and names the duplicate-bullet gate" "[ $? -eq 0 ]"
# The other direction, and the reason gate 7 compares exact bullet text rather
# than keyword overlap: good_tree's [Unreleased] note and two of its release
# bullets all say "checkpoint", so a word-overlap comparison flags a legitimate
# tree - and a gate that rejects a correct section costs a release. Task 3
# step 3 runs the gate script against archived HEAD before the overlay, so on
# the normal path that rejection stops the release before anything goes live.
bash "$GATES" --repo "$TMP/good" --version 0.5.1 2>&1 | grep -q '^PASS duplicate-bullet'
ok "G30: near-duplicate wording across the two sections still passes" "[ $? -eq 0 ]"

# ---- G32: an undated prior release heading fails ----------------------
# Gate 8. Gates 4, 5, 6 and 7 read the release section as the lines between
# the release heading and the next `## [` heading, and gate 2 reads the first
# two headings only, so nothing used to read the third. Measured on the
# earlier script: this tree gave RESULT PASS, exit 0.
good_tree "$TMP/undatedprior"
sed -i 's/^## \[0\.5\.0\] - 2026-07-25$/## [0.5.0]/' "$TMP/undatedprior/CHANGELOG.md"
bash "$GATES" --repo "$TMP/undatedprior" --version 0.5.1 >/dev/null 2>&1
ok "G32: an undated prior release heading exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/undatedprior" --version 0.5.1 2>&1 | grep -q '^FAIL prior-release-heading'
ok "G32: and names the prior-release-heading gate" "[ $? -eq 0 ]"

# ---- G33: a deleted prior release heading fails -----------------------
# The consequential half. Deleting the heading swallows the previous release's
# bullets into the release section, so the bullet count goes UP and gate 6's
# floor cannot catch it. Measured on the earlier script: RESULT PASS, exit 0.
good_tree "$TMP/noprior"
sed -i '/^## \[0\.5\.0\] - 2026-07-25$/d' "$TMP/noprior/CHANGELOG.md"
bash "$GATES" --repo "$TMP/noprior" --version 0.5.1 >/dev/null 2>&1
ok "G33: a deleted prior release heading exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/noprior" --version 0.5.1 2>&1 | grep -q '^FAIL prior-release-heading'
ok "G33: and names the prior-release-heading gate, not the bullet floor" "[ $? -eq 0 ]"

# ---- G34: --prior pins the exact prior version ------------------------
# The structural default cannot catch a heading deleted from the MIDDLE of a
# long changelog, because the release before it is itself well-formed. --prior
# closes that case, and this pair pins both of its directions.
bash "$GATES" --repo "$TMP/good" --version 0.5.1 --prior 0.4.9 >/dev/null 2>&1
ok "G34: a third heading other than the declared prior release exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/good" --version 0.5.1 --prior 0.4.9 2>&1 | grep -q '^FAIL prior-release-heading'
ok "G34: and names the prior-release-heading gate" "[ $? -eq 0 ]"
bash "$GATES" --repo "$TMP/good" --version 0.5.1 --prior 0.5.0 >/dev/null 2>&1
ok "G34: and the declared prior release on a well-formed tree exits 0" "[ $? -eq 0 ]"

# ---- G35: a trailing --prior exits 2 rather than hanging ---------------
# Same argument-loop hazard as G19-G21, under the same timeout.
timeout 10 bash "$GATES" --repo "$TMP/good" --version 0.5.1 --prior >/dev/null 2>&1
ok "G35: a trailing --prior exits 2 rather than hanging" "[ $? -eq 2 ]"

# ---- G44: a third heading repeating this release fails -----------------
# Gate 8's repeat-version arm, which no fixture reached: G32 and G33 are both
# decided by the arms below it, so deleting this one left the suite green
# (measured) - a duplicated release heading then fell through to the well-formed
# `## [<version>] - <date>` arm and passed. It is the arm that catches a release
# section with no lower bound of its own.
good_tree "$TMP/repeatver"
sed -i 's/^## \[0\.5\.0\] - 2026-07-25$/## [0.5.1] - 2026-07-28\n\n## [0.5.0] - 2026-07-25/' "$TMP/repeatver/CHANGELOG.md"
bash "$GATES" --repo "$TMP/repeatver" --version 0.5.1 >/dev/null 2>&1
ok "G44: a third heading repeating the release version exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/repeatver" --version 0.5.1 2>&1 | grep -qE "^FAIL prior-release-heading.*repeats"
ok "G44: and names the repeat, not the malformed-heading arm" "[ $? -eq 0 ]"
bash "$GATES" --repo "$TMP/repeatver" --version 0.5.1 2>&1 | grep -q '^PASS bullet-floor'
ok "G44: and passes bullet-floor, so it is gate 8 that fired" "[ $? -eq 0 ]"

# ---- G36-G40, G45, G51-G53: every coverage ALTERNATIVE is load-bearing -
# Each of gate 5's arms is an alternation, and an alternative no fixture
# exercises can be deleted without turning this suite red - measured: the
# install-channel arm reduced to `settings-channel`, the write-path arm reduced
# to `timestamp`, and the retention arm with `progress-cold` or with
# `BATON_PROGRESS_COLD_DAYS` deleted, all left the suite fully green.
#
# A later sweep found three the earlier round of this block still missed, now
# pinned by G51, G52 and G53. `cold tier` survived because the only bullet
# carrying it also carried `progress-cold`, so the neighbour did the killing -
# the same pattern the header at :22-28 names. `cold-tier` and `write-path`
# survived because those hyphenated spellings appeared in no fixture at all.
# With those three added, dropping ANY single alternative from any of the four
# arms turns this suite red.
#
# Each case in this block rewrites the good tree so exactly ONE alternative
# satisfies the arm under test, and asserts exit 0 - the G26/G27 shape. They
# are positive cases: they pin the gate's tolerance of correct wording, which
# is the direction that rejects a real release.
#
# What this block does NOT pin is letter CASE. The four arms are matched with
# `grep -qi`, and every satisfying term in every fixture here is written in its
# pattern literal's own case, so all four `-i` flags are removable with this
# block fully green. That is a separate property and G54 pins it separately.

good_tree "$TMP/altchan1"
sed -i 's/^- Commands now reach the settings-channel install\.$/- The settings.json install channel now delivers the slash commands./' "$TMP/altchan1/CHANGELOG.md"
bash "$GATES" --repo "$TMP/altchan1" --version 0.5.1 >/dev/null 2>&1
ok "G36: the 'install channel' wording alone satisfies install-channel" "[ $? -eq 0 ]"

# G45 is the third member of the install-channel alternation, and the one
# good_tree used to carry incidentally: with the shipped bullet also matching
# `commands? .*install`, deleting `settings-channel` left the suite green
# (measured). The bullet here drops the word "install" entirely, so only
# `settings-channel` can satisfy the arm.
good_tree "$TMP/altchan3"
sed -i 's/^- Commands now reach the settings-channel install\.$/- The settings-channel now delivers slash verbs./' "$TMP/altchan3/CHANGELOG.md"
bash "$GATES" --repo "$TMP/altchan3" --version 0.5.1 >/dev/null 2>&1
ok "G45: the 'settings-channel' wording alone satisfies install-channel" "[ $? -eq 0 ]"

good_tree "$TMP/altchan2"
sed -i 's/^- Commands now reach the settings-channel install\.$/- Slash commands are delivered by the settings.json install./' "$TMP/altchan2/CHANGELOG.md"
bash "$GATES" --repo "$TMP/altchan2" --version 0.5.1 >/dev/null 2>&1
ok "G37: the 'commands ... install' wording alone satisfies install-channel" "[ $? -eq 0 ]"

good_tree "$TMP/altwrite"
sed -i 's/^- Every checkpoint now writes to a fresh progress-file path carrying a timestamp\.$/- Every checkpoint now takes a fresh progress-file write path./' "$TMP/altwrite/CHANGELOG.md"
sed -i 's/^- Archived progress files carry exactly one timestamp instead of a doubled pair\.$/- Archived progress files carry exactly one suffix instead of a doubled pair./' "$TMP/altwrite/CHANGELOG.md"
bash "$GATES" --repo "$TMP/altwrite" --version 0.5.1 >/dev/null 2>&1
ok "G38: the 'write path' wording alone satisfies write-path" "[ $? -eq 0 ]"

good_tree "$TMP/altcold"
drop "$TMP/altcold" '^- The progress archive is pruned on a two-tier retention rule\.$' \
                     '^- BATON_PROGRESS_COLD_DAYS is registered on the config surface\.$'
sed -i 's/^- Aged progress files sweep into a cold tier under progress-cold\.$/- Aged progress files sweep into progress-cold./' "$TMP/altcold/CHANGELOG.md"
bash "$GATES" --repo "$TMP/altcold" --version 0.5.1 >/dev/null 2>&1
ok "G39: the 'progress-cold' vocabulary alone satisfies retention" "[ $? -eq 0 ]"

good_tree "$TMP/altdays"
drop "$TMP/altdays" '^- The progress archive is pruned on a two-tier retention rule\.$' \
                     '^- Aged progress files sweep into a cold tier under progress-cold\.$'
bash "$GATES" --repo "$TMP/altdays" --version 0.5.1 >/dev/null 2>&1
ok "G40: BATON_PROGRESS_COLD_DAYS alone satisfies retention" "[ $? -eq 0 ]"

# G51: the spaced `cold tier` spelling. G27 and G39 both leave this alternative
# satisfied, but neither leaves it ALONE: good_tree's cold-tier bullet reads
# "... into a cold tier under progress-cold", so `progress-cold` was always
# there to do the killing. Rewording that bullet to drop the implementation
# noun is what makes this the single deciding term. Nine bullets, clear of the
# floor.
good_tree "$TMP/altcoldtier"
drop "$TMP/altcoldtier" '^- The progress archive is pruned on a two-tier retention rule\.$' \
                        '^- BATON_PROGRESS_COLD_DAYS is registered on the config surface\.$'
sed -i 's/^- Aged progress files sweep into a cold tier under progress-cold\.$/- Aged progress files sweep into a cold tier once they age out./' "$TMP/altcoldtier/CHANGELOG.md"
bash "$GATES" --repo "$TMP/altcoldtier" --version 0.5.1 >/dev/null 2>&1
ok "G51: the spaced 'cold tier' wording alone satisfies retention" "[ $? -eq 0 ]"

# G52: the hyphenated spelling of the same noun, which is a distinct
# alternative on the arm and matched no fixture anywhere in this suite. An
# author who writes "cold-tier" rather than "cold tier" must pass.
good_tree "$TMP/altcoldhyphen"
drop "$TMP/altcoldhyphen" '^- The progress archive is pruned on a two-tier retention rule\.$' \
                          '^- BATON_PROGRESS_COLD_DAYS is registered on the config surface\.$'
sed -i 's/^- Aged progress files sweep into a cold tier under progress-cold\.$/- Aged progress files sweep into the cold-tier archive./' "$TMP/altcoldhyphen/CHANGELOG.md"
bash "$GATES" --repo "$TMP/altcoldhyphen" --version 0.5.1 >/dev/null 2>&1
ok "G52: the hyphenated 'cold-tier' spelling alone satisfies retention" "[ $? -eq 0 ]"

# G53: the same hyphenation split on the write-path arm. G38 pins the spaced
# `write path`; the hyphenated spelling matched no fixture. The second sed
# clears `timestamp` off the other write-path bullet, in G38's shape, so the
# hyphenated term is the only one left that can decide the arm.
good_tree "$TMP/altwritehyphen"
sed -i 's/^- Every checkpoint now writes to a fresh progress-file path carrying a timestamp\.$/- Every checkpoint now takes a fresh progress-file write-path./' "$TMP/altwritehyphen/CHANGELOG.md"
sed -i 's/^- Archived progress files carry exactly one timestamp instead of a doubled pair\.$/- Archived progress files carry exactly one suffix instead of a doubled pair./' "$TMP/altwritehyphen/CHANGELOG.md"
bash "$GATES" --repo "$TMP/altwritehyphen" --version 0.5.1 >/dev/null 2>&1
ok "G53: the hyphenated 'write-path' spelling alone satisfies write-path" "[ $? -eq 0 ]"

# ---- G54: the coverage arms are case-insensitive on purpose ------------
# All four arms match with `grep -qi`, and all four `-i` flags were removable
# with this suite fully green (measured), because every satisfying term in
# every fixture above happens to be written in its pattern literal's own case.
# That is not the same as "the fixtures are lowercase":
# `BATON_PROGRESS_COLD_DAYS` is uppercase in both the arm and the bullet and
# matches case-sensitively anyway.
#
# The flag is not decoration. A release bullet that opens a sentence with
# "Dashboard TUI mode ..." carries a capital D, and without `-i` this gate
# would FAIL a correctly authored release over sentence case - the same
# release-costing direction the arms' own comments care about.
#
# One fixture, not four. Each of the four arms is left with exactly one
# satisfying bullet, and each of those four bullets is capitalised differently
# from its arm's pattern literal, so dropping any single `-i` uncovers that one
# arm on its own and the run exits non-zero. Nine bullets, clear of the floor,
# and the second assertion names content-coverage so a red run cannot be
# mistaken for the floor firing.
good_tree "$TMP/altcase"
drop "$TMP/altcase" '^- The progress archive is pruned on a two-tier retention rule\.$' \
                    '^- BATON_PROGRESS_COLD_DAYS is registered on the config surface\.$'
sed -i 's/^- Commands now reach the settings-channel install\.$/- The Settings-Channel now delivers slash verbs./' "$TMP/altcase/CHANGELOG.md"
sed -i 's/^- The dashboard TUI mode is documented and findable\.$/- Dashboard TUI mode is documented and findable./' "$TMP/altcase/CHANGELOG.md"
sed -i 's/^- The dashboard docs carry a drift guard against the scripts\.$/- The TUI docs carry a drift guard against the scripts./' "$TMP/altcase/CHANGELOG.md"
sed -i 's/^- Aged progress files sweep into a cold tier under progress-cold\.$/- Aged progress files sweep into a Cold Tier./' "$TMP/altcase/CHANGELOG.md"
sed -i 's/^- Every checkpoint now writes to a fresh progress-file path carrying a timestamp\.$/- Every checkpoint now takes a fresh progress-file Timestamp./' "$TMP/altcase/CHANGELOG.md"
sed -i 's/^- Archived progress files carry exactly one timestamp instead of a doubled pair\.$/- Archived progress files carry exactly one suffix instead of a doubled pair./' "$TMP/altcase/CHANGELOG.md"
bash "$GATES" --repo "$TMP/altcase" --version 0.5.1 >/dev/null 2>&1
ok "G54: sentence-cased coverage wording still satisfies all four arms" "[ $? -eq 0 ]"
bash "$GATES" --repo "$TMP/altcase" --version 0.5.1 2>&1 | grep -q '^PASS content-coverage'
ok "G54: and it is content-coverage that passes, not the floor alone" "[ $? -eq 0 ]"

# ---- G42: coverage is decided by bullets, not by any line --------------
# The four arms used to grep the release section wholesale, so a `### ` heading
# or any prose satisfied an area. Measured on the earlier script: rewording the
# two dashboard bullets to drop the word and renaming `### Added` to
# `### Dashboard` gave PASS content-coverage, exit 0 - the gate reporting true
# for a property that is false. The bullet count is untouched at eleven, so the
# floor cannot be what fires.
good_tree "$TMP/headingonly"
sed -i 's/^- The dashboard TUI mode is documented and findable\.$/- The TUI mode is documented and findable./' "$TMP/headingonly/CHANGELOG.md"
sed -i 's/^- The dashboard docs carry a drift guard against the scripts\.$/- The TUI docs carry a drift guard against the scripts./' "$TMP/headingonly/CHANGELOG.md"
sed -i '0,/^### Added$/s//### Dashboard/' "$TMP/headingonly/CHANGELOG.md"
bash "$GATES" --repo "$TMP/headingonly" --version 0.5.1 >/dev/null 2>&1
ok "G42: an area named only by a subheading exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/headingonly" --version 0.5.1 2>&1 | grep -qE '^FAIL content-coverage.*uncovered areas:.*dashboard'
ok "G42: and names the dashboard area, not the bullet floor" "[ $? -eq 0 ]"
bash "$GATES" --repo "$TMP/headingonly" --version 0.5.1 2>&1 | grep -q '^PASS bullet-floor'
ok "G42: and still passes bullet-floor at eleven bullets" "[ $? -eq 0 ]"

# ---- G46-G48: a version carrying an ERE metacharacter ------------------
# Every gate that needs the release section derives it by splicing $VERSION into
# a range predicate. While that splice was a dynamic REGEX, a `+` in the version
# stopped the predicate matching its own heading, and the failure was silent in
# both directions: gates 5 and 6 read an empty section and rejected a correctly
# authored release, while gates 4 and 7 read an empty section and PASSED a tree
# carrying the exact violation they exist to catch. Measured on the earlier
# script, all four cases below.
#
# `1.0.0+build` is a valid semver, so this is a release the maintainer can
# legitimately cut, not a malformed invocation.

# G46: the correctly authored direction. The tree is good_tree verbatim, so
# anything but exit 0 means the section derived empty.
meta_tree "$TMP/metagood"
bash "$GATES" --repo "$TMP/metagood" --version '1.0.0+build' >/dev/null 2>&1
ok "G46: a well-formed tree at a metacharacter version exits 0" "[ $? -eq 0 ]"
bash "$GATES" --repo "$TMP/metagood" --version '1.0.0+build' 2>&1 | grep -q '^PASS content-coverage'
ok "G46: and locates the release section for content-coverage" "[ $? -eq 0 ]"
bash "$GATES" --repo "$TMP/metagood" --version '1.0.0+build' 2>&1 | grep -q '^PASS bullet-floor'
ok "G46: and counts its bullets rather than reading zero" "[ $? -eq 0 ]"

# G47: the vacuous-pass direction on gate 4. Same restated-note tree as G43,
# which that gate catches at 0.5.1 and used to MISS here.
meta_tree "$TMP/metanote"
sed -i 's/^- The manual and automated checkpoint modes are defined correctly\.$/&\n- Code alignment is still pending for the mode docs./' "$TMP/metanote/CHANGELOG.md"
bash "$GATES" --repo "$TMP/metanote" --version '1.0.0+build' >/dev/null 2>&1
ok "G47: the pending note folded into a metacharacter release exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/metanote" --version '1.0.0+build' 2>&1 | grep -q '^FAIL pending-note'
ok "G47: and names the pending-note gate" "[ $? -eq 0 ]"

# G48: the vacuous-pass direction on gate 7, the same tree as G30.
meta_tree "$TMP/metadup"
sed -i 's/^- An unrelated item that stays behind in this release\.$/&\n- The dashboard TUI mode is documented and findable./' "$TMP/metadup/CHANGELOG.md"
bash "$GATES" --repo "$TMP/metadup" --version '1.0.0+build' >/dev/null 2>&1
ok "G48: a bullet in both sections at a metacharacter version exits non-zero" "[ $? -ne 0 ]"
bash "$GATES" --repo "$TMP/metadup" --version '1.0.0+build' 2>&1 | grep -q '^FAIL duplicate-bullet'
ok "G48: and names the duplicate-bullet gate" "[ $? -eq 0 ]"

# ---- G31: the script ships executable ---------------------------------
# Step 4 chmod +x's it, but every case above invokes it as `bash "$GATES"`, so
# the bit itself is otherwise never exercised.
ok "G31: tools/release-gates.sh is executable" "[ -x '$GATES' ]"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
