#!/usr/bin/env bash
# lib/subset-stratify.sh - per-transcript CC12 subset flags.
# Pure: no I/O beyond transcript read; no jq. Depends on lib/transcript.sh.
set -u

for _fn in transcript::compact_events transcript::clear_events; do
  if ! declare -f "$_fn" >/dev/null 2>&1; then
    echo "lib/subset-stratify.sh: required function not in scope: $_fn" >&2
    echo "  source order: lib/transcript.sh, then this file." >&2
    return 1 2>/dev/null || exit 1
  fi
done
unset _fn

# subset_stratify::compaction_fired <transcript_path> - 1 if any compact boundary, else 0.
subset_stratify::compaction_fired() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "subset_stratify: transcript not found: $path" >&2
    return 1
  fi
  local n
  n=$(transcript::compact_events "$path" | wc -l | awk '{print $1}')
  if [ "$n" -gt 0 ]; then printf '1\n'; else printf '0\n'; fi
}

# subset_stratify::clear_used <transcript_path> - 1 if any /clear event, else 0.
subset_stratify::clear_used() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "subset_stratify: transcript not found: $path" >&2
    return 1
  fi
  local n
  n=$(transcript::clear_events "$path" | wc -l | awk '{print $1}')
  if [ "$n" -gt 0 ]; then printf '1\n'; else printf '0\n'; fi
}
