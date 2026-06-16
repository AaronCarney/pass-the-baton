#!/usr/bin/env bash
# lib/eventlog.sh - tolerant reader for the hook-events.jsonl append stream (CC20).
# The event log is a BEST-EFFORT append stream, not a guaranteed-clean file:
# crash / VM-pause zero-fill can leave NUL runs or blank lines that abort a
# naive single-`jq`/`read_json_auto` mid-stream, silently hiding every later
# event. The writer (lib/envelope.sh) flocks writes >512 bytes
# and prepends a newline on torn tails; smaller writes rely on atomic O_APPEND.
# Neither prevents crash zero-fill, and fsync-per-event is not worth it for an
# observability log - so tolerance lives on the READ side. eventlog::stream
# emits only valid JSON records (one compact object per line), preserving input
# order. Route every intolerant record-parsing reader of the PLAIN log through
# it. Readers that already tolerate malformed lines and/or glob .zst shards
# (latency.sh's stream_events, query.sh's DuckDB ignore_errors) keep their path.
#
# Usage:  eventlog::stream [FILE...]   # no args → reads stdin
eventlog::stream() {
  jq -cR 'fromjson? // empty' "$@"
}
