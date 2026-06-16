#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PASS=0; FAIL=0
assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$label" >&2; fi
}

# Loud-fail under CI, skip cleanly locally.
if [ -n "${CI:-}" ] && ! python3 -c 'import bambi' 2>/dev/null; then
  echo 'CI requires bambi - install failed?'
  exit 1
fi
if [ -z "${CI:-}" ] && ! python3 -c 'import bambi' 2>/dev/null; then
  echo 'SKIP: bambi not installed locally'
  exit 0
fi

# --- F8: Bambi+nutpie API contract smoke (prove fit() works on minimal toy data) ---
echo 'test: bambi+nutpie API contract' >&2
python3 - <<'PY' || { echo 'FAIL F8: bambi+nutpie fit contract broken'; exit 1; }
import bambi as bmb, pandas as pd
m = bmb.Model('y ~ 1', pd.DataFrame({'y': [1.0, 2.0, 3.0, 4.0, 5.0]}))
idata = m.fit(inference_method='nutpie', draws=50, tune=50, chains=2, progressbar=False, random_seed=1)
assert idata is not None
print('API contract OK')
PY
echo ok

# --- Main self-check: passes hard gates and recovers variance components ---
echo 'test: hierarchical --self-check passes hard gates and recovers variance components (F15)' >&2
sc_tmpfile=$(mktemp /tmp/hm-sc-out.XXXXXX)
timeout 300 python3 "$REPO_ROOT/tools/hierarchical-model.py" --self-check --seed 42 > "$sc_tmpfile" 2>&1 \
  || { echo 'FAIL self-check exit'; cat "$sc_tmpfile"; rm -f "$sc_tmpfile"; exit 1; }
grep -q 'gates_passed=true' "$sc_tmpfile" \
  || { echo 'FAIL no gates_passed=true'; cat "$sc_tmpfile"; rm -f "$sc_tmpfile"; exit 1; }
grep -q 'self-check OK' "$sc_tmpfile" \
  || { echo 'FAIL no self-check OK'; cat "$sc_tmpfile"; rm -f "$sc_tmpfile"; exit 1; }
PASS=$((PASS+1))

# F15: parse variance components from file and assert within 15% of truth.
# Truths in hierarchical-model.py _self_check: workspace=1.0, project=0.5, residual=0.25
python3 - "$sc_tmpfile" <<'PY' || { rm -f "$sc_tmpfile"; exit 1; }
import re, sys
with open(sys.argv[1]) as fh:
    out = fh.read()
truths = {'workspace': 1.0, 'project': 0.5, 'residual': 0.25}
for key, truth in truths.items():
    m = re.search(rf'sigma_{key}=([0-9.]+)', out)
    assert m, f'F15: sigma_{key} not in output:\n{out}'
    rec = float(m.group(1))
    err = abs(rec - truth) / truth
    assert err < 0.15, f'F15: sigma_{key} recovery {rec} vs truth {truth} err={err:.3f} (>= 0.15)'
print('F15 ok')
PY
rm -f "$sc_tmpfile"
echo ok

# --- F14: deterministic bad-fit MUST flag gates_passed:false with ess_bulk violation ---
echo 'test: hierarchical hard gates fail loudly on deterministic bad fit (F14)' >&2
python3 -c "
import json, numpy as np
rng = np.random.default_rng(99)
# 12-row dataset, 2 workspaces x 2 projects x 3 sessions; intentionally tiny + noisy.
for w in range(2):
    for p in range(2):
        for s in range(3):
            print(json.dumps({'workspace': f'w{w}', 'project': f'w{{w}}/p{{p}}', 'session': f's{{s}}', 'y': float(rng.normal(0,1))}))
" > /tmp/badfit.jsonl
set +e
python3 "$REPO_ROOT/tools/hierarchical-model.py" --input /tmp/badfit.jsonl --run-id _badfit --draws 50 --tune 10 --chains 2 --seed 42 > /tmp/badfit.out 2>&1
rc=$?
set -e
# F14: REQUIRE exact gates_passed:false (no rc-fallback).
grep -qE '"gates_passed"[[:space:]]*:[[:space:]]*false' /tmp/badfit.out \
  || { echo 'FAIL F14: bad fit did not emit gates_passed:false'; cat /tmp/badfit.out; exit 1; }
grep -qE 'ess_bulk' /tmp/badfit.out \
  || { echo 'FAIL F14: bad fit did not name ess_bulk in failed_gates'; cat /tmp/badfit.out; exit 1; }
[ $rc -ne 0 ] \
  || { echo 'FAIL F14: rc must be non-zero on failed gates'; exit 1; }
echo ok

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
