# Releases

A release is a git tag on `main` and a GitHub Release of the same name. The first one is [`v0.1.0-alpha.1`](https://github.com/Avana-Labs/avana-monorepo/releases/tag/v0.1.0-alpha.1) (commit `807e2c8`, release title "0.1.0-alpha.1: Avana v1.1.1"); every later release follows the same names.

## Names

| What | Form | Example |
|---|---|---|
| Tag | `vX.Y.Z`, or `vX.Y.Z-alpha.N`, `-beta.N`, `-rc.N` for a pre-release | `v0.1.0-alpha.1` |
| GitHub Release title | `X.Y.Z[-pre.N]: Avana vA.B.C`, the tag without its `v`, then the name the release goes by | `0.1.0-alpha.1: Avana v1.1.1` |
| CHANGELOG.md section | `## [X.Y.Z[-pre.N]] - YYYY-MM-DD`, with a link reference at the bottom of the file | `## [0.1.0-alpha.1] - 2026-11-11` |
| Deploy scripts | `AVANA_RELEASE` = the tag | `AVANA_RELEASE=v0.1.0-alpha.1` |
| Manifest | `release` = the tag; files `deployments/<network>/<tag>.json`, `deployments/verified/<network>-<tag>.json` | `deployments/sepolia/v0.2.0.json` |

The version rules (major, minor, patch, pre-release) are at the top of [`CHANGELOG.md`](../CHANGELOG.md). A tag matches the manifest schema's `release` pattern, `^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$`. Tags with `-local`, `-test` or `-learn` are learning tags: the deploy scripts accept them for anvil rehearsals (`contracts/script/deploy/config/anvil.json` uses `v0.1.0-local`), and neither the release workflow nor `manifest publish` accepts them.

## The tag is the salt

`AVANA_RELEASE` goes into the salt of every contract the deploy scripts place with CREATE3, `keccak256("avana.<tag>.<name>")` (`contracts/script/deploy/lib/DeployBase.sol`), and into the timelock operation salts, `keccak256("avana.<tag>.operation.<name>")`. The CREATE3 factory sits at one CREATE2 address on every chain and namespaces each salt by its caller, so a tag and a deployer fix the address of every named contract (AvanaTimelock, MarketRegistry, ParameterStore, RiskModule, AaveAdapter, LPVaultSwap, Lock, Collateralization, VaultTokenFactory, ProxyManager, PayoutEscrow, AaveV3FlashSource, FlashLiquidator, Lens, `LPVault.<integrationId>`, `OperatorFlashLiquidator.<i>`) on Ethereum and Base alike. For that reason a tag is never moved, deleted or reused, and a fix is a new tag.

## Steps

1. **Changelog.** In a pull request to `main`, move the entries under `## [Unreleased]` into a new section `## [X.Y.Z] - <date>`, list the changed contracts with their spec IDs under **Contracts**, and update the link references at the bottom (`[Unreleased]` compares from the new tag; add one line for the new version). Merge it once every CI job has passed.
2. **Tag.** On the merge commit, create an annotated tag and push it:

   ```bash
   git tag -a v0.2.0 -m "v0.2.0" <merge commit>
   git push origin v0.2.0
   ```

   The first tag, `v0.1.0-alpha.1`, is a lightweight tag; it stays as it is, since a tag is never moved. Later tags are annotated (the workflow warns on a lightweight one).
3. **Release workflow.** The tag push runs [`.github/workflows/release.yml`](../.github/workflows/release.yml), and also the long checks of `contracts.yml` (deep invariants, fork, differential, SMTChecker, Certora, slow security tier); the release workflow runs no test suite itself. It checks the tag (format, not a learning tag, commit on `main`, CHANGELOG section present), builds the tagged commit with the release build (the default Foundry profile into `contracts/out`, the `aave` profile into `contracts/out-aave`; these are the artifacts the deploy scripts and `manifest verify` read), checks the committed ABIs of `packages/protocol` against that build, then attaches to the GitHub Release:

   | File | Contents |
   |---|---|
   | `release.json` | Release record: tag, commit, ABI hash, compiler settings, the CREATE3 factory address, the salt of each named contract (and its address, when the repository variable `AVANA_DEPLOYER` or the run's `deployer` input names the deployer), and for every deployable Avana artifact its path, source, optimizer settings and creation and runtime code hashes. Its shared fields are checked against [`deployments/release-manifest.schema.json`](../deployments/release-manifest.schema.json). |
   | `bytecode-hashes.txt` | One line per artifact: runtime code hash, creation code hash, artifact path. |
   | `avana-<tag>-artifacts.tar.gz` | The artifact JSON files the record lists, from `contracts/`. |
   | `SHA256SUMS` | SHA-256 of the three files above. |

   Runtime code hashes are taken with immutable positions zero; `manifest verify` compares on-chain code against the artifact with those positions masked (`TEST-134`).
4. **Publish.** If the tag had no GitHub Release, the workflow creates a draft with the CHANGELOG section as notes and the title `X.Y.Z`; set the title to the form above, check the attached files and publish it (as a pre-release for a pre-release tag). An existing release keeps its title and notes; the workflow only replaces the attached files.
5. **Deployments.** A deployment of the release runs the deploy scripts with `AVANA_RELEASE=<tag>` from a checkout of the tag, then `npm run manifest -- produce` and `verify` ([`deployments/README.md`](../deployments/README.md)). The manifest's `release`, `commit` and `abiHash` equal those of `release.json`, and its `create3Factory` and CREATE3 addresses equal the record's predictions for its deployer. The verified manifest is added to the release's **Deployments** list in the CHANGELOG.

## Attaching files to an earlier release

Run the workflow by hand (Actions → release → Run workflow) with `tag` set to the existing tag, for example `v0.1.0-alpha.1`. The workflow builds that tag with this branch's release tools; a tag older than the deploy scripts or `packages/protocol` (as `v0.1.0-alpha.1` is) gets the bytecode hashes only, with `create3Factory` and `abiHash` null and no salts. The CHANGELOG checked is the one on the branch the workflow runs from.

## Building the record locally

```bash
(cd contracts && forge build && FOUNDRY_PROFILE=aave forge build)
node packages/protocol/scripts/release-build.mjs --release v0.2.0 --commit "$(git rev-parse HEAD)" --out-dir dist/release
```
