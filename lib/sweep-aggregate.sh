#!/usr/bin/env bash
# lib/sweep-aggregate.sh - per-threshold summary stats (basic rigor).
# Pure: sourced, no top-level execution, no network. Awk LC_ALL=C math.
# Producer of contract agg-stats consumed by tools/cost-sweep-corpus.sh.
set -uo pipefail

sweep_agg::quantile() {
  local q="$1"
  LC_ALL=C awk -v q="$q" '
    function ceil(x) { return (x == int(x)) ? x : int(x)+1 }
    { v[NR]=$1+0 }
    END {
      if (NR == 0) { print "NaN"; exit }
      for (i=2;i<=NR;i++) { x=v[i]; j=i-1; while (j>=1 && v[j]>x) { v[j+1]=v[j]; j-- } v[j+1]=x }
      idx = ceil(q*NR)
      if (idx < 1) idx = 1
      if (idx > NR) idx = NR
      printf "%.6f\n", v[idx]
    }'
}

sweep_agg::mean() {
  LC_ALL=C awk '
    { s+=$1+0; n++ }
    END { if (n==0) print "NaN"; else printf "%.6f\n", s/n }'
}

sweep_agg::count() {
  LC_ALL=C awk 'END { print NR+0 }'
}

sweep_agg::summary_stats() {
  local stream; stream="$(cat)"
  # Empty-stream guard: printf '%s\n' "" yields a single blank line, which
  # downstream awk would count as NR=1 (wrong). Branch explicitly so the
  # row reports NaN/NaN/NaN/NaN/0 - matching the existing per-helper sentinels
  # (quantile/mean → NaN, count → 0).
  if [ -z "$stream" ]; then
    printf 'NaN\tNaN\tNaN\tNaN\t0\n'
    return 0
  fi
  local med mean p95 q25 q75 cnt iqr
  med=$(printf '%s\n' "$stream" | sweep_agg::quantile 0.50)
  mean=$(printf '%s\n' "$stream" | sweep_agg::mean)
  p95=$(printf '%s\n' "$stream" | sweep_agg::quantile 0.95)
  q25=$(printf '%s\n' "$stream" | sweep_agg::quantile 0.25)
  q75=$(printf '%s\n' "$stream" | sweep_agg::quantile 0.75)
  cnt=$(printf '%s\n' "$stream" | sweep_agg::count)
  if [ "$q25" = 'NaN' ] || [ "$q75" = 'NaN' ]; then iqr='NaN'
  else iqr=$(LC_ALL=C awk -v a="$q75" -v b="$q25" 'BEGIN{printf "%.6f", a-b}')
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$med" "$mean" "$p95" "$iqr" "$cnt"
}

sweep_agg::mode() {
  LC_ALL=C awk '
    { c[$1]++ }
    END {
      if (length(c)==0) { print "NaN"; exit }
      best=""; bestcount=-1
      n=0; for (k in c) keys[n++]=k+0
      asort(keys)
      for (i=1;i<=n;i++) if (c[keys[i]] > bestcount) { bestcount=c[keys[i]]; best=keys[i] }
      print best
    }'
}
