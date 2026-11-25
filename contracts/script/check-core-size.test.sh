#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Regression test of script/check-core-size.sh on fixture src/ folders.
#
#   1. Comment lines (line, NatSpec and block comments) and blank lines are not counted.
#   2. A tree within every limit passes.
#   3. One core contract over 800 code lines fails, counting its libraries.
#   4. The core total over 4,000 fails while each contract stays within 800.
#   5. The policy part (AaveAdapter + RiskModule) over 1,500 fails.
#   6. The AMM parts are not counted in the core total.
#   7. A .sol file outside every listed file and folder fails, at the top of src/ or in src/libraries/.
#
# Usage, from contracts/:  script/check-core-size.test.sh

set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CORE="AaveAdapter RiskModule LPVault VaultToken LPOracle LiquidationModule FirstLossReserve"

sol() { # <file> <code lines>: a contract with that many code lines, plus comments and blanks that do not count
  mkdir -p "$(dirname "$1")"
  {
    echo "// SPDX-License-Identifier: BUSL-1.1"
    echo "/// @notice NatSpec"
    echo "/* block"
    echo "   comment */"
    echo ""
    for _ in $(seq 1 "$2"); do echo "uint256 constant X = 1; // trailing comment"; done
  } >"$1"
}

tree() { # <dir> <lines per core contract>
  rm -rf "$1"
  for c in $CORE; do sol "$1/$c.sol" "$2"; done
  sol "$1/integrations/A.sol" 5000
}

fail=0
expect() { # <description> <expected status: pass|fail> <dir>
  local got=pass
  script/check-core-size.sh "$3" >"$TMP/log" 2>&1 || got=fail
  if [ "$got" = "$2" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1 (expected $2, got $got)"
    sed 's/^/     /' "$TMP/log"
    fail=1
  fi
}

tree "$TMP/ok" 100
expect "a tree within every limit passes, AMM parts not counted" pass "$TMP/ok"
grep -Eq '^VaultToken .* 100 ' "$TMP/log" || { echo "FAIL comments or blanks were counted"; fail=1; }
grep -Eq '^core total .* 700 ' "$TMP/log" || { echo "FAIL the core total counted the AMM parts"; fail=1; }

tree "$TMP/one" 100
sol "$TMP/one/libraries/LPPriceMath.sol" 701
expect "one contract over 800 with its library fails" fail "$TMP/one"

tree "$TMP/total" 600
expect "core total over 4,000 fails" fail "$TMP/total"

tree "$TMP/policy" 100
sol "$TMP/policy/AaveAdapter.sol" 760
sol "$TMP/policy/RiskModule.sol" 760
expect "policy part over 1,500 fails" fail "$TMP/policy"

tree "$TMP/stray" 100
sol "$TMP/stray/misc/P.sol" 1
expect "a file outside every listed file and folder fails" fail "$TMP/stray"

tree "$TMP/library" 100
sol "$TMP/library/libraries/Stray.sol" 1
expect "a library of no core contract fails" fail "$TMP/library"

tree "$TMP/periphery" 100
sol "$TMP/periphery/FlashloanRepay.sol" 900
expect "a periphery helper is outside the count" pass "$TMP/periphery"

exit "$fail"
