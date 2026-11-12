#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# Runs one shard of the Foundry suite: every test file under test/ (fork and differential excluded, as in the default
# profile), with each invariant of test/invariant/ as a unit of its own, split over N shards of about equal run time by
# script/test-shard.py from the measured times in script/test-timings.json. Every unit lands in exactly one shard.
# Extra arguments go to `forge test`. Refresh the times from the shard logs of a full run on main:
# script/update-test-timings.py <log>...
#
# Usage, from contracts/:  script/test-shard.sh <K> <N> [forge test arguments]
#                          script/test-shard.sh --list <K> <N>     (print the shard's units)
set -euo pipefail
list=0
if [ "${1:-}" = --list ]; then list=1; shift; fi
K=${1:?usage: test-shard.sh [--list] <K> <N> [forge args]}; N=${2:?usage: test-shard.sh [--list] <K> <N> [forge args]}; shift 2
[ "$K" -ge 1 ] && [ "$K" -le "$N" ] || { echo "shard $K is outside 1..$N" >&2; exit 2; }
units=$(python3 script/test-shard.py "$K" "$N")
[ -n "$units" ] || { echo "shard $K of $N has no units"; exit 0; }
if [ "$list" = 1 ]; then echo "$units"; exit 0; fi
echo "shard $K of $N: $(echo "$units" | wc -l | tr -d ' ') units"
# Whole files run in one forge invocation; each invariant unit (<file>::<invariant>) runs on its own. Every invocation
# runs even after one fails, and the shard fails if any failed.
rc=0
files=$(echo "$units" | grep -v '::' || true)
if [ -n "$files" ]; then
  glob="{$(echo "$files" | paste -sd, -)}"
  forge test --match-path "$glob" "$@" || rc=1
fi
while IFS= read -r unit; do
  [ -n "$unit" ] || continue
  echo "invariant unit: $unit"
  forge test --match-path "${unit%%::*}" --match-test "^${unit##*::}\\(" "$@" || rc=1
done <<< "$(echo "$units" | grep '::' || true)"
exit $rc
