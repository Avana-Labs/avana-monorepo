# Changelog

Every release of Avana is an annotated git tag `vX.Y.Z` on `main`, and each has a section here, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/) as applied to the deployed system:

- **Major** (`v2.0.0`): a new immutable core (LPVault, Collateralization, vault tokens, ProxyManager, PositionProxy, Lock, PayoutEscrow), which means new addresses and a migration.
- **Minor** (`v1.1.0`): a new upgradeable implementation, a new AMM integration, a new chain or a new debt asset.
- **Patch** (`v1.0.1`): a fix with no change to any external function, event, error or storage layout.

The tag is also the deploy scripts' `AVANA_RELEASE`, which feeds the CREATE2 and CREATE3 salts and the manifest file names ([`contracts/script/README.md`](contracts/script/README.md#releases-and-tags)). Contracts deployed under one tag therefore have different addresses from those deployed under another, and a tag is never moved or reused.

Each release section lists, under **Contracts**, every changed contract with the spec IDs it implements or changes, and under **Deployments**, the verified manifests that use the release. Changes not yet in a release go under **Unreleased**.

## Unreleased

### Added

- Secret scan: `.github/workflows/gitleaks.yml` runs Gitleaks 8.30.1 over the full git history on every pull request, every push to `main` and weekly, with the rules in `.gitleaks.toml`.
- Repository setup: fork-block constants in `contracts/test/utils/fixtures/ForkConstants.sol` (`TEST-003`; both 0, so the fork suites skip until the blocks are pinned), `contracts/.env.example`, dependency review, actions pinned by commit, gas snapshots, contract-size margins, `contracts/Makefile`, `SECURITY.md`, CODEOWNERS, pull-request and issue templates, governance operation folders, the external audit index, the generated address library and tool version files.

### Changed

- CI: every pull request runs the short set of `contracts.yml` in about 10 minutes (format, lint, build, the `ci` and `gas` test profiles, the generated-ABI check, coverage, traceability, the fast security tier); a pull request labelled `hotfix` also runs the touched contracts' invariants at full depth. Every push to `main` runs the same set at full test depth in 20 shards, each invariant a unit of its own. The long checks (the deep invariant campaign, fork, differential, Halmos, SMTChecker, Certora, the slow security tier, the mutation gates of all six layers and the spec models) run every night on `main` at 06:00 UTC, on every release tag and by hand; an upgrade is scheduled from a release tag, so they run during the timelock delay. Echidna runs without its own Slither pass.
- CI: the test suite runs as 10 shards in parallel (`script/test-shard.sh`), balanced by measured run time (`script/test-timings.json`), reusing the build job's output; a pull request runs the invariant suites as a short check, `main` at the full ci profile; gas snapshots run in their own job; a `gate` job passes only when every job and shard passed, for branch protection.
- CI: `ci-failure-report.yml` records every failed run: an issue labelled `ci-failure` for `main` (closed by the next success of that workflow) and a comment for a pull request, with the failed jobs, steps, annotations and log lines.
- The Hub, Spoke, oracle, price-feed and storage-read interfaces in `contracts/src/interfaces/external/aave/` are written by Avana and declare only the members Avana code, tests and CVL specs use, with selectors, struct layouts and event signatures equal to the pinned lending-market release.
