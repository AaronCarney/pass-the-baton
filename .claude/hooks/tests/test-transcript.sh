#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib/transcript.sh"
PASS=0; FAIL=0; FAILED=()
assert() { local n="$1" c="$2"; if eval "$c"; then PASS=$((PASS+1)); echo "  PASS  $n"; else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n"; fi; }

t=$(mktemp -d)
cat > "$t/s.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"role":"assistant","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":8000,"input_tokens":500,"output_tokens":1500}}}
{"type":"assistant","message":{"role":"assistant","usage":{"cache_read_input_tokens":8000,"ephemeral_5m_input_tokens":2000,"input_tokens":0,"output_tokens":1500}}}
{"corrupt json line that must be skipped
EOF

out=$(transcript::turn_stream "$t/s.jsonl")
assert "two assistant turns extracted" "[ \"\$(printf '%s\n' \"\$out\" | grep -c .)\" = '2' ]"
line1=$(printf '%s\n' "$out" | sed -n 1p)
assert "turn1 = cr0 cw5=8000 cw1=0 fi=500 out=1500" "[ \"\$line1\" = \$'0\t8000\t0\t500\t1500' ]"
line2=$(printf '%s\n' "$out" | sed -n 2p)
assert "turn2 ephemeral_5m maps to cw5=2000, cr=8000" "[ \"\$line2\" = \$'8000\t2000\t0\t0\t1500' ]"
assert "missing file -> empty, rc 0" "[ -z \"\$(transcript::turn_stream "$t/none.jsonl" 2>/dev/null)\" ]"
rm -rf "$t"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
