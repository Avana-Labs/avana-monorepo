#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Regression test for hevm-compatible signatures emitted by security-targets.py.

set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/build/AaveAdapter.sol"
cat >"$TMP/build/AaveAdapter.sol/AaveAdapter.json" <<'JSON'
{
  "ast": {"absolutePath": "src/AaveAdapter.sol"},
  "abi": [
    {"type": "function", "name": "allowWithdraw", "inputs": [
      {"type": "address"}, {"type": "bytes32"}, {"type": "uint128"}, {"type": "bytes"}
    ]},
    {"type": "function", "name": "collectFees", "inputs": [
      {"type": "uint256"}, {"type": "bytes32[]"}
    ]},
    {"type": "function", "name": "multicall", "inputs": [
      {"type": "bytes[]"}
    ]},
    {"type": "function", "name": "repay", "inputs": [
      {"type": "uint256"}
    ]}
  ]
}
JSON

PYTHON="${PYTHON:-python3}"
"$PYTHON" script/security-targets.py external-sigs "$TMP/build" AaveAdapter >"$TMP/actual"
cat >"$TMP/expected" <<'SIGS'
allowWithdraw(address,bytes32,uint128,bytes memory)
collectFees(uint256,bytes32[] memory)
multicall(bytes[] memory)
repay(uint256)
SIGS
tr -d '\r' <"$TMP/actual" >"$TMP/normalized"
diff -u "$TMP/expected" "$TMP/normalized"
