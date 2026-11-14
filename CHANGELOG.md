# Changelog

Every release of Avana is a git tag `vX.Y.Z` on `main` with a GitHub Release of the same name, and each has a section here, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/) as applied to the deployed system:

- **Major** (`v2.0.0`): a new immutable core (LPVault, Collateralization, vault tokens, ProxyManager, PositionProxy, Lock, PayoutEscrow), which means new addresses and a migration.
- **Minor** (`v1.1.0`): a new upgradeable implementation, a new AMM integration, a new chain or a new debt asset.
- **Patch** (`v1.0.1`): a fix with no change to any external function, event, error or storage layout.
- **Pre-release** (`v0.1.0-alpha.1`, then `-alpha.2`, `-beta.1`, `-rc.1`): a development release, built and published but not deployed to Ethereum or Base. Versions below `v1.0.0` follow the same rules, except that a minor version may also change the immutable core.

The tag is also the deploy scripts' `AVANA_RELEASE`, which feeds the CREATE2 and CREATE3 salts and the manifest file names ([`contracts/script/README.md`](contracts/script/README.md#releases-and-tags)). Contracts deployed under one tag therefore have different addresses from those deployed under another, and a tag is never moved or reused. How a release is cut, built and published: [`docs/release.md`](docs/release.md).

Each release section lists, under **Contracts**, every changed contract with the spec IDs it implements or changes, and under **Deployments**, the verified manifests that use the release. Changes not yet in a release go under **Unreleased**.

## [Unreleased]

### Contracts

- `MarketRegistry.enableDebtReserve`: a cross-Hub debt reserve whose draw cap exceeds its credit line reverts `CrossHubCapExceeded(drawCap, line)` (`REQ-HUB-103`). ([#27](https://github.com/Avana-Labs/avana-monorepo/pull/27))
- Settlement routes: a route pair shares no intermediate token other than the debt asset (`REQ-ROUTE-003`), also in the rehearsal's route search. ([#27](https://github.com/Avana-Labs/avana-monorepo/pull/27))
- LPVaultSwap: deleverage pays `min(balance change, R − x − φ)` (`SPEC-LIQ-020`); the health factor is read after both oracles are poked; the slippage allowance is bounded so the Avana fee survives at the smallest liquidation bonus (`s × minLB ≤ (10⁴ − f)(minLB − 10⁴)`, activation check `feeBound`). ([#27](https://github.com/Avana-Labs/avana-monorepo/pull/27))
- Loss layers renamed: `CoverageSpoke` → `AvanaFirstLossReserve`, `DeficitOffsetSpoke` → `DaoDeficitOffset`, ABIs included. ([#27](https://github.com/Avana-Labs/avana-monorepo/pull/27))
- Lens matches execution: the repay-with-collateral preview is closed only under `Paused(MintPathSuspect)`; `previewBorrowMax` applies the borrowed reserve's debt-price gate; price age follows execution's rules through the new `PriceAge` library, which RiskModule and LPVaultSwap also use; `getDebtPriceState.updatedAt` reports the served route's timestamp. ([#27](https://github.com/Avana-Labs/avana-monorepo/pull/27))
- LPOracle and DebtOracle: the accepted price follows a faster leg at the same oldest timestamp; the raw-price bound is raised from 2^64 to 2^128; while Drifting, the debt price is `max(min(p, b), A)`, so one faulty route cannot raise it alone (`SPEC-ORC-018`). ([#27](https://github.com/Avana-Labs/avana-monorepo/pull/27), NatSpec corrected in [#30](https://github.com/Avana-Labs/avana-monorepo/pull/30))
- LPOracleCL: `unitExp` recorded in the storage-layout snapshot. ([#27](https://github.com/Avana-Labs/avana-monorepo/pull/27))

### Added

- Release process: `.github/workflows/release.yml` builds a tag with the release build, records the bytecode hashes, the CREATE3 salts and the ABI hash in a release record checked against the manifest schema, and attaches them to the tag's GitHub Release; [`docs/release.md`](docs/release.md) lists the steps.
- Webapp: `webapp/` (`@avana/web`) with Lend, Borrow, Portfolio, the market pages, Swap, Support and Ask AI, and its Convex modules in `services/convex`; `.github/workflows/web.yml` runs lint, typecheck, unit tests and a production build. ([#31](https://github.com/Avana-Labs/avana-monorepo/pull/31))
- Keeper: reads the indexer's new `GET /keeper/v1/events` stream at the chain head, acts on liquidation failure reasons, holds a per-chain fee ceiling (`KEEPER_GAS_CEILING_WEI_<CHAIN>`), keeps mined transactions until finalized across reorgs, reports to the monitoring service, funds a call from inventory when a flash loan is unusable, and confirms the health factor on a second provider before signing. ([#29](https://github.com/Avana-Labs/avana-monorepo/pull/29))
- Tests on the real stack: fee-on-transfer debt (`TEST-287`), four Slipstream generations with the real Aerodrome FactoryRegistry (`TEST-047`, `TEST-193`), the integration invariants, Lens price gates and the repay health-factor order; the stand-in integration fixture is deleted. ([#32](https://github.com/Avana-Labs/avana-monorepo/pull/32))
- Secret scan: `.github/workflows/gitleaks.yml` runs Gitleaks 8.30.1 over the full git history on every pull request, every push to `main` and weekly, with the rules in `.gitleaks.toml`.

### Changed

- Repository layout: `web/` → `webapp/`, `spec/` → `docs/spec/`, `governance/` → `docs/governance/`, `audit/` → `docs/audit/`, `tools/heimdall/` → `contracts/tools/heimdall/`; CI path filters, CODEOWNERS, tools and links follow. ([#34](https://github.com/Avana-Labs/avana-monorepo/pull/34))
- CI: every pull request runs the short set of `contracts.yml` in about 10 minutes (format, lint, build, the `ci` and `gas` test profiles, the generated-ABI check, coverage, traceability, the fast security tier); a pull request labelled `hotfix` also runs the touched contracts' invariants at full depth. Every push to `main` runs the same set at full test depth in 30 shards; each invariant file is one campaign, and a campaign over 20 minutes runs as segments of its runs at the same depth. The long checks (the deep invariant campaign, fork, differential, SMTChecker, Certora, the slow security tier with Halmos at loop 16 one check per job, the mutation gates of all six layers and the spec models) run every night on `main` at 06:00 UTC when `NIGHTLY_ENABLED` is set, on every release tag and by hand; an upgrade is scheduled from a release tag, so they run during the timelock delay. Echidna runs without its own Slither pass. ([#25](https://github.com/Avana-Labs/avana-monorepo/pull/25))
- CI: the test suite runs in shards (`script/test-shard.sh`), balanced by measured run time (`script/test-timings.json`), reusing the build job's output; a pull request runs 10 shards and the invariant suites as a short check, `main` runs the full ci profile; gas snapshots run in their own job; a `gate` job passes only when every job and shard passed, for branch protection.
- CI: Certora's prover jobs and `certoraMutate` run only when the repository variable `CERTORA_ENABLED` is `true`; the offline methods check runs on every pull request. An hevm counterexample fails its step only when its on-chain replay ends in `Panic(1)`. ([#25](https://github.com/Avana-Labs/avana-monorepo/pull/25))
- CI: `ci-failure-report.yml` records every failed run: an issue labelled `ci-failure` for `main` (closed by the next success of that workflow) and a comment for a pull request, with the failed jobs, steps, annotations and log lines.
- Mutation gate: Gambit's isolated copy links `out-univ3/`; via-IR Lens mutants get their own build budget; 12 survivors killed by new tests. ([#27](https://github.com/Avana-Labs/avana-monorepo/pull/27))
- Rehearsal services step runs on Windows. ([#27](https://github.com/Avana-Labs/avana-monorepo/pull/27))

### Removed

- Dependabot version updates; dependency review and security alerts stay. ([#12](https://github.com/Avana-Labs/avana-monorepo/pull/12))

## [0.1.0-alpha.1] - 2026-11-11

Pre-audit development release, tag `v0.1.0-alpha.1` (`807e2c8`), GitHub Release "0.1.0-alpha.1: Avana v1.1.1". Not deployed.

### Contracts

- Shared core: AvanaRoles, Lock, AvanaTimelock, ParameterStore, MarketRegistry, RiskModule, Collateralization, LPOracle, DebtOracle, LPPriceMath, SettlementMath.
- AMM integrations: Uniswap v3 LPVault (Ethereum) and Aerodrome Slipstream LPVault (Base).
- VaultToken and VaultTokenFactory; PositionProxy and ProxyManager.
- Aave V3 flash source and the public flash liquidation helper.
- Settlement routes (DEX path, wrapper-then-DEX, peg module), PayoutEscrow and the first-loss layer.
- In progress at this tag: concentrated-liquidity pricing, AaveAdapter, LPVaultSwap, Lens.

### Added

- Verification: Foundry unit, fuzz, invariant and integration tests on Aave V4; Halmos, Echidna and Medusa harnesses; Certora specs; the specification with traceability from every requirement to its tests and formal properties; math models in Z3, SymPy, Hypothesis and Quint.
- Fast security tier on every change (Slither, Aderyn, Semgrep, 4naly3er, solhint, storage-layout and upgradeability checks, per-file branch-coverage minimums) and the slow tier (Echidna, Medusa, Halmos, hevm, Mythril, slither-mutate, Gambit, Necessist).
- Off-chain services design and scaffolding: indexer, keeper, Convex import.
- Governance roles and parameters.
- Licensing: BUSL-1.1 with third-party notices (`LICENSING.md`, `NOTICE`, `THIRD_PARTY_LICENSES.md`).
- Repository setup: fork-block constants in `contracts/test/utils/fixtures/ForkConstants.sol` (`TEST-003`; both 0, so the fork suites skip until the blocks are pinned), `contracts/.env.example`, dependency review, actions pinned by commit, gas snapshots, contract-size margins, `contracts/Makefile`, `SECURITY.md`, CODEOWNERS, pull-request and issue templates, governance operation folders, the external audit index and tool version files.

### Changed

- The Hub, Spoke, oracle, price-feed and storage-read interfaces in `contracts/src/interfaces/external/aave/` are written by Avana and declare only the members Avana code, tests and CVL specs use, with selectors, struct layouts and event signatures equal to the pinned lending-market release.

### Deployments

- None.

[Unreleased]: https://github.com/Avana-Labs/avana-monorepo/compare/v0.1.0-alpha.1...HEAD
[0.1.0-alpha.1]: https://github.com/Avana-Labs/avana-monorepo/releases/tag/v0.1.0-alpha.1
