#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
source "$_SD/lib/sweep-aggregate.sh"

PASS=0; FAIL=0
assert() { local name="$1" cond="$2"; if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi; }

m=$(printf '1\n2\n3\n4\n5\n' | sweep_agg::quantile 0.50)
assert 'median odd' "[ \"$m\" = '3.000000' ]"

m=$(printf '1\n2\n3\n4\n' | sweep_agg::quantile 0.50)
assert 'median even returns a defined value' "printf '%s' \"$m\" | grep -qE '^[0-9]+\\.[0-9]+$'"

p=$(seq 1 100 | sweep_agg::quantile 0.95)
assert 'p95 of 1..100 == 95' "[ \"$p\" = '95.000000' ]"

q25=$(seq 1 100 | sweep_agg::quantile 0.25)
q75=$(seq 1 100 | sweep_agg::quantile 0.75)
assert 'p25 of 1..100 == 25' "[ \"$q25\" = '25.000000' ]"
assert 'p75 of 1..100 == 75' "[ \"$q75\" = '75.000000' ]"

mn=$(seq 1 10 | sweep_agg::mean)
assert 'mean 1..10 == 5.5' "[ \"$mn\" = '5.500000' ]"

c=$(printf '1\n2\n3\n' | sweep_agg::count)
assert 'count == 3' "[ \"$c\" = '3' ]"

m=$(printf '' | sweep_agg::quantile 0.50)
assert 'empty stream median emits NaN sentinel' "[ \"$m\" = 'NaN' ]"
mn=$(printf '' | sweep_agg::mean)
assert 'empty stream mean emits NaN sentinel' "[ \"$mn\" = 'NaN' ]"
c=$(printf '' | sweep_agg::count)
assert 'empty stream count == 0' "[ \"$c\" = '0' ]"

out=$(seq 1 100 | sweep_agg::summary_stats)
fields=$(printf '%s' "$out" | awk -F'\t' '{print NF}')
assert 'summary_stats emits 5 TAB-separated fields' "[ \"$fields\" = '5' ]"
med=$(printf '%s' "$out" | awk -F'\t' '{print $1}')
mean=$(printf '%s' "$out" | awk -F'\t' '{print $2}')
p95=$(printf '%s' "$out" | awk -F'\t' '{print $3}')
iqr=$(printf '%s' "$out" | awk -F'\t' '{print $4}')
cnt=$(printf '%s' "$out" | awk -F'\t' '{print $5}')
assert 'summary median 1..100' "[ \"$med\" = '50.000000' ] || [ \"$med\" = '50.500000' ]"
assert 'summary mean 1..100 == 50.5' "[ \"$mean\" = '50.500000' ]"
assert 'summary p95 1..100 == 95' "[ \"$p95\" = '95.000000' ]"
assert 'summary iqr 1..100 == 50' "[ \"$iqr\" = '50.000000' ]"
assert 'summary count 1..100 == 100' "[ \"$cnt\" = '100' ]"

md=$(printf '20\n22\n22\n22\n24\n26\n26\n' | sweep_agg::mode)
assert 'mode picks the most-frequent integer' "[ \"$md\" = '22' ]"

md=$(printf '20\n22\n22\n26\n26\n' | sweep_agg::mode)
assert 'mode tie-break: lowest int wins' "[ \"$md\" = '22' ]"

md=$(printf '' | sweep_agg::mode)
assert 'mode empty stream emits NaN' "[ \"$md\" = 'NaN' ]"

# Empty-stream summary_stats: must report count=0 (not 1 - the bug was that
# printf '%s\n' "" emitted a single blank line that awk counted as NR=1).
out=$(printf '' | sweep_agg::summary_stats)
cnt=$(printf '%s' "$out" | awk -F'\t' '{print $5}')
med=$(printf '%s' "$out" | awk -F'\t' '{print $1}')
assert 'empty-stream summary_stats count is 0 (not 1)' "[ \"$cnt\" = '0' ]"
assert 'empty-stream summary_stats median is NaN sentinel' "[ \"$med\" = 'NaN' ]"
# Mirror via an empty file (production path: per-threshold files start empty).
TMPSWP=$(mktemp -d); trap 'rm -rf "$TMPSWP"' EXIT
: > "$TMPSWP/empty"
out=$(sweep_agg::summary_stats < "$TMPSWP/empty")
cnt=$(printf '%s' "$out" | awk -F'\t' '{print $5}')
assert 'empty-FILE summary_stats count is 0' "[ \"$cnt\" = '0' ]"

assert 'no network in lib/sweep-aggregate.sh' "! grep -E 'curl|wget|\\bnc\\b|/dev/tcp' \"$_SD/lib/sweep-aggregate.sh\""
assert 'lib parses' "bash -n \"$_SD/lib/sweep-aggregate.sh\""

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
