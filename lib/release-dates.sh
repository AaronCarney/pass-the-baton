#!/usr/bin/env bash
# lib/release-dates.sh - Verified Claude model release-date lookup.
#
# Provenance: All release dates sourced from Anthropic's public model
# announcements at https://docs.anthropic.com/en/docs/about-claude/models/overview
# Dates are bulk-cited; unknown dates are omitted rather than guessed.
#
# Pure helpers; no exec on source.

# release_dates::for_model MODEL_ID
# Prints the ISO-8601 release date (YYYY-MM-DD) for the given model, or empty
# string if the model is not in the verified table.
#
# Note: claude-sonnet-4-5 is intentionally omitted - see the project decision log (maintained internally)
# E18 T11 triage (accepted spec-delta #1). Adding entries here requires a
# verified citation per c-001; do not guess.
release_dates::for_model() {
  local model="$1"
  case "$model" in
    claude-haiku-4-5)  printf '2025-10-15\n' ;;
    claude-sonnet-4-6) printf '2026-02-17\n' ;;
    claude-opus-4-7)   printf '2026-04-16\n' ;;
    *)                 printf '' ;;
  esac
}

# release_dates::crossings DATE_FROM DATE_TO
# Emits one whitespace-separated 'model_id YYYY-MM-DD' line per known release
# with date in the half-open/closed range (FROM, TO] - i.e., FROM < date <= TO.
# ISO date string comparison is used (lexicographic, works for YYYY-MM-DD).
release_dates::crossings() {
  local from="$1" to="$2"
  # Pairs: "model_id date" - one per line. Add entries here as dates are verified.
  local pairs=(
    'claude-haiku-4-5 2025-10-15'
    'claude-sonnet-4-6 2026-02-17'
    'claude-opus-4-7 2026-04-16'
  )
  local pair model date
  for pair in "${pairs[@]}"; do
    model="${pair%% *}"
    date="${pair##* }"
    # Half-open lower (exclusive), closed upper (inclusive): FROM < date <= TO
    # [[ > ]] is lexicographic on YYYY-MM-DD; <= via negation of >
    if [[ "$date" > "$from" ]] && ! [[ "$date" > "$to" ]]; then
      printf '%s %s\n' "$model" "$date"
    fi
  done
}
