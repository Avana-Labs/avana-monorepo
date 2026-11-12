#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# Runs one shard of the Foundry suite: every test file under test/ (fork and differential excluded, as in the default
# profile), split over N shards of about equal run time by script/test-shard.py from the measured times in
# script/test-timings.json. Every file lands in exactly one shard. Extra arguments go to `forge test`.
# Refresh the times from the ten shard logs of a full run on main: script/update-test-timings.py <log>...
#
# Usage, from contracts/:  script/test-shard.sh <K> <N> [forge test arguments]
#                          script/test-shard.sh --list <K> <N>     (print the shard's files)
set -euo pipefail
list=0
if [ "${1:-}" = --list ]; then list=1; shift; fi
K=${1:?usage: test-shard.sh [--list] <K> <N> [forge args]}; N=${2:?usage: test-shard.sh [--list] <K> <N> [forge args]}; shift 2
[ "$K" -ge 1 ] && [ "$K" -le "$N" ] || { echo "shard $K is outside 1..$N" >&2; exit 2; }
files=$(python3 script/test-shard.py "$K" "$N")
[ -n "$files" ] || { echo "shard $K of $N has no files"; exit 0; }
if [ "$list" = 1 ]; then echo "$files"; exit 0; fi
echo "shard $K of $N: $(echo "$files" | wc -l | tr -d ' ') files"
glob="{$(echo "$files" | paste -sd, -)}"
exec forge test --match-path "$glob" "$@"
