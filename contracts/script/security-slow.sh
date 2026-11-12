#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Slow security tier: on every push to main (.github/workflows/security-slow.yml), by hand (workflow_dispatch) and
# before a release; the layer gate runs its mutate, gambit and necessist steps.
#
#   build    first a strict pass: `forge build -D warnings` per group, so any warning in any file fails the step.
#            The groups are src/, then each folder of test/ (a folder of more than BUILD_CHUNK=60 files is split
#            into alphabetical chunks of that many files) and script/ when it holds Solidity. One compile of all of
#            them would stop at solc's limit of 256 warnings (warning 4591, fatal under -D warnings), since the test
#            contracts print about two contract-size warnings (5574, 3860) per file, which Foundry then ignores; each
#            group stays at about half that limit, and a group that still reaches it fails with its name. Then
#            forge build --force --build-info of src/, test/ and script/ into out-security/build/all, without
#            -D warnings since the strict pass found none; Echidna, Medusa, hevm and Mythril read this build, so
#            out/ and cache/ are never cleaned or overwritten. Strict-pass logs go to out-security/build-strict/
#   echidna  every `*Properties` harness in test/invariant/echidna/, in property mode and in assertion mode, each on
#            a build of its own file and imports (out-security/build/echidna/<Name>, slow-tier settings) with its heap
#            bounded by ECHIDNA_MAX_HEAP; corpora in out-security/corpus/ persist between runs
#   medusa   every `*Properties` harness in test/invariant/echidna/ and test/invariant/medusa/ (property and
#            assertion tests in one campaign)
#   halmos   every `check_` function in test/halmos/ (contract names ending in HalmosTest)
#   hevm     against a local anvil chain (see hevm_targets below): `hevm symbolic` on each assertion entry point of
#            every harness, deployed so its constructor has run (each must reach QED), on the runtime code of every
#            src/ contract and library with its address immutables filled (no assertion violation), and `hevm test`
#            on every `prove_` function in test/symbolic/
#   mythril  script/security-mythril.sh on the runtime code of every src/ contract and library
#   mutate   slither-mutate on every implementation file of the layers in security/mutation-layers.json, each mutant
#            run against its Foundry tests (`forge test -j 2 --match-path <tests>`) in an isolated copy of src/ and
#            test/ under out-security/mutation/root; uncaught mutants are listed per layer in
#            out-security/mutation/<layer>/survivors.txt and kept in out-security/mutation/<layer>/<Contract>/
#   gambit   script/security-gambit.sh: Gambit expression mutants of the same files (fixed seed, operators and per-file
#            cap from the `gambit` object of security/mutation-layers.json), each run against the same tests with a
#            per-mutant timeout in an isolated copy under out-security/gambit/root; survivors are listed in
#            out-security/gambit/<layer>/survivors.txt, and any survived or timed-out mutant not accepted in
#            security/gambit-triage.json fails the step
#   necessist  Necessist (tools/bin/necessist) on the test files of the same layers, in the same kind of isolated copy;
#            every statement whose removal leaves the tests passing is listed in out-security/necessist/<layer>.txt
#
# A step with nothing to run prints what it skipped and why and passes; a step whose targets exist fails on any
# failed property, counterexample, unproven harness assertion, untriaged finding or tool error. Every step runs even
# after an earlier one fails; the script exits 1 when any step fails. Reports go to out-security/.
#
# Budgets (environment, with defaults): ECHIDNA_TEST_LIMIT (echidna.yaml), ECHIDNA_TIMEOUT=900 and MEDUSA_TIMEOUT=900
# seconds per harness and mode, ECHIDNA_MAX_HEAP=8g (GHC heap limit), ECHIDNA_HARNESSES (space-separated harness
# names; empty: all), MEDUSA_TEST_LIMIT
# (medusa.json), HEVM_SMT_TIMEOUT=300 seconds per query,
# HALMOS_LOOP=8; BUILD_CHUNK=60 files per strict build group;
# MUTATE_LAYERS and MUTATE_CONTRACTS (space-separated; empty: every layer and contract of
# security/mutation-layers.json), MUTATE_TIMEOUT=300 seconds per mutant test run, MUTATE_FUZZ_RUNS=256,
# MUTATE_MUTATORS (comma-separated slither-mutate mutators; empty: all), NECESSIST_TIMEOUT=300 seconds per removal.
# GAMBIT_TIMEOUT=300 seconds per Gambit mutant test run, GAMBIT_FUZZ_RUNS (default MUTATE_FUZZ_RUNS).
# Selectors (environment, space-separated; empty: every target, as above), used by CI to run one target per job:
# ECHIDNA_HARNESSES and ECHIDNA_MODES (default "property assertion"), MEDUSA_HARNESSES, HALMOS_CONTRACTS (exact
# contract names, run as --match-contract '^(A|B)$'), HALMOS_TESTS (exact test function names, run as
# --match-test '^(a|b)\('), HEVM_TARGETS (`harness:<Name>`, `src:<Name>`, `test`),
# MYTHRIL_CONTRACTS (src/ contract names), MUTATE_LAYERS and MUTATE_CONTRACTS, NECESSIST_TESTS (test file paths).
# Survivors of `mutate` and `necessist` are a report for the layer gate review, not a failure; a tool error fails.
# Survivors of `gambit` fail until a test kills them or the layer gate review accepts them in the triage file.
#
# Usage, from contracts/:  script/security-slow.sh [step ...]     (no step: all, in the order above)

set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=out-security
BUILD="$OUT/build/all"
export PATH="$ROOT/tools/bin:$ROOT/.venv/bin:$HOME/.foundry/bin:$PATH"
PY="$ROOT/.venv/bin/python"
# Fuzzing corpora persist across runs (and across CI runs on main through the cache), so each campaign starts from
# every sequence that reached new coverage before.
CORPUS="$OUT/corpus"
ECHIDNA_DIR=test/invariant/echidna
MEDUSA_DIR=test/invariant/medusa

ECHIDNA_TIMEOUT=${ECHIDNA_TIMEOUT:-900}
ECHIDNA_MAX_HEAP=${ECHIDNA_MAX_HEAP:-8g}
MEDUSA_TIMEOUT=${MEDUSA_TIMEOUT:-900}
HEVM_SMT_TIMEOUT=${HEVM_SMT_TIMEOUT:-300}
HALMOS_LOOP=${HALMOS_LOOP:-8}

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

# slow_env <command...>: runs the command with the settings of the slow-tier build.
# Without dynamic test linking: its foundry-pp/DeployHelper sources are not resolvable by crytic-compile.
# With the CBOR metadata and its IPFS hash, which the release build drops (bytecode_hash = "none"): Echidna tells
# deployed contracts apart by the metadata hash in their runtime code, and without it a harness that deploys
# contracts in its constructor and keeps them in immutables crashes every worker with `Set.elemAt: index out of
# range` before the first call (crytic/echidna#1118). This build is read only by the slow-tier tools; the release
# bytecode check compares out/, which keeps foundry.toml's settings.
slow_env() { FOUNDRY_DYNAMIC_TEST_LINKING=false FOUNDRY_CBOR_METADATA=true FOUNDRY_BYTECODE_HASH=ipfs "$@"; }

BUILD_CHUNK=${BUILD_CHUNK:-60}

# build_groups: one line per strict build group, "<name><TAB><space-separated paths>". Every Solidity file of src/,
# test/ and script/ is in exactly one group; file names hold no spaces.
build_groups() {
  local d files
  printf 'src\tsrc\n'
  for d in test/*/ test script; do
    d=${d%/}
    if [ "$d" = test ]; then
      files=$(find test -maxdepth 1 -name '*.sol' | LC_ALL=C sort)
    else
      files=$(find "$d" -name '*.sol' | LC_ALL=C sort)
    fi
    [ -n "$files" ] || continue
    awk -v dir="$d" -v n="$BUILD_CHUNK" '
      { f[NR] = $0 }
      END {
        k = int((NR + n - 1) / n)
        for (i = 0; i < k; i++) {
          name = (k == 1) ? dir : sprintf("%s %d/%d", dir, i + 1, k)
          line = ""
          for (j = i * n + 1; j <= NR && j <= (i + 1) * n; j++) line = line (line == "" ? "" : " ") f[j]
          printf "%s\t%s\n", name, line
        }
      }' <<<"$files"
  done
}

# build_strict: `forge build -D warnings` of each group into a throwaway output, with the slow-tier settings.
build_strict() {
  local dir="$OUT/build-strict" status=0 name paths log slug
  rm -rf "$dir" && mkdir -p "$dir"
  while IFS=$'\t' read -r name paths; do
    slug=$(tr ' /' '__' <<<"$name")
    log="$dir/$slug.txt"
    echo "=== strict build: $name"
    # shellcheck disable=SC2086
    if ! slow_env forge build --force -D warnings $paths --out "$dir/$slug-out" --cache-path "$dir/$slug-cache" \
      >"$log" 2>&1; then
      status=1
      cat "$log"
      echo "build: $name has a warning or error (see $log)"
    fi
    if grep -qE '\(4591\)|more than 256 warnings' "$log"; then
      status=1
      echo "build: $name reached solc's limit of 256 warnings, so later warnings went unreported; lower BUILD_CHUNK"
    fi
    rm -rf "$dir/$slug-out" "$dir/$slug-cache"
  done < <(build_groups)
  return $status
}

step_build() {
  rm -rf "$BUILD" "$BUILD-cache"
  build_strict 2>&1 | tee "$OUT/build-all.txt"
  [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
  echo "=== build with build info: src/, test/ and script/" | tee -a "$OUT/build-all.txt"
  slow_env forge build --force --build-info --out "$BUILD" --cache-path "$BUILD-cache" 2>&1 | tee -a "$OUT/build-all.txt"
  return "${PIPESTATUS[0]}"
}

ensure_build() { [ -d "$BUILD/build-info" ] || step_build >/dev/null; }

# selected <selector> <name>: true when the selector (space-separated names) is empty or holds <name>.
selected() { [ -z "$1" ] || [[ " $1 " == *" $2 "* ]]; }

# unmatched <step> <selector> <seen>: fails, naming them, when the selector holds a name the step did not find, so a
# CI job given a target that no longer exists fails instead of passing with nothing run.
unmatched() {
  local n missing=()
  for n in $2; do [[ " $3 " == *" $n "* ]] || missing+=("$n"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  echo "$1: no such target: ${missing[*]}" >&2
  return 1
}

# harness_list <dir>...: "<Name><TAB><source>" per harness found in the build.
harness_list() { "$PY" script/security-targets.py harnesses "$BUILD" "$@"; }

# echidna_ran <log>: true when the campaign printed its summary with at least one call, no worker crashed, and no test
# failed or errored.
echidna_ran() {
  local log=$1 calls
  grep -qE 'Crashed|Please report it to https://github.com/crytic/echidna' "$log" && return 1
  calls=$(sed -nE 's/^Total calls: ([0-9]+).*/\1/p' "$log" | tail -n1)
  [ -n "$calls" ] && [ "$calls" -gt 0 ] || return 1
  grep -qE ': (failed|FAILED|falsified|error)' "$log" && return 1
  return 0
}

step_echidna() {
  require echidna || return 1
  ensure_build || return 1
  local list status=0 name source mode log limit=() seen=""
  list=$(harness_list "$ECHIDNA_DIR") || return 1
  if [ -z "$list" ]; then
    echo "echidna: skipped, $ECHIDNA_DIR/ holds no contract named *Properties"
    return 0
  fi
  [ -n "${ECHIDNA_TEST_LIMIT:-}" ] && limit=(--test-limit "$ECHIDNA_TEST_LIMIT")
  mkdir -p "$OUT/echidna"
  local hbuild config
  while IFS=$'\t' read -r name source; do
    selected "${ECHIDNA_HARNESSES:-}" "$name" || continue
    seen+=" $name"
    # Echidna loads every contract of the build it is given, with its source maps and coverage maps. On the build of
    # all of src/, test/ and script/ (about 470 MB of build info) a harness held 2.2 GB of live heap and 4.8 GB in all
    # before its first call, and every CI job died 8 to 13 minutes in with the runner shut down and no log; on a build
    # of the harness's own sources alone the same harness holds 28 MB (604 MB in all). So each harness gets that build,
    # with the slow-tier settings, and a copy of echidna.yaml that points crytic-compile at it.
    hbuild="$OUT/build/echidna/$name"
    config="$OUT/echidna/$name.yaml"
    echo "=== echidna $name: build of $source and its imports"
    if ! slow_env forge build "$source" --build-info --out "$hbuild" --cache-path "$hbuild-cache" \
      >"$OUT/echidna/$name-build.log" 2>&1; then
      cat "$OUT/echidna/$name-build.log"
      echo "echidna: the build of $name failed"
      status=1
      continue
    fi
    sed "s|\"out-security/build/all\"|\"$hbuild\"|" echidna.yaml >"$config"
    if ! grep -qF "\"$hbuild\"" "$config"; then
      echo "echidna: echidna.yaml has no cryticArgs build path to replace" >&2
      return 1
    fi
    for mode in ${ECHIDNA_MODES:-property assertion}; do
      echo "=== echidna $name ($source), $mode mode"
      mkdir -p "$CORPUS/echidna/$name-$mode"
      log="$OUT/echidna/$name-$mode.log"
      # --disable-slither: Echidna's own Slither pass analyses the whole project before fuzzing and fails ("Running
      # slither failed"), so it adds nothing but time; the project's Slither run is in the fast tier.
      # +RTS -M: a heap above ECHIDNA_MAX_HEAP ends Echidna with "Heap exhausted" and a failed step with its log,
      # instead of exhausting the machine. The log is also streamed, so a run that dies still shows how far it got.
      echidna . --config "$config" --contract "$name" --test-mode "$mode" --timeout "$ECHIDNA_TIMEOUT" \
        --disable-slither ${limit[@]+"${limit[@]}"} --corpus-dir "$CORPUS/echidna/$name-$mode" --format text \
        +RTS -M"$ECHIDNA_MAX_HEAP" -RTS 2>&1 | tee "$log" |
        grep --line-buffered -vE '^\[[^]]*\] +(\[Worker [0-9]+\] New coverage|Saved reproducer)'
      if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        status=1
        echo "echidna: $name failed in $mode mode"
      fi
      grep -E ': (passing|failed|FAILED|falsified|error)|Error|ERROR|Crashed|Heap exhausted|^Total calls' "$log" | grep -v '^\[' || true
      # Echidna exits 0 even when its workers crash, and then still prints every test as passing; a run counts only
      # when it executed calls and printed its summary.
      if ! echidna_ran "$log"; then
        status=1
        echo "echidna: $name did not fuzz in $mode mode (crash, no calls or no summary; see $log)"
      fi
    done
  done <<<"$list"
  unmatched echidna "${ECHIDNA_HARNESSES:-}" "$seen" || status=1
  return $status
}

step_medusa() {
  require medusa || return 1
  ensure_build || return 1
  local list status=0 name source limit=() seen=""
  list=$(harness_list "$ECHIDNA_DIR" "$MEDUSA_DIR") || return 1
  if [ -z "$list" ]; then
    echo "medusa: skipped, $ECHIDNA_DIR/ and $MEDUSA_DIR/ hold no contract named *Properties"
    return 0
  fi
  [ -n "${MEDUSA_TEST_LIMIT:-}" ] && limit=(--test-limit "$MEDUSA_TEST_LIMIT")
  # Medusa caches Slither's results for a build; a fresh build needs a fresh cache. The corpus is kept.
  rm -rf "$OUT/medusa" && mkdir -p "$OUT/medusa" "$CORPUS/medusa"
  while IFS=$'\t' read -r name source; do
    selected "${MEDUSA_HARNESSES:-}" "$name" || continue
    seen+=" $name"
    echo "=== medusa $name ($source)"
    if ! medusa fuzz --config medusa.json --target-contracts "$name" --timeout "$MEDUSA_TIMEOUT" ${limit[@]+"${limit[@]}"} \
      --corpus-dir "$CORPUS/medusa/$name" --no-color >"$OUT/medusa/$name.log" 2>&1; then
      status=1
      echo "medusa: $name failed"
    fi
    grep -E '\[(PASSED|FAILED)\]|Test summary|[Ee]rror' "$OUT/medusa/$name.log" || true
  done <<<"$list"
  unmatched medusa "${MEDUSA_HARNESSES:-}" "$seen" || status=1
  return $status
}

step_halmos() {
  require halmos || return 1
  if ! grep -rqs --include='*.sol' 'function check_' test/halmos; then
    echo "halmos: skipped, test/halmos/ holds no check_ function"
    return 0
  fi
  # HALMOS_CONTRACTS selects exact contract names and HALMOS_TESTS exact test function names (CI runs one of each per
  # job); halmos fails with "No tests with" when the selection matches no test.
  local match='HalmosTest$' tests=()
  [ -n "${HALMOS_CONTRACTS:-}" ] && match="^($(echo $HALMOS_CONTRACTS | tr ' ' '|'))\$"
  [ -n "${HALMOS_TESTS:-}" ] && tests=(--match-test "^($(echo $HALMOS_TESTS | tr ' ' '|'))\\(")
  # Halmos has no deployCode cheatcode, which dynamic test linking turns `new C(...)` into. PYTHONUNBUFFERED: each
  # result line reaches the log when the check ends, so a run stopped by a time limit still shows which checks passed.
  PYTHONUNBUFFERED=1 FOUNDRY_DYNAMIC_TEST_LINKING=false halmos --root . --match-contract "$match" \
    ${tests[@]+"${tests[@]}"} --loop "$HALMOS_LOOP" --solver-timeout-assertion 0 2>&1 |
    tee "$OUT/halmos.txt"
  local rc=${PIPESTATUS[0]}
  # A build failure, or a run that never reached a result line, fails the step whatever the exit code says.
  if grep -qE 'Build failed|Unable to resolve imports|Compiler run failed' "$OUT/halmos.txt"; then
    echo "halmos: the build failed (see $OUT/halmos.txt)" >&2
    return 1
  fi
  if ! grep -qE 'Symbolic test result: [0-9]+ passed' "$OUT/halmos.txt"; then
    echo "halmos: no test result in $OUT/halmos.txt" >&2
    return 1
  fi
  return "$rc"
}

# hevm_targets runs every target against a local anvil chain (`--rpc`), never on bare runtime code: on bare code the
# immutables are zero, the storage is empty and every called contract is unknown code, whose revert data hevm leaves
# free, so each call whose failure the contract passes on (a bubbled revert) became an "assertion violation" with
# Panic(1) as that data. The run on main of 2026-11-12 reported such counterexamples on 41 targets, for example 18 on
# Collateralization, one per function that first calls the Lock (`nextRecordId()` included); none was an assertion of
# Avana's code.
#   harness:<Name>  the harness is deployed on the chain, so its constructor runs and deploys and configures the
#                   contracts it tests, as for Echidna and Medusa; each assertion entry point is then run symbolically
#                   from that state, with every contract the call reaches executed from its deployed code and storage.
#                   Each must reach QED.
#   src:<Name>      the contract's runtime code is placed on the chain (`anvil_setCode`) at HEVM_SRC_ADDRESS with its
#                   address immutables filled as a constructor fills them (script/security-targets.py runtime-code)
#                   and its own-address immutables set to that address; the addresses it calls hold no code there, so
#                   a call to them returns no data and the caller reverts with empty data. A Panic(1) can then come only
#                   from an `assert` of the contract itself. Paths after a successful call to another contract are
#                   explored by the harness targets, where that contract is deployed.
HEVM_PORT=${HEVM_PORT:-18545}
HEVM_RPC="http://127.0.0.1:$HEVM_PORT"
HEVM_SRC_ADDRESS=0x000000000000000000000000000000000000a7a5
HEVM_DEPLOYER=0x0000000000000000000000000000000000030000
HEVM_ANVIL_PID=""

hevm_chain_start() {
  anvil --port "$HEVM_PORT" --silent --code-size-limit 1000000 --gas-limit 30000000000 --disable-block-gas-limit \
    --auto-impersonate --chain-id 31337 >"$OUT/hevm/anvil.log" 2>&1 &
  HEVM_ANVIL_PID=$!
  local i
  for i in $(seq 1 100); do
    cast block-number --rpc-url "$HEVM_RPC" >/dev/null 2>&1 && break
    sleep 0.2
  done
  cast rpc --rpc-url "$HEVM_RPC" anvil_setBalance "$HEVM_DEPLOYER" 0xffffffffffffffffffffffff >/dev/null
}

hevm_chain_stop() { [ -n "$HEVM_ANVIL_PID" ] && kill "$HEVM_ANVIL_PID" 2>/dev/null; HEVM_ANVIL_PID=""; }

# hevm_symbolic <log> <args...>: hevm against the chain's latest block; 0 on QED, 1 on a counterexample or error, 2 on
# a partial exploration.
hevm_symbolic() {
  local log=$1 block
  shift
  block=$(cast block-number --rpc-url "$HEVM_RPC")
  hevm symbolic --solver z3 --smt-timeout "$HEVM_SMT_TIMEOUT" --rpc "$HEVM_RPC" --block "$block" "$@" >"$log" 2>&1
  local rc=$?
  if grep -q 'QED' "$log" && ! grep -qi 'partially explore' "$log"; then return 0; fi
  if [ $rc -ne 0 ] || grep -qiE 'counterexample|discovered the following' "$log"; then return 1; fi
  if grep -qi 'partially explore' "$log"; then return 2; fi
  return 1
}

# hevm_deploy <creation-code file>: deploys it from HEVM_DEPLOYER and prints the new address; fails when the
# constructor reverts.
hevm_deploy() {
  local receipt
  receipt=$(cast send --rpc-url "$HEVM_RPC" --unlocked --from "$HEVM_DEPLOYER" --gas-limit 29000000000 \
    --create "0x$(cat "$1")" --json) || return 1
  "$PY" -c 'import json,sys; r=json.loads(sys.argv[1]); assert int(r["status"], 16) == 1; print(r["contractAddress"])' \
    "$receipt"
}

step_hevm() {
  require hevm z3 anvil cast || return 1
  ensure_build || return 1
  mkdir -p "$OUT/hevm"
  hevm_chain_start
  hevm_targets
  local rc=$?
  hevm_chain_stop
  return $rc
}

hevm_targets() {
  local status=0 list name source sig hex rc addr seen=""

  list=$(harness_list "$ECHIDNA_DIR" "$MEDUSA_DIR") || return 1
  if [ -z "$list" ]; then
    echo "hevm harnesses: skipped, no *Properties harness in $ECHIDNA_DIR/ or $MEDUSA_DIR/"
  fi
  while IFS=$'\t' read -r name source; do
    [ -n "$name" ] || continue
    selected "${HEVM_TARGETS:-}" "harness:$name" || continue
    seen+=" harness:$name"
    hex="$OUT/hevm/$name.init.hex"
    "$PY" script/security-targets.py creation-code "$BUILD" "$name" "$hex" || return 1
    if ! addr=$(hevm_deploy "$hex"); then
      echo "hevm $name: FAIL, the harness constructor reverted on the local chain"
      status=1
      continue
    fi
    echo "hevm $name: deployed at $addr"
    while IFS= read -r sig; do
      [ -n "$sig" ] || continue
      hevm_symbolic "$OUT/hevm/$name.${sig%%(*}.log" --address "$addr" --sig "$sig"
      rc=$?
      case $rc in
        0) echo "hevm $name.$sig: QED" ;;
        2) echo "hevm $name.$sig: FAIL, explored only partially (see $OUT/hevm/$name.${sig%%(*}.log)"; status=1 ;;
        *) echo "hevm $name.$sig: FAIL (see $OUT/hevm/$name.${sig%%(*}.log)"; status=1 ;;
      esac
    done < <("$PY" script/security-targets.py assertion-sigs "$BUILD" "$name")
  done <<<"$list"

  list=$("$PY" script/security-targets.py runtime-code "$BUILD" "$OUT/hevm/code" "$HEVM_SRC_ADDRESS") || return 1
  if [ -z "$list" ]; then
    echo "hevm src: skipped, no contract or library under src/ compiles to runtime code"
  fi
  while IFS=$'\t' read -r name hex; do
    [ -n "$name" ] || continue
    selected "${HEVM_TARGETS:-}" "src:$name" || continue
    seen+=" src:$name"
    cast rpc --rpc-url "$HEVM_RPC" anvil_setCode "$HEVM_SRC_ADDRESS" "0x$(cat "$hex")" >/dev/null &&
      cast rpc --rpc-url "$HEVM_RPC" anvil_mine >/dev/null || return 1
    hevm_symbolic "$OUT/hevm/src-$name.log" --address "$HEVM_SRC_ADDRESS"
    rc=$?
    case $rc in
      0) echo "hevm src $name: QED" ;;
      2) echo "hevm src $name: no assertion violation found, explored partially (see $OUT/hevm/src-$name.log)" ;;
      *) echo "hevm src $name: FAIL (see $OUT/hevm/src-$name.log)"; status=1 ;;
    esac
  done <<<"$list"

  if ! selected "${HEVM_TARGETS:-}" test; then
    :
  elif ! grep -rqs --include='*.sol' 'function prove_' test/symbolic; then
    echo "hevm test: skipped, test/symbolic/ holds no prove_ function"
  else
    seen+=" test"
    # hevm test reads <root>/out; an isolated root keeps that build out of the workspace's out/.
    local root="$OUT/hevm/root" f
    rm -rf "$root" && mkdir -p "$root"
    for f in src test dependencies foundry.toml remappings.txt; do ln -s "$ROOT/$f" "$root/$f"; done
    if (cd "$root" && forge build --ast --skip script >"$ROOT/$OUT/hevm/test-build.log" 2>&1) &&
      hevm test --root "$root" --solver z3 --smt-timeout "$HEVM_SMT_TIMEOUT" 2>&1 | tee "$OUT/hevm/test.log"; then
      echo "hevm test: pass"
    else
      echo "hevm test: FAIL (see $OUT/hevm/test.log)"
      status=1
    fi
  fi
  unmatched hevm "${HEVM_TARGETS:-}" "$seen" || status=1
  return $status
}

step_mythril() {
  ensure_build || return 1
  MYTHRIL_CONTRACTS="${MYTHRIL_CONTRACTS:-}" script/security-mythril.sh "$BUILD"
}

MUTATE_TIMEOUT=${MUTATE_TIMEOUT:-300}
MUTATE_FUZZ_RUNS=${MUTATE_FUZZ_RUNS:-256}
NECESSIST_TIMEOUT=${NECESSIST_TIMEOUT:-300}

# solc_bin: the solc of foundry.toml's solc_version, from Foundry's svm cache (macOS or Linux) or tools/bin.
solc_bin() {
  local v d
  v=$(sed -nE 's/^solc_version *= *"([0-9.]+)".*/\1/p' foundry.toml | head -n1)
  for d in "$HOME/Library/Application Support/svm" "${XDG_DATA_HOME:-$HOME/.local/share}/svm" "$HOME/.svm"; do
    [ -x "$d/$v/solc-$v" ] && { echo "$d/$v/solc-$v"; return 0; }
  done
  [ -x "$ROOT/tools/bin/solc-$v" ] && { echo "$ROOT/tools/bin/solc-$v"; return 0; }
  echo "missing solc $v: run forge build once so Foundry installs it" >&2
  return 1
}

# isolated_root <dir>: a project copy whose src/ and test/ the mutation tools may edit in place, so an interrupted run
# never leaves a mutant in the workspace; its own out/ and cache/ keep the workspace build untouched. bin/solc is the
# project's solc, first on PATH, because slither-mutate compiles each mutant with the `solc` it finds.
isolated_root() {
  local root=$1 f solc
  solc=$(solc_bin) || return 1
  rm -rf "$root" && mkdir -p "$root/bin"
  cp -R src test "$root/"
  for f in dependencies foundry.toml remappings.txt out-aave; do
    [ -e "$f" ] && ln -s "$ROOT/$f" "$root/$f"
  done
  ln -s "$solc" "$root/bin/solc"
}

step_mutate() {
  require slither-mutate forge || return 1
  local list status=0 layer name file tests root="$OUT/mutation/root" dir log remaps mutators=()
  list=$("$PY" script/mutation-targets.py contracts --layers "${MUTATE_LAYERS:-}" --contracts "${MUTATE_CONTRACTS:-}") || return 1
  if [ -z "$list" ]; then
    echo "mutate: skipped, no implementation file in the selected layers of security/mutation-layers.json"
    return 0
  fi
  isolated_root "$root" || return 1
  remaps=$(tr '\n' ' ' <remappings.txt)
  [ -n "${MUTATE_MUTATORS:-}" ] && mutators=(--mutators-to-run "$MUTATE_MUTATORS")
  while IFS=$'\t' read -r layer name file tests; do
    dir="$ROOT/$OUT/mutation/$layer"
    mkdir -p "$dir"
    log="$dir/$name.log"
    echo "=== slither-mutate $name ($file), layer $layer, tests $tests"
    if ! (cd "$root" && PATH="$PWD/bin:$PATH" FOUNDRY_FUZZ_RUNS="$MUTATE_FUZZ_RUNS" slither-mutate "$file" \
      --contract-names "$name" --solc "$PWD/bin/solc" --solc-remaps "$remaps" --timeout "$MUTATE_TIMEOUT" \
      --test-cmd "forge test -j 2 --match-path '$tests'" --output-dir "$dir/$name" ${mutators[@]+"${mutators[@]}"} \
      >"$log" 2>&1); then
      status=1
      echo "mutate: slither-mutate failed on $name (see $log)"
    fi
    if grep -qE 'Test suite fails|Cannot find contracts|Traceback|too short for tests' "$log"; then
      status=1
      echo "mutate: $name did not run (see $log)"
    fi
    grep -oE '(Revert|Comment|Tweak) mutants: .*|Zero (Revert|Comment|Tweak) mutants analyzed' "$log" | sed 's/^/  /' || true
    grep 'UNCAUGHT' "$log" | sed "s|^|$name: |" >>"$dir/survivors.txt" || true
    # The isolated copy must be unchanged after the campaign: slither-mutate restores every file it mutates.
    if ! diff -q "$file" "$root/$file" >/dev/null; then
      status=1
      echo "mutate: $file was not restored in the isolated copy; recreating it"
      isolated_root "$root" || return 1
    fi
  done <<<"$list"
  for dir in "$OUT"/mutation/*; do
    [ -f "$dir/survivors.txt" ] && echo "survivors: $(wc -l <"$dir/survivors.txt" | tr -d ' ') in $dir/survivors.txt"
  done
  return $status
}

step_gambit() {
  MUTATE_FUZZ_RUNS="$MUTATE_FUZZ_RUNS" script/security-gambit.sh
}

step_necessist() {
  require forge || return 1
  if ! command -v necessist >/dev/null 2>&1; then
    echo "missing necessist: run script/install-security-tools.sh --necessist (needs cargo)" >&2
    return 1
  fi
  local list status=0 layer files root="$OUT/necessist/root"
  list=$("$PY" script/mutation-targets.py tests --layers "${MUTATE_LAYERS:-}" --contracts "${MUTATE_CONTRACTS:-}") || return 1
  if [ -n "${NECESSIST_TESTS:-}" ]; then
    unmatched necessist "$NECESSIST_TESTS" "$(cut -f2 <<<"$list" | tr '\n' ' ')" || return 1
    list=$(awk -F'\t' -v sel=" $NECESSIST_TESTS " 'index(sel, " " $2 " ")' <<<"$list")
  fi
  if [ -z "$list" ]; then
    echo "necessist: skipped, no test file in the selected layers of security/mutation-layers.json"
    return 0
  fi
  mkdir -p "$OUT/necessist"
  for layer in $(cut -f1 <<<"$list" | sort -u); do
    files=$(awk -F'\t' -v l="$layer" '$1 == l {print $2}' <<<"$list")
    isolated_root "$root" || return 1
    echo "=== necessist, layer $layer: $(wc -l <<<"$files" | tr -d ' ') test file(s)"
    # shellcheck disable=SC2086
    if ! (cd "$root" && PATH="$PWD/bin:$PATH" FOUNDRY_FUZZ_RUNS="$MUTATE_FUZZ_RUNS" necessist --framework foundry \
      --timeout "$NECESSIST_TIMEOUT" --no-sqlite $files -- -j 2 >"$ROOT/$OUT/necessist/$layer.log" 2>&1); then
      status=1
      echo "necessist: layer $layer failed (see $OUT/necessist/$layer.log)"
    fi
    grep -E ' passed$' "$OUT/necessist/$layer.log" >"$OUT/necessist/$layer.txt" || true
    echo "necessist: $(wc -l <"$OUT/necessist/$layer.txt" | tr -d ' ') removal(s) left the tests passing (see $OUT/necessist/$layer.txt)"
  done
  return $status
}

notes() {
  cat <<'EOF'
Not run, by design:
  manticore  archived upstream (trailofbits/manticore, last release 0.3.7 in February 2022); hevm, Halmos and
             Mythril run the symbolic execution it provided
  mythx      the hosted service shut down effective 31 March (mythx.io/sunset) and its API no longer answers;
             Mythril, its open-source engine, runs locally above
  kontrol    needs the K framework (kup and Nix); hevm and Halmos cover symbolic proofs of Foundry tests
EOF
}

ALL=(build echidna medusa halmos hevm mythril mutate gambit necessist)
steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=("${ALL[@]}")

for s in "${steps[@]}"; do
  if ! declare -F "step_$s" >/dev/null; then
    echo "security-slow: unknown step $s (steps: ${ALL[*]})" >&2
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
notes
echo
if [ ${#failed[@]} -gt 0 ]; then
  echo "security-slow: FAIL in ${failed[*]} (reports in $OUT/)"
  exit 1
fi
echo "security-slow: every step passed (reports in $OUT/)"
