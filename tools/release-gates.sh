#!/usr/bin/env bash
# The release gates for a Pass the Baton version cut, as one script with real
# exit codes.
#
# These checks used to live as prose plus fenced commands inside an L2 plan's
# validation task, graded by a reader comparing output against an expectation
# written a paragraph away. That grading is unreliable in a specific, measured
# way: git writes errors to stderr and leaves stdout EMPTY, awk exits 0 whether
# or not it printed a violation, and `grep -c` exits 1 on the honest answer 0.
# Each of those reads as a clean pass. Every gate below therefore reports
# PASS/FAIL on stdout AND contributes to the exit status.
#
# Usage: tools/release-gates.sh --repo <path> --version <semver>
#        [--date <YYYY-MM-DD>] [--prior <semver>]
# Exit:  0 = every gate passed, 1 = one or more failed, 2 = bad invocation.
#
# Gates 4, 5 and 6 are specific to the 0.5.1 cut and you should expect to EDIT
# all three at the next cut, not to delete them. Gate 5's four areas and gate
# 6's floor of seven come from that release's scope. Gate 4 is release-scoped
# for a different reason: it pins a named [Unreleased] note describing work that
# is expected to be RESOLVED, and once the note is gone the gate cannot pass, so
# retire or repoint it deliberately at the cut that resolves it rather than
# deleting it in confusion when it fails. The structural gates - 0 through 3, 7
# and 8 - carry over unchanged.
set -u

REPO=""; VERSION=""; DATE=""; PRIOR=""
# Writes to stdout. On --help the usage text is the requested output of a
# successful run, so it belongs on the data stream; the error paths below
# redirect it to stderr, where a diagnostic belongs.
usage(){ echo "usage: $0 --repo <path> --version <semver> [--date <YYYY-MM-DD>] [--prior <semver>]"; }

# Shift by two only when a value is actually on the stack. `shift 2` against a
# single remaining argument fails, leaves $# unchanged, and spins this loop
# forever: a trailing `--repo` used to hang here rather than reporting a bad
# invocation, and `set -u` cannot see it because `${2:-}` is defaulted.
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    REPO="${2:-}";    shift $(( $# > 1 ? 2 : 1 )) ;;
    --version) VERSION="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --date)    DATE="${2:-}";    shift $(( $# > 1 ? 2 : 1 ))
               [ -n "$DATE" ] || { usage >&2; exit 2; } ;;
    --prior)   PRIOR="${2:-}";   shift $(( $# > 1 ? 2 : 1 ))
               [ -n "$PRIOR" ] || { usage >&2; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] && [ -n "$VERSION" ] || { usage >&2; exit 2; }

RC=0
# Every gate that needs the release section locates it by its heading, and
# $VERSION is part of that heading. It reaches awk as a VALUE compared with
# index(), never spliced into a dynamic regex: `1.0.0+build` is a valid semver,
# and as a regex its `+` stopped matching the literal heading, so the range
# predicate never fired. The section then derived EMPTY, which is silent in both
# directions - gates 5 and 6 rejected a correctly authored release, and gates 4
# and 7 reported PASS for a tree carrying the exact violation they exist to
# catch. awk's -v assignment runs escape processing over its value, so a literal
# backslash is doubled here to survive the trip; escaping the metacharacters
# instead does NOT work, because that same processing strips the escapes back
# off (`\.` reaches the variable as a plain `.`).
VAWK=${VERSION//\\/\\\\}
pass(){ echo "PASS $1"; }
fail(){ echo "FAIL $1: $2"; RC=1; }

MANIFEST="$REPO/.claude-plugin/plugin.json"
CHANGELOG="$REPO/CHANGELOG.md"

# Gate 0: the inputs exist and the tools they need are present. Without this
# every gate below reads empty and the script would report a clean release for
# a path that is not a repository. The jq arm is here rather than left to gate
# 1 for the same reason the repo arm is: with jq absent, GOT is empty and the
# run fails `manifest-version`, naming the wrong fault.
if [ ! -f "$MANIFEST" ] || [ ! -f "$CHANGELOG" ]; then
  fail inputs "missing manifest or changelog under $REPO"
  echo "RESULT FAIL"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  fail inputs "jq is not on PATH; the manifest gate cannot read $MANIFEST"
  echo "RESULT FAIL"
  exit 1
fi

# Gate 1: the manifest reads the release version.
GOT=$(jq -r '.version // empty' "$MANIFEST" 2>/dev/null)
if [ "$GOT" = "$VERSION" ]; then
  pass manifest-version
else
  fail manifest-version "manifest reads '${GOT:-<unset>}', expected '$VERSION'"
fi

# Gate 2: heading order. [Unreleased] first, the release second, and the
# release heading carries a date. Matching the version prefix alone let any
# date through, including one predating work the release contains; the date is
# declared load-bearing by this plan's own contract, so it is gated.
# Pass --date to require an exact declared date; without it the heading must
# still carry a well-formed ISO date and nothing else.
H1=$(grep -n '^## \[' "$CHANGELOG" | sed -n '1p' | cut -d: -f2-)
H2=$(grep -n '^## \[' "$CHANGELOG" | sed -n '2p' | cut -d: -f2-)
# Both arms feed one verdict. Emitting a separate line per arm would let a run
# print PASS heading-order and FAIL heading-order at once, and a gate that
# reports two answers is not one a machine can grade.
HO=""
case "$H1" in
  '## [Unreleased]'*) : ;;
  *) HO="first release heading is '${H1:-<none>}', expected '## [Unreleased]'" ;;
esac
if [ -n "$DATE" ]; then
  [ "$H2" = "## [$VERSION] - $DATE" ] || HO="${HO:+$HO; }second release heading is '${H2:-<none>}', expected '## [$VERSION] - $DATE'"
else
  case "$H2" in
    "## [$VERSION] - "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) HO="${HO:+$HO; }second release heading is '${H2:-<none>}', expected '## [$VERSION] - <YYYY-MM-DD>'" ;;
  esac
fi
if [ -z "$HO" ]; then
  pass heading-order
else
  fail heading-order "$HO"
fi

# Gate 3: no subheading is left empty. Task 2 empties a `### Fixed` under
# [Unreleased] by moving its only bullet into the release section, and a bare
# heading with nothing under it is not valid Keep a Changelog structure.
# awk exits 0 either way, so the violation is carried in its OUTPUT and this
# gate grades the output, not the exit status.
EMPTY=$(awk '
  /^## \[/ { if (h && !n) print s " / " h; s=$0; h=""; n=0; next }
  /^### /   { if (h && !n) print s " / " h; h=$0; n=0; next }
  /^- /     { n++ }
  END       { if (h && !n) print s " / " h }
' "$CHANGELOG")
if [ -z "$EMPTY" ]; then
  pass empty-subheading
else
  fail empty-subheading "$(echo "$EMPTY" | tr '\n' ';')"
fi

# Gate 4: the pending code-alignment note stayed under [Unreleased] and was
# not folded into the release. It describes work this release does not do.
#
# RELEASE-SCOPED, like gates 5 and 6: NOTE names a note that is expected to be
# resolved and removed, and when it is, IN_UNREL goes to 0 and this gate cannot
# pass. A FAIL pending-note at a later cut usually means exactly that. Repoint
# NOTE at that cut's own pending note, or retire the gate on purpose - do not
# delete it because it failed.
NOTE='Code alignment is still pending'
# grep -F, not plain grep: NOTE is repointed at each cut's own pending note (see
# the header), and release-note prose routinely carries `[`, `*` and `\`, which
# a BRE would read as syntax.
IN_UNREL=$(awk -v v="$VAWK" '/^## \[Unreleased\]/ {p=1} index($0, "## [" v "]")==1 {p=0} p' "$CHANGELOG" | grep -cF "$NOTE")
IN_REL=$(awk -v v="$VAWK" 'index($0, "## [" v "]")==1 {p=1; next} /^## \[/ {p=0} p' "$CHANGELOG" | grep -cF "$NOTE")
if [ "$IN_UNREL" -ge 1 ] && [ "$IN_REL" -eq 0 ]; then
  pass pending-note
else
  fail pending-note "note appears $IN_UNREL time(s) under [Unreleased] and $IN_REL time(s) under [$VERSION]; want >=1 and 0"
fi

REL=$(awk -v v="$VAWK" 'index($0, "## [" v "]")==1 {p=1; next} /^## \[/ {p=0} p' "$CHANGELOG")
RELB=$(echo "$REL" | grep '^- ')
BULLETS=$(echo "$REL" | grep -c '^- ')

# Gate 5: content coverage. This is the independent mechanical assertion -
# independent in the sense that it does not re-run the derivation task 2 used
# to author the section. It asserts the shipped section covers each area this
# release actually ships, by keyword.
#
# The retention arm is keyed to E5's own vocabulary and not to the generic
# words "progress file" or "retention". Task 2 step 4 moves the checkpoint
# write-path bullet into this section verbatim, and that bullet contains both
# "progress-file" and "timestamp": under a looser arm it satisfied retention
# and write-path by itself, so a release section carrying no E5 content at all
# passed this gate (measured). It is correct for the write-path arm to be
# satisfied by that bullet - that is the content it exists to require. The
# defect was only that retention was satisfiable by the same bullet.
#
# The alternatives on the retention arm are load-bearing in both directions:
# `two-tier` matches the wording task 2 step 4 mandates, and `progress-cold` /
# `cold tier` / `BATON_PROGRESS_COLD_DAYS` match E5's shipped implementation
# vocabulary. Dropping either half makes this gate reject a correctly-authored
# release. Task 3 step 3 runs this same script against archived HEAD before the
# overlay, so on the normal path that rejection stops the release before
# anything goes live; the residual is a change landing between that run and
# task 5 step 2.
#
# The arms read $RELB, the release section's BULLET lines, not $REL. Grepping
# the section wholesale let a `### ` heading or any prose satisfy an area:
# measured, a section whose dashboard bullets were reworded to drop the word
# and whose `### Added` was renamed `### Dashboard` passed content-coverage.
# Coverage is a claim about what the release SAYS it shipped, and a changelog
# says that in its bullets.
MISSING=""
echo "$RELB" | grep -qiE 'settings-channel|install channel|commands? .*install' || MISSING="$MISSING install-channel"
echo "$RELB" | grep -qiE 'dashboard'                                            || MISSING="$MISSING dashboard"
echo "$RELB" | grep -qiE 'two-tier|cold tier|cold-tier|progress-cold|BATON_PROGRESS_COLD_DAYS' || MISSING="$MISSING retention"
echo "$RELB" | grep -qiE 'timestamp|write path|write-path'                      || MISSING="$MISSING write-path"
if [ -z "$MISSING" ]; then
  pass content-coverage
else
  fail content-coverage "uncovered areas:$MISSING"
fi

# Gate 6: the bullet floor, split out of content-coverage so that an uncovered
# area and a too-thin section print different gate names. Task 2 step 4
# mandates seven content items, so seven bullets is the floor a correctly
# authored section clears exactly. Three of those seven - verify-install, the
# template attribution marker and the manual/automated correction - are matched
# by no arm above, so this floor is the only thing that requires them.
if [ "$BULLETS" -ge 7 ]; then
  pass bullet-floor
else
  fail bullet-floor "release section carries $BULLETS bullet(s), want >=7"
fi

# Gate 7: no bullet appears in both [Unreleased] and the release section. Task
# 2 step 4 MOVES two bullets down; a move performed as a copy leaves the same
# claim in two places, and gate 6's floor counts bullets, so a duplicate RAISES
# the count rather than lowering it. This generalises gate 4, which asks the
# same two-range question against one hardcoded string.
#
# The comparison is EXACT bullet text, deliberately. A keyword or word-overlap
# comparison flags legitimate near-duplicates - in this script's own test suite
# the good tree's [Unreleased] note and two of its release bullets all say
# "checkpoint" - and a gate that rejects a correctly authored section still
# costs a release. Task 3 step 3 runs this same script against archived HEAD
# before the overlay, so on the normal path that rejection stops the release
# before anything goes live; the residual is a change landing between that run
# and task 5 step 2. Exact text catches the mechanical failure, a copy where a
# move was meant. A reworded restatement is not mechanically decidable and
# stays with task 2 step 6's anti-omission read.
DUP=$(awk -v v="$VAWK" '
  /^## \[Unreleased\]/            { sec=1; next }
  index($0, "## [" v "]")==1      { sec=2; next }
  /^## \[/                        { sec=0; next }
  sec==1 && /^- /                 { u[$0]=1; next }
  sec==2 && /^- /                 { if ($0 in u) print $0 }
' "$CHANGELOG")
if [ -z "$DUP" ]; then
  pass duplicate-bullet
else
  fail duplicate-bullet "bullet(s) in both [Unreleased] and [$VERSION]: $(echo "$DUP" | tr '\n' ';')"
fi

# Gate 8: the previous release's heading survived, and carries a date. Gates 4,
# 5, 6 and 7 all derive the release section as the lines between the release
# heading and the NEXT `## [` heading, so a lost or malformed prior heading
# silently widens that range and swallows the previous release's bullets into
# this one. That RAISES the bullet count, so gate 6's floor cannot catch it,
# and gate 2 reads the first two headings only. Measured against a tree that
# otherwise passes every gate: stripping the date off the prior heading gave
# RESULT PASS exit 0, and deleting the heading outright gave RESULT PASS exit 0
# with the release section's bullet count going UP.
#
# Without --prior the check is structural: the third heading must exist, carry
# a well-formed ISO date, and not repeat this release's version. That catches
# an undated heading and one lost off the end of the file, but NOT one deleted
# from the middle of a long changelog, where the release before it is itself a
# well-formed dated heading. --prior pins the exact prior version and closes
# that case, in the same shape --date pins gate 2.
H3=$(grep -n '^## \[' "$CHANGELOG" | sed -n '3p' | cut -d: -f2-)
PRH=""
case "$H3" in
  '') PRH="no third release heading; the [$VERSION] section runs to the end of the file" ;;
  '## ['"$VERSION"']'*) PRH="third heading repeats '[$VERSION]'; the release section has no lower bound" ;;
  '## ['*'] - '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) PRH="third heading is '$H3', expected '## [<version>] - <YYYY-MM-DD>'" ;;
esac
if [ -z "$PRH" ] && [ -n "$PRIOR" ]; then
  case "$H3" in
    '## ['"$PRIOR"'] - '*) : ;;
    *) PRH="third heading is '$H3', expected the declared prior release '## [$PRIOR] - <YYYY-MM-DD>'" ;;
  esac
fi
if [ -z "$PRH" ]; then
  pass prior-release-heading
else
  fail prior-release-heading "$PRH"
fi

[ "$RC" -eq 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
exit "$RC"
