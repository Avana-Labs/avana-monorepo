# Build, test and deploy entry points for contracts/. Variables come from .env (see .env.example) and
# can be set on the command line: `make deploy-03_DeployAvana chain=sepolia dry=0` (script/deploy/03_DeployAvana.s.sol;
# AVANA_NETWORK names the config in script/deploy/config/).
#
# Deploys are dry runs by default: `dry=1` simulates the script against `chain` with the given sender
# and broadcasts nothing. `dry=0` broadcasts with --slow (one transaction confirmed before the next)
# and, on every chain except anvil, verifies the sources on the explorer of [etherscan] in foundry.toml.

-include .env
export

chain ?= anvil
dry ?= 1
JOBS ?= 2
ACCOUNT_NAME ?= deployer
MNEMONIC_INDEX ?= 0

BROADCAST = $(if $(filter 0,$(dry)),--broadcast $(if $(filter anvil,$(chain)),,--verify),)

.PHONY: build build-aave build-external e2e-local fmt test test-fork test-differential gas gas-check sizes coverage security-fast

build:
	forge build

build-aave:
	FOUNDRY_PROFILE=aave forge build

# Uniswap v3 and Aerodrome Slipstream (Solidity 0.7.6) for the test-network world of script/deploy/02_DeployWorld.
build-external:
	FOUNDRY_PROFILE=univ3 forge build
	FOUNDRY_PROFILE=univ3-periphery forge build
	FOUNDRY_PROFILE=slipstream-v1 forge build
	FOUNDRY_PROFILE=slipstream-main forge build
	FOUNDRY_PROFILE=aerodrome forge build
	FOUNDRY_PROFILE=aave-v3 forge build

# Local deployment rehearsal on a fresh anvil node (deployments/README.md); needs build, build-aave, build-external
# and `npm ci` at the repository root. Prints and writes deployments-local/anvil/e2e-status.json.
e2e-local:
	script/e2e/e2e-local.sh

fmt:
	forge fmt

test:
	forge test -j $(JOBS)

test-fork:
	FOUNDRY_PROFILE=fork forge test -j $(JOBS)

test-differential:
	FOUNDRY_PROFILE=differential forge test -j $(JOBS)

# Rewrites snapshots/*.json from the gas suites in test/gas/; commit the result with the change.
gas:
	FOUNDRY_PROFILE=gas FORGE_SNAPSHOT_CHECK=false forge test -j $(JOBS)

# Fails when a gas suite measures a value other than the committed snapshot (the CI check).
gas-check:
	FOUNDRY_PROFILE=gas forge test -j $(JOBS)

sizes:
	script/check-sizes.sh

coverage:
	script/check-coverage.sh

security-fast:
	script/security-fast.sh

# Hardware-wallet deploy: make deploy-ledger-03_DeployAvana chain=mainnet dry=0
# Defined before deploy-% so that make picks it for deploy-ledger-* targets.
deploy-ledger-%:
	@test -n "$(LEDGER_SENDER)" || { echo "LEDGER_SENDER is not set"; exit 1; }
	forge script script/deploy/$*.s.sol --rpc-url $(chain) --ledger --mnemonic-indexes $(MNEMONIC_INDEX) \
		--sender $(LEDGER_SENDER) --slow $(BROADCAST)

# Keystore deploy: make deploy-03_DeployAvana chain=sepolia dry=0
deploy-%:
	@test -n "$(SENDER)" || { echo "SENDER is not set"; exit 1; }
	forge script script/deploy/$*.s.sol --rpc-url $(chain) --account $(ACCOUNT_NAME) --sender $(SENDER) --slow $(BROADCAST)
