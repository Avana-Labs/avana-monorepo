# Changelog

Every release of Avana is an annotated git tag `vX.Y.Z` on `main`, and each has a section here, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/) as applied to the deployed system:

- **Major** (`v2.0.0`): a new immutable core (LPVault, Collateralization, vault tokens, ProxyManager, PositionProxy, Lock, PayoutEscrow), which means new addresses and a migration.
- **Minor** (`v1.1.0`): a new upgradeable implementation, a new AMM integration, a new chain or a new debt asset.
- **Patch** (`v1.0.1`): a fix with no change to any external function, event, error or storage layout.

The tag is also the deploy scripts' `AVANA_RELEASE`, which feeds the CREATE2 and CREATE3 salts and the manifest file names ([`contracts/script/README.md`](contracts/script/README.md#releases-and-tags)). Contracts deployed under one tag therefore have different addresses from those deployed under another, and a tag is never moved or reused.

Each release section lists, under **Contracts**, every changed contract with the spec IDs it implements or changes, and under **Deployments**, the verified manifests that use the release. Changes not yet in a release go under **Unreleased**.

## Unreleased

### Added

- Repository setup: fork blocks pinned in `contracts/test/utils/fixtures/ForkConstants.sol` (`TEST-003`), `contracts/.env.example`, dependency review, actions pinned by commit, gas snapshots, contract-size margins, `contracts/Makefile`, `SECURITY.md`, CODEOWNERS, pull-request and issue templates, governance operation folders, the external audit index, the generated address library and tool version files.

### Changed

- The Hub, Spoke, oracle, price-feed and storage-read interfaces in `contracts/src/interfaces/external/aave/` are written by Avana and declare only the members Avana code, tests and CVL specs use, with selectors, struct layouts and event signatures equal to the pinned lending-market release.
