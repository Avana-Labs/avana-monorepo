#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# Runs one shard of the Foundry suite: every test file under test/ (fork and differential excluded, as in the default
# profile), split over N shards of about equal run time by script/test-shard.py from the measured times in
# script/test-timings.json. A file of test/invariant/ is one invariant campaign; a campaign too long for one shard is
# split into segments `<file>@<k>/<m>`, each running ceil(runs / m) of its runs at the same depth with a seed of its
# own. Every unit lands in exactly one shard. Extra arguments go to `forge test`. Refresh the times from the shard logs
# of a full run on main: script/update-test-timings.py <log>...
#
# Usage, from contracts/:  script/test-shard.sh <K> <N> [forge test arguments]
#                          script/test-shard.sh --list <K> <N>     (print the shard's units)
#                          script/test-shard.sh --unit <unit> [forge test arguments]   (one unit, as printed by
#                                                                  script/hotfix-units.py or --list)
set -euo pipefail
list=0
if [ "${1:-}" = --unit ]; then
  units=${2:?usage: test-shard.sh --unit <unit> [forge args]}
  shift 2
  echo "unit: $units"
else
  if [ "${1:-}" = --list ]; then list=1; shift; fi
  K=${1:?usage: test-shard.sh [--list] <K> <N> [forge args]}; N=${2:?usage: test-shard.sh [--list] <K> <N> [forge args]}; shift 2
  [ "$K" -ge 1 ] && [ "$K" -le "$N" ] || { echo "shard $K is outside 1..$N" >&2; exit 2; }
  units=$(python3 script/test-shard.py "$K" "$N")
  [ -n "$units" ] || { echo "shard $K of $N has no units"; exit 0; }
  if [ "$list" = 1 ]; then echo "$units"; exit 0; fi
  echo "shard $K of $N: $(echo "$units" | wc -l | tr -d ' ') units"
fi

# segment_args <k> [forge args]: the arguments with --fuzz-seed moved by k * 2^32 (0xa7a7a, foundry.toml's seed, when
# none is given), so no two segments of a campaign run the same sequences, in this shard or another.
segment_args() {
  local k=$1 seed="" out=() prev=""
  shift
  for a in "$@"; do
    if [ "$prev" = --fuzz-seed ]; then seed=$a; prev=""; continue; fi
    if [ "$a" = --fuzz-seed ]; then prev=$a; continue; fi
    out+=("$a")
  done
  printf '%s\n' --fuzz-seed "$(printf '0x%x' $(( ${seed:-0xa7a7a} + k * 4294967296 )))" ${out[@]+"${out[@]}"}
}

# Whole files run in one forge invocation; each segment runs on its own. Every invocation runs even after one fails,
# and the shard fails if any failed.
rc=0
files=$(echo "$units" | grep -v '@' || true)
if [ -n "$files" ]; then
  glob="{$(echo "$files" | paste -sd, -)}"
  forge test --match-path "$glob" "$@" || rc=1
fi
segments=$(echo "$units" | grep '@' || true)
if [ -n "$segments" ]; then
  runs=$(python3 script/test-shard.py --runs)
  while IFS= read -r unit; do
    file=${unit%@*}; part=${unit##*@}; k=${part%/*}; m=${part#*/}
    seg_runs=$(( (runs + m - 1) / m ))
    echo "invariant campaign segment: $file, part $k of $m, $seg_runs of $runs runs"
    args=()
    while IFS= read -r a; do args+=("$a"); done < <(segment_args "$k" "$@")
    FOUNDRY_INVARIANT_RUNS=$seg_runs forge test --match-path "$file" "${args[@]}" || rc=1
  done <<< "$segments"
fi
exit $rc
