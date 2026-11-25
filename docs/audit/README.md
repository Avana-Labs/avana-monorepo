# audit

Audit status and an index of the verification evidence for Avana's current core. The evidence lives next to the code it checks; this page points to it. Records about the code before the 2026-11-18 redesign were removed with that code.

## Audit status

Avana is going through an internal audit: an internal manual review of the code and an automated review. There has been no external audit yet. When those steps finish, the audit opens to external auditors and to the public.

The bug bounty has not started. It will be announced. Until then, report a vulnerability as [`SECURITY.md`](../../SECURITY.md) describes.

## Formal verification

| Evidence | Where |
|---|---|
| Certora confs, one per verified contract or harness | [`contracts/certora/conf/`](../../contracts/certora/conf/), specs in [`contracts/certora/specs/`](../../contracts/certora/specs/), rules and proof rule in [`contracts/certora/README.md`](../../contracts/certora/README.md) |
| Floor-credit proof | The LP-vault credit design record, [`contracts/design/vault.md`](../../contracts/design/vault.md) |

The Prover runs locally in WSL, not in CI; CI runs only the methods check (`certora/check-methods.py`, the `cvl` step of the fast security tier). `certoraMutate` also runs locally (`contracts/script/certora-mutate-local.sh`).

## CI gates

| Workflow | When | What it runs |
|---|---|---|
| [`contracts.yml`](../../.github/workflows/contracts.yml), fast | Every pull request that touches `contracts/` | Format, lint and build; the ci test profile in 3 shards (fuzz 1,000 runs, invariants 64 at depth 64); gas snapshots; the generated-ABI check; the fast security tier when `contracts/src/` changes |
| `contracts.yml`, full | By hand | The ci profile in 10 shards (fuzz 10,000 runs, invariants 1,000 at depth 100), gas, ABIs, branch coverage and the fast security tier |
| `contracts.yml`, long | By hand: after a large protocol change and on a release tag's commit | The full suite plus the deep invariant campaign, the Ethereum and Base fork tests, the FFI differential suite and SMTChecker, one target per job |
| [`security-slow.yml`](../../.github/workflows/security-slow.yml) | By hand | Echidna, Medusa, Halmos, hevm and Mythril, one job per target (`contracts/script/security-slow.sh`); `campaign` runs a layer's pre-audit fuzzing campaign |
| [`mutation-gate.yml`](../../.github/workflows/mutation-gate.yml) | By hand | slither-mutate, Gambit and Necessist per layer (`.github/security/mutation-layers.json`); `mutation-summary` passes only when every job passed |

The fast security tier is `contracts/script/security-fast.sh`: format, file sizes, licence headers, `forge lint`, a warnings-denied build with size limits, the Certora methods check, solhint, Slither, slither-check-upgradeability, Aderyn, Semgrep, 4naly3er and the storage-layout check. Each tool's gate and severity are listed at the top of the script.

## Triage and thresholds

A finding at or above a tool's gate fails its step unless an entry in the tool's triage file accepts it with a reason. All files are in [`.github/security/`](../../.github/security/):

| File | Tool |
|---|---|
| `slither-triage.json`, `slither-upgradeability-triage.json` | Slither, slither-check-upgradeability |
| `aderyn-triage.json` | Aderyn |
| `semgrep-triage.json` | Semgrep |
| `4naly3er-triage.json` | 4naly3er |
| `mythril-triage.json`, `mythril.conf` | Mythril |
| `slither-mutate-triage.json`, `gambit-triage.json`, `necessist-triage.json` | Mutation gates |
| `mutation-layers.json` | Which contracts and tests each mutation layer covers |
| `halmos-bounds.json` | Halmos checks allowed to stop at their bound (must list none) |
| [`coverage-thresholds.json`](../../.github/security/coverage-thresholds.json) | Branch-coverage minimum per `src/` file (floor 80%; every file is set at 100%), with each unreachable branch and its reason (`contracts/script/coverage-gate.py`) |
| `size-margins.json` | Contract-size margins |
| `licence-allowlist.txt` | Licence identifiers allowed on ported files |
