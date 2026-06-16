#!/bin/bash
# Unit tests for lib/otel_mapping.sh - OTel field rename table (E7-T2).
# Pure function tests: no filesystem, no network. Value comparison required.
# Usage: bash .claude/hooks/tests/test-otel-mapping.sh

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$HOOKS_DIR/lib/otel_mapping.sh"

# shellcheck source=/dev/null
. "$LIB"

PASS=0
FAIL=0
FAILED_CASES=()

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS+1))
    echo "  PASS  $name"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name")
    echo "  FAIL  $name"
  fi
}

# Helper: extract a dotted key path from JSON output via jq.
jval() {
  local json="$1" path="$2"
  echo "$json" | jq -r "$path"
}

echo "## otel::rename_line - known keys"

# Mapping 1: data.provider → gen_ai.provider.name
out=$(otel::rename_line '{"schema":"baton.event.v1","event":"x","data":{"provider":"anthropic"}}')
assert "data.provider → gen_ai.provider.name (value preserved)" \
  "[ \"\$(jval \"\$out\" '.data[\"gen_ai.provider.name\"]')\" = 'anthropic' ]"

# Mapping 2: data.model → gen_ai.request.model
out=$(otel::rename_line '{"schema":"baton.event.v1","event":"x","data":{"model":"claude-opus-4-7"}}')
assert "data.model → gen_ai.request.model (value preserved)" \
  "[ \"\$(jval \"\$out\" '.data[\"gen_ai.request.model\"]')\" = 'claude-opus-4-7' ]"

# Mapping 3: data.tokens_in → gen_ai.usage.input_tokens
out=$(otel::rename_line '{"schema":"baton.event.v1","event":"x","data":{"tokens_in":1234}}')
assert "data.tokens_in → gen_ai.usage.input_tokens (value preserved)" \
  "[ \"\$(jval \"\$out\" '.data[\"gen_ai.usage.input_tokens\"]')\" = '1234' ]"

# Mapping 4: data.tokens_out → gen_ai.usage.output_tokens
out=$(otel::rename_line '{"schema":"baton.event.v1","event":"x","data":{"tokens_out":567}}')
assert "data.tokens_out → gen_ai.usage.output_tokens (value preserved)" \
  "[ \"\$(jval \"\$out\" '.data[\"gen_ai.usage.output_tokens\"]')\" = '567' ]"

# Mapping 5: data.tool_name → gen_ai.tool.name
out=$(otel::rename_line '{"schema":"baton.event.v1","event":"x","data":{"tool_name":"Bash"}}')
assert "data.tool_name → gen_ai.tool.name (value preserved)" \
  "[ \"\$(jval \"\$out\" '.data[\"gen_ai.tool.name\"]')\" = 'Bash' ]"

# Mapping 6: data.session_id → gen_ai.conversation.id
out=$(otel::rename_line '{"schema":"baton.event.v1","event":"x","data":{"session_id":"sess-abc"}}')
assert "data.session_id → gen_ai.conversation.id (value preserved)" \
  "[ \"\$(jval \"\$out\" '.data[\"gen_ai.conversation.id\"]')\" = 'sess-abc' ]"

echo "## otel::rename_line - negative cases"

# Negative 1: unknown data.* key passes through unchanged
out=$(otel::rename_line '{"schema":"baton.event.v1","event":"x","data":{"custom_field":"keep_me"}}')
assert "unknown data.* key passes through unchanged" \
  "[ \"\$(jval \"\$out\" '.data.custom_field')\" = 'keep_me' ]"

# Negative 2: top-level envelope field (event) is not renamed
out=$(otel::rename_line '{"schema":"baton.event.v1","event":"checkpoint_written","ts":"2026-05-14T00:00:00Z","data":{}}')
assert "top-level 'event' field not renamed" \
  "[ \"\$(jval \"\$out\" '.event')\" = 'checkpoint_written' ]"

echo "## otel::rename_line - stability after rename"

# Stability 1: running twice yields same output as once (provider key)
in='{"schema":"baton.event.v1","event":"x","data":{"provider":"anthropic","model":"claude-opus-4-7"}}'
once=$(otel::rename_line "$in")
twice=$(otel::rename_line "$once")
assert "stability: rename twice equals rename once (provider+model)" \
  "[ \"\$(echo \"\$once\" | jq -cS .)\" = \"\$(echo \"\$twice\" | jq -cS .)\" ]"

# Stability 2: running twice yields same output as once (all keys + unknown)
in='{"schema":"baton.event.v1","event":"x","data":{"provider":"a","model":"m","tokens_in":1,"tokens_out":2,"tool_name":"T","session_id":"S","custom":"c"}}'
once=$(otel::rename_line "$in")
twice=$(otel::rename_line "$once")
assert "stability: rename twice equals rename once (all keys + unknown)" \
  "[ \"\$(echo \"\$once\" | jq -cS .)\" = \"\$(echo \"\$twice\" | jq -cS .)\" ]"

echo
echo "====================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
