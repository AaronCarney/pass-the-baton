#!/usr/bin/env bash
# test-release-dates.sh - TDD tests for lib/release-dates.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PASS=0; FAIL=0; FAILED=()
assert() {
  local n="$1" c="$2"
  if eval "$c"; then PASS=$((PASS+1)); echo "  PASS  $n"
  else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n"; fi
}

source "$REPO_ROOT/lib/release-dates.sh"

# (a) claude-haiku-4-5 returns verified ISO date
out=$(release_dates::for_model claude-haiku-4-5)
assert 'haiku-4-5 returns 2025-10-15' '[ "$out" = "2025-10-15" ]'

# (b) claude-opus-4-7 returns verified ISO date
out=$(release_dates::for_model claude-opus-4-7)
assert 'opus-4-7 returns 2026-04-16' '[ "$out" = "2026-04-16" ]'

# (c) unknown model returns empty
out=$(release_dates::for_model unknown-model)
assert 'unknown-model returns empty' '[ -z "$out" ]'

# (d) crossings emits one 'model_id YYYY-MM-DD' line per known release in (FROM, TO]
out=$(release_dates::crossings 2025-10-14 2025-10-16)
assert 'crossings haiku-4-5 in range emits line' 'printf "%s" "$out" | grep -q "claude-haiku-4-5 2025-10-15"'

# (e) range with no crossings emits zero lines
out=$(release_dates::crossings 2020-01-01 2020-12-31)
assert 'crossings empty range emits zero lines' '[ -z "$(printf "%s" "$out" | grep -v "^$")" ]'

# (f) BOUNDARY half-open lower: release date == FROM is EXCLUDED
out=$(release_dates::crossings 2025-10-15 2025-10-16)
assert 'crossings FROM==release excluded (half-open lower)' '! printf "%s" "$out" | grep -q "claude-haiku-4-5"'

# (g) BOUNDARY closed upper: release date == TO is INCLUDED
out=$(release_dates::crossings 2025-10-14 2025-10-15)
assert 'crossings TO==release included (closed upper)' 'printf "%s" "$out" | grep -q "claude-haiku-4-5 2025-10-15"'

echo ""
echo "=== $PASS passed, $FAIL failed ==="
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "Failed:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
fi
[ $FAIL -eq 0 ] || exit 1
