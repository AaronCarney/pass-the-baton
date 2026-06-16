#!/usr/bin/env bash
# lib/corpus.sh - Claude Code transcript corpus discovery + filter.
# Pure: sourced, no top-level execution, no network.
# Producer of contract corpus-tsv: TSV line per transcript on stdout.
# Columns: path<TAB>workspace<TAB>session_id<TAB>bytes<TAB>turns
set -uo pipefail

CORPUS_DEFAULT_EXCLUDE_WORKSPACE="subagents"

corpus::_turn_count() {
  # Cheap lower-bound turn count: lines whose .type field is exactly assistant.
  # The grep is restricted to the canonical type-key string to avoid matching
  # tool_result echoes or user-message metadata that happen to contain the word.
  # grep -c on no-match prints "0" + exits rc=1; capturing into a var and then
  # || fallback produces a single-line value without the trailing "\n0" that a
  # bare `grep -c ... || echo 0` would emit (which would break TSV downstream).
  local path="$1" n
  n=$(grep -c '^\{"type":"assistant"' "$path" 2>/dev/null) || n=0
  printf '%s' "$n"
}

corpus::list() {
  local root="" inc_globs=() exc_globs=() include_subagents=0 limit=0
  root="${1:-}"; shift || true
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "corpus::list: corpus root missing: $root" >&2; return 2
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace-include) inc_globs+=("$2"); shift 2;;
      --workspace-exclude) exc_globs+=("$2"); shift 2;;
      --include-subagents) include_subagents=1; shift;;
      --limit) limit="$2"; shift 2;;
      *) echo "corpus::list: unknown arg $1" >&2; return 2;;
    esac
  done
  local count=0 path ws sid bytes turns
  while IFS= read -r path; do
    [ -f "$path" ] || continue
    ws="$(basename "$(dirname "$path")")"
    sid="$(basename "$path" .jsonl)"
    if [ "$include_subagents" -eq 0 ] && [ "$ws" = "$CORPUS_DEFAULT_EXCLUDE_WORKSPACE" ]; then continue; fi
    if [ "${#inc_globs[@]}" -gt 0 ]; then
      local matched=0 g
      for g in "${inc_globs[@]}"; do [[ "$ws" == $g ]] && matched=1 && break; done
      [ "$matched" -eq 0 ] && continue
    fi
    local skip=0 g
    for g in "${exc_globs[@]}"; do [[ "$ws" == $g ]] && skip=1 && break; done
    [ "$skip" -eq 1 ] && continue
    bytes=$(wc -c < "$path" 2>/dev/null || echo 0)
    turns=$(corpus::_turn_count "$path")
    printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$ws" "$sid" "$bytes" "$turns"
    count=$((count+1))
    if [ "$limit" -gt 0 ] && [ "$count" -ge "$limit" ]; then break; fi
  done < <(find "$root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -type f 2>/dev/null | sort)
}
