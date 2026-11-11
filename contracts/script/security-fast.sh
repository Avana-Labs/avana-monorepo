#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Fast security tier: runs on every commit and pull request in a few minutes.
#
#   fmt            forge fmt --check
#   size           script/check-file-size.sh (Q-240)
#   licence        script/check-licence.sh: the BUSL-1.1 SPDX and Avana Labs copyright header on every Avana-owned
#                  .sol file, the identifier in security/licence-allowlist.txt on each ported file, and no UNLICENSED
#   lint           forge lint -D notes on src/ (rules and exclusions in foundry.toml [lint])
#   build          forge build src --force --build-info --extra-output storageLayout --sizes of src/ into
#                  out-security/build/src, warnings denied and every runtime code within 24,576 bytes; Slither and the
#                  layout step read this build, so out/ and cache/ are never cleaned or overwritten
#   cvl            certora/check-methods.py: every methods entry of every CVL spec in certora/specs names a function,
#                  with its parameter and return types, that exists in the interface ABIs of the build above
#   solhint        solhint with .solhint.json on src/**/*.sol, zero warnings
#   slither        Slither with slither.config.json; gate at informational, triage in security/slither-triage.json
#   upgradeability slither-check-upgradeability on every deployable src/ contract that inherits Initializable
#   aderyn         Aderyn with aderyn.toml; gate at low, triage in security/aderyn-triage.json
#   semgrep        Semgrep with the pinned smart-contract rules in tools/semgrep-smart-contracts/solidity on src/; gate
#                  at low (rule severity INFO and above, performance rules reported only), triage in
#                  security/semgrep-triage.json; any Semgrep error (parse failure, rule timeout) fails the step
#   4naly3er       4naly3er (tools/4naly3er) on src/, one run per src/ area; gate at low (H, M and L issues; NC and
#                  GAS reported only), triage in security/4naly3er-triage.json
#   layout         script/storage-layout.js: storage-layout snapshots in security/storage-layout/ of every
#                  upgradeable src/ contract and every contract sharing its ERC-7201 namespace (any change to an
#                  existing slot fails), then OpenZeppelin upgrades-core `validate` on the build
#
# Every step runs even after an earlier one fails, so one run reports everything; the script exits 1 when any step
# fails (a finding at or above its gate that is not triaged, or a tool error). Reports go to out-security/.
#
# Usage, from contracts/:  script/security-fast.sh [step ...]     (no step: all, in the order above)

set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=out-security
BUILD="$OUT/build/src"
export PATH="$ROOT/tools/bin:$ROOT/.venv/bin:$HOME/.foundry/bin:$PATH"
PY="$ROOT/.venv/bin/python"

mkdir -p "$OUT"
failed=()

require() {
  for bin in "$@"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "missing $bin: run script/install-security-tools.sh" >&2
      return 1
    fi
  done
}

step_fmt() { forge fmt --check; }

step_size() { script/check-file-size.sh; }

step_licence() { script/check-licence.sh; }

step_lint() { forge lint -D notes 2>&1 | tee "$OUT/forge-lint.txt"; }

step_build() {
  rm -rf "$BUILD" "$BUILD-cache"
  # Dynamic test linking writes foundry-pp/DeployHelper sources that crytic-compile cannot resolve; the security
  # build needs none of them, so it is built without it. Only src/ is compiled: `--skip test` skips `.t.sol` files
  # only, and a test helper under a compilation restriction puts shared src/ contracts into a second profile.
  FOUNDRY_DYNAMIC_TEST_LINKING=false forge build src --force --build-info --extra-output storageLayout --sizes \
    --skip test --skip script -D warnings --out "$BUILD" --cache-path "$BUILD-cache" 2>&1 | tee "$OUT/build-src.txt"
}

ensure_build() { [ -d "$BUILD/build-info" ] || step_build >/dev/null; }

step_cvl() {
  ensure_build || return 1
  "$PY" certora/check-methods.py --out "$BUILD" 2>&1 | tee "$OUT/cvl-methods.txt"
  return "${PIPESTATUS[0]}"
}

step_solhint() {
  require npx || return 1
  [ -x node_modules/.bin/solhint ] || { echo "missing solhint: run script/install-security-tools.sh --node" >&2; return 1; }
  node_modules/.bin/solhint --config .solhint.json --max-warnings 0 -f unix 'src/**/*.sol' 2>&1 | tee "$OUT/solhint.txt"
}

step_slither() {
  require slither || return 1
  ensure_build || return 1
  rm -f "$OUT/slither.json" "$OUT/slither.sarif"
  slither . --config-file slither.config.json >"$OUT/slither.log" 2>&1
  local rc=$?
  if [ ! -s "$OUT/slither.json" ]; then
    cat "$OUT/slither.log"
    echo "slither: no report written (exit $rc)" >&2
    return 1
  fi
  "$PY" script/security-gate.py slither "$OUT/slither.json" --triage security/slither-triage.json \
    --fail-on informational --summary "$OUT/slither-gate.txt"
}

step_upgradeability() {
  require slither-check-upgradeability || return 1
  ensure_build || return 1
  local contracts status=0
  contracts=$("$PY" script/security-list-upgradeable.py "$BUILD" 2>"$OUT/upgradeability-list.log") || {
    cat "$OUT/upgradeability-list.log"
    return 1
  }
  if [ -z "$contracts" ]; then
    echo "upgradeability: skipped, no deployable contract under src/ inherits Initializable or UUPSUpgradeable yet"
    return 0
  fi
  mkdir -p "$OUT/upgradeability"
  for c in $contracts; do
    echo "=== slither-check-upgradeability $c"
    rm -f "$OUT/upgradeability/$c.json"
    slither-check-upgradeability . "$c" --foundry-ignore-compile --foundry-out-directory "$BUILD" \
      --json "$OUT/upgradeability/$c.json" >"$OUT/upgradeability/$c.log" 2>&1
    if [ ! -s "$OUT/upgradeability/$c.json" ]; then
      cat "$OUT/upgradeability/$c.log"
      echo "upgradeability: no report for $c" >&2
      status=1
      continue
    fi
    "$PY" script/security-gate.py slither-upgradeability "$OUT/upgradeability/$c.json" \
      --triage security/slither-upgradeability-triage.json --fail-on informational || status=1
  done
  return $status
}

step_aderyn() {
  require aderyn || return 1
  rm -f "$OUT/aderyn.json" "$OUT/aderyn.sarif"
  aderyn . -o "$OUT/aderyn.json" >"$OUT/aderyn.log" 2>&1 && aderyn . -o "$OUT/aderyn.sarif" >>"$OUT/aderyn.log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ] || [ ! -s "$OUT/aderyn.json" ]; then
    cat "$OUT/aderyn.log"
    echo "aderyn: failed (exit $rc)" >&2
    return 1
  fi
  "$PY" script/security-gate.py aderyn "$OUT/aderyn.json" --triage security/aderyn-triage.json \
    --fail-on low --summary "$OUT/aderyn-gate.txt"
}

SEMGREP_RULES=tools/semgrep-smart-contracts/solidity
FOURNALYZER=tools/4naly3er

step_semgrep() {
  require semgrep || return 1
  [ -d "$SEMGREP_RULES" ] || { echo "missing Semgrep rules: run script/install-security-tools.sh --rules" >&2; return 1; }
  rm -f "$OUT/semgrep.json" "$OUT/semgrep.sarif"
  # --no-git-ignore scans every file under src/, tracked or not; the timeout is per rule and file, generous because
  # a rule that times out is an error, never a silent pass.
  semgrep scan --metrics=off --disable-version-check --no-git-ignore --quiet --timeout 300 --timeout-threshold 0 \
    --config "$SEMGREP_RULES" --exclude src/interfaces/external \
    --json-output="$OUT/semgrep.json" --sarif-output="$OUT/semgrep.sarif" src >"$OUT/semgrep.log" 2>&1
  local rc=$?
  if [ ! -s "$OUT/semgrep.json" ]; then
    cat "$OUT/semgrep.log"
    echo "semgrep: no report written (exit $rc)" >&2
    return 1
  fi
  "$PY" script/security-gate.py semgrep "$OUT/semgrep.json" --triage security/semgrep-triage.json \
    --fail-on low --summary "$OUT/semgrep-gate.txt"
}

step_4naly3er() {
  local ts="$FOURNALYZER/node_modules/.bin/ts-node"
  [ -x "$ts" ] || { echo "missing 4naly3er: run script/install-security-tools.sh --4naly3er" >&2; return 1; }
  local dir="$OUT/4naly3er" area status=0
  rm -rf "$dir" "$OUT/4naly3er.md"
  mkdir -p "$dir"
  # One run per src/ area (src/<area>/): 4naly3er compiles its whole scope in one solc-js call, and the WebAssembly
  # compiler runs out of memory on all of src/ at once. Each run writes report.md into its working directory.
  for area in $(find src -name '*.sol' -not -path 'src/interfaces/external/*' | cut -d/ -f2 | sort -u); do
    mkdir -p "$dir/$area"
    find "src/$area" -name '*.sol' -not -path 'src/interfaces/external/*' | sort >"$dir/$area/scope.txt"
    if ! (cd "$dir/$area" && node "$ROOT/script/4naly3er-run.js" \
      "$ROOT/" scope.txt) >"$dir/$area/run.log" 2>&1 || [ ! -s "$dir/$area/report.md" ] ||
      grep -q 'Cannot compile AST\|import not found' "$dir/$area/run.log"; then
      tail -n 20 "$dir/$area/run.log"
      echo "4naly3er: run on src/$area failed (see $dir/$area/run.log)" >&2
      status=1
    fi
    cat "$dir/$area/report.md" >>"$OUT/4naly3er.md" 2>/dev/null
  done
  [ $status -eq 0 ] || return 1
  "$PY" script/security-gate.py 4naly3er "$OUT/4naly3er.md" --triage security/4naly3er-triage.json \
    --fail-on low --summary "$OUT/4naly3er-gate.txt"
}

step_layout() {
  require node || return 1
  local oz=node_modules/.bin/openzeppelin-upgrades-core
  [ -x "$oz" ] || { echo "missing @openzeppelin/upgrades-core: run script/install-security-tools.sh --node" >&2; return 1; }
  ensure_build || return 1
  local status=0
  node script/storage-layout.js "$BUILD" --snapshots security/storage-layout 2>&1 | tee "$OUT/storage-layout.txt"
  [ "${PIPESTATUS[0]}" -eq 0 ] || status=1
  # Allowed by design, every other check (selfdestruct, initializers, upgradeToAndCall, linked libraries) runs:
  #   constructor               each implementation constructor only calls _disableInitializers and sets immutables
  #   state-variable-immutable  per-chain addresses fixed in the implementation (REQ-ARCH-048), read by the proxy
  #   delegatecall              the router's calls into its immutable logic contracts and OpenZeppelin's
  #                             upgradeToAndCall; the logic contracts share the proxy's namespace (checked above)
  "$oz" validate "$BUILD/build-info" --unsafeAllow constructor,state-variable-immutable,delegatecall \
    >"$OUT/oz-upgrades-validate.txt" 2>&1 || status=1
  grep -E '✔|✘|SUCCESS|FAILED|Error' "$OUT/oz-upgrades-validate.txt" || cat "$OUT/oz-upgrades-validate.txt"
  return $status
}

ALL=(fmt size licence lint build cvl solhint slither upgradeability aderyn semgrep 4naly3er layout)
steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=("${ALL[@]}")

for s in "${steps[@]}"; do
  if ! declare -F "step_$s" >/dev/null; then
    echo "security-fast: unknown step $s (steps: ${ALL[*]})" >&2
    exit 2
  fi
  echo
  echo "##### $s"
  start=$SECONDS
  if "step_$s"; then
    echo "##### $s: pass ($((SECONDS - start))s)"
  else
    echo "##### $s: FAIL ($((SECONDS - start))s)"
    failed+=("$s")
  fi
done

echo
if [ ${#failed[@]} -gt 0 ]; then
  echo "security-fast: FAIL in ${failed[*]} (reports in $OUT/)"
  exit 1
fi
echo "security-fast: every step passed (reports in $OUT/)"
