#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# Runs one shard of the Foundry suite: every test file under test/ (fork and differential excluded, as in the default
# profile), sorted by path and dealt round-robin over N shards, so shard K of N runs files K, K+N, K+2N, ... Every file
# lands in exactly one shard. Extra arguments go to `forge test`.
#
# Usage, from contracts/:  script/test-shard.sh <K> <N> [forge test arguments]
#                          script/test-shard.sh --list <K> <N>     (print the shard's files)
set -euo pipefail
list=0
if [ "${1:-}" = --list ]; then list=1; shift; fi
K=${1:?usage: test-shard.sh [--list] <K> <N> [forge args]}; N=${2:?usage: test-shard.sh [--list] <K> <N> [forge args]}; shift 2
[ "$K" -ge 1 ] && [ "$K" -le "$N" ] || { echo "shard $K is outside 1..$N" >&2; exit 2; }
files=$(find test -name '*.t.sol' -type f ! -path 'test/fork/*' ! -path 'test/differential/*' | LC_ALL=C sort |
  awk -v k="$K" -v n="$N" '(NR - 1) % n == k - 1')
[ -n "$files" ] || { echo "shard $K of $N has no files"; exit 0; }
if [ "$list" = 1 ]; then echo "$files"; exit 0; fi
echo "shard $K of $N: $(echo "$files" | wc -l | tr -d ' ') files"
glob="{$(echo "$files" | paste -sd, -)}"
exec forge test --match-path "$glob" "$@"
