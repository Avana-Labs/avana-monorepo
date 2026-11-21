# Contributing

Each core contract records its decisions in a `DESIGN.md` next to its code. A change to a decision updates that record in the same pull request.

## Security reports

Do not open a public issue, pull request or discussion for a vulnerability. Email **support@avana.cc** with "Security" in the subject; [`SECURITY.md`](SECURITY.md) says what to include and what happens next. The bug bounty has not started; audit and bug-bounty status is in [`docs/audit/README.md`](docs/audit/README.md#audit-status).

## Setup

Prerequisites: [Foundry](https://getfoundry.sh) through `foundryup`, [uv](https://docs.astral.sh/uv/), Node.js 22.18.0 (`.nvmrc`) with npm, Python 3, and [lefthook](https://github.com/evilmartians/lefthook) for the pre-commit checks. From the repository root:

```bash
git config --unset core.hooksPath   # only in a clone set up with the old .githooks/ folder
lefthook install
foundryup --install 1.9.0
cd contracts
forge soldeer install
script/install-security-tools.sh
FOUNDRY_PROFILE=aave forge build
```

`forge soldeer install` installs the dependencies pinned in `contracts/soldeer.lock`; `script/install-security-tools.sh` installs the pinned analysis tools (Slither, Halmos, Semgrep, certora-cli and Gambit, Mythril, solhint, Echidna, Medusa, Aderyn, hevm, Bitwuzla, the Semgrep rules and 4naly3er); `--necessist` adds Necessist, which needs cargo. The `aave` build produces the Aave V4 artifacts the test fixtures deploy.

The pre-commit hook ([`lefthook.yml`](lefthook.yml)) runs a local disclosure scan and Gitleaks on staged changes, dependency audits when lockfiles or requirements change, `script/security-fast.sh` when Solidity source changes, `forge fmt --check` and the file-size check on staged Solidity, and the licence-header check on staged Solidity, Python, JavaScript, shell and JSON files. The policy scan checks added lines and sensitive filenames against [`.github/security/premerge-names.json`](.github/security/premerge-names.json). A pre-push hook repeats the scan on outgoing commits and branch names. PR CI also scans the diff, title, body and branch, and cancels other CI on a policy finding.

Install the hooks once per clone with `lefthook install`. Git has no standard hook that blocks branch creation or PR creation. Outgoing mail uses provider DLP; setup for Microsoft 365 and Google Workspace is in [`docs/security/pre-merge-security.md`](docs/security/pre-merge-security.md).

Commit messages and pull request text carry no AI credit (no AI co-author trailer, no "Generated with" line). The `commit-msg` hook, installed by the same `lefthook install`, runs [`contracts/script/check-ai-credit.sh`](contracts/script/check-ai-credit.sh) on each message, and the `commit-messages` workflow checks a pull request's own commits, title and body.

## Build and test

From `contracts/`:

```bash
forge build -D warnings                     # Avana sources, warnings denied
forge build --sizes                         # with the EIP-170 runtime limit
forge test                                  # unit, fuzz, integration, hostile and invariant suites
forge test --match-contract LiquidationModule   # one contract
FOUNDRY_PROFILE=ci forge test               # CI depth (10,000 fuzz runs)
FOUNDRY_PROFILE=invariant forge test        # deep invariant campaign
FOUNDRY_PROFILE=differential forge test     # against the Python reference
FOUNDRY_PROFILE=fork forge test             # reads the archive endpoints RPC_MAINNET and RPC_BASE
forge fmt                                   # format
forge lint src                              # lints on src/
script/check-file-size.sh                   # 500 code lines per implementation file, 300 lines per interface
script/check-sizes.sh                       # runtime size against EIP-170 minus security/size-margins.json
script/check-licence.sh                     # licence headers
make gas                                    # rewrite snapshots/ after a gas change
```

Test naming and fixtures are in [`contracts/test/README.md`](contracts/test/README.md); Certora runs are in [`contracts/certora/README.md`](contracts/certora/README.md).

## Security tiers

From `contracts/`; each runner takes step names and runs every step even after one fails.

```bash
script/security-fast.sh                     # fmt, size, licence, lint, build, CVL methods, solhint, Slither,
                                            # upgradeability, Aderyn, Semgrep, 4naly3er, storage layout
script/check-coverage.sh                    # per-file branch-coverage minimums
script/security-slow.sh                     # Echidna, Medusa, Halmos, hevm, Mythril, slither-mutate, Gambit, Necessist
script/security-slow.sh build echidna       # one tool after a build
MUTATE_LAYERS=2.1 script/security-slow.sh mutate gambit necessist   # layer gate of 2.1
MUTATE_LAYERS=2.2 MUTATE_CONTRACTS=ClPriceMath script/security-gambit.sh   # Gambit on one file
```

A real finding is fixed. A false positive, or a surviving Gambit mutant whose change cannot be observed, is accepted in the tool's file in `contracts/security/` (`slither-triage.json`, `aderyn-triage.json`, `semgrep-triage.json`, `4naly3er-triage.json`, `mythril-triage.json`, `slither-upgradeability-triage.json`, `gambit-triage.json`) with its fingerprint and a one-line reason; `script/security-gate.py` fails the run on anything neither fixed nor accepted. The full gate list is in [`contracts/README.md`](contracts/README.md#security-tooling).

## Formal verification

Certora runs locally in WSL, not in CI; rules follow the proof rule in [`contracts/certora/README.md`](contracts/certora/README.md#proof-rule).

## Licence of contributions

A contribution is licensed under the licence of the file it changes: the Business Source License 1.1 in [`LICENSE`](LICENSE) for Avana's code, and the file's own SPDX licence for the third-party files listed in [`LICENSES/LICENSING.md`](LICENSES/LICENSING.md). By opening a pull request you confirm that you have the right to submit the change under that licence. A new file Avana owns starts with the BUSL-1.1 header that `contracts/script/check-licence.sh` checks:

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs
```

Code ported from another project keeps that project's licence: its file carries the origin's SPDX identifier and names the origin and commit in its header, a Solidity file is added to `contracts/security/licence-allowlist.txt`, and the component gets an entry in [`LICENSES/THIRD_PARTY_LICENSES.md`](LICENSES/THIRD_PARTY_LICENSES.md) and, where its licence requires one, in [`NOTICE`](LICENSES/NOTICE).

