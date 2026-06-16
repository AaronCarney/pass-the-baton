#!/usr/bin/env bash
# tools/outcome-proxy-commit-survival.sh - supplementary proxy: 14-day commit survival (L0 A6).
# Numeric-only output: no commit messages, paths, authors, or SHAs (L0 D1).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/.claude/hooks/lib/outcome-proxies.sh"

WINDOW=14
REPO="${CLAUDE_PROJECT_DIR:-$PWD}"
SLUG=""
JSON_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --window-days) WINDOW="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --slug) SLUG="$2"; shift 2;;
    --json) JSON_ONLY=1; shift;;
    -h|--help) echo 'Usage: outcome-proxy-commit-survival.sh [--window-days N] [--repo PATH] [--slug SLUG] [--json]'; exit 0;;
    *) echo "outcome-proxy-commit-survival: unknown flag '$1'" >&2; exit 1;;
  esac
done
[ -d "$REPO/.git" ] || { echo '{"error":"not a git repo"}'; exit 0; }
SLUG="${SLUG:-$(basename "$REPO")}"

# Read all commit subjects in the window (numeric counts only - no SHAs, no authors, no paths).
subjects_file=$(mktemp)
trap 'rm -f "$subjects_file"' EXIT
GIT_TERMINAL_PROMPT=0 git -C "$REPO" log --since="$WINDOW days ago" --pretty=tformat:'%s' > "$subjects_file"

if [ ! -s "$subjects_file" ]; then
  payload=$(jq -cn --arg slug "$SLUG" --argjson w "$WINDOW" \
    '{slug: $slug, window_days: $w, n_commits: 0, n_reverted: 0, n_survived: 0, survival_fraction: 0}')
else
  n_commits=$(wc -l < "$subjects_file" | awk '{print $1}')
  # Count originals that have a matching Revert commit.
  # Revert commits themselves (subject starts with 'Revert "') are excluded from the count.
  n_reverted=0
  while IFS= read -r orig; do
    case "$orig" in
      Revert\ \"*\") ;;  # skip revert commits themselves
      *)
        revert_subj="Revert \"$orig\""
        if grep -qxF "$revert_subj" "$subjects_file"; then
          n_reverted=$((n_reverted+1))
        fi
        ;;
    esac
  done < "$subjects_file"
  n_survived=$((n_commits - n_reverted))
  frac=$(awk -v s="$n_survived" -v n="$n_commits" \
    'BEGIN{ if(n==0){printf "0"} else {printf "%.4f", s/n} }')
  payload=$(jq -cn \
    --arg slug "$SLUG" \
    --argjson w "$WINDOW" \
    --argjson nc "$n_commits" \
    --argjson nr "$n_reverted" \
    --argjson ns "$n_survived" \
    --arg sf "$frac" \
    '{slug: $slug, window_days: $w, n_commits: $nc, n_reverted: $nr, n_survived: $ns,
      survival_fraction: ($sf | tonumber)}')
fi

if [ "$JSON_ONLY" = "1" ]; then
  echo "$payload" | jq -c '. + {subkind: "commit_survival"}'
else
  outcome_proxies::emit_event commit_survival "$payload" || true
fi
exit 0
