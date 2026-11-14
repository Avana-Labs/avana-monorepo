# solhint, forge lint, formatting, warnings-denied build and file sizes

## What it proves

- `forge fmt --check`: the code is in the repository's format.
- `script/check-file-size.sh`: every implementation file is at most 500 lines of code and every interface at most 300 lines (`Q-240`, `TEST-207`).
- `forge lint -D notes`: every lint of every severity on `src/` (external ABI mirrors excluded), with the excluded lints listed and reasoned in `foundry.toml` `[lint]`.
- `forge build --force -D warnings --sizes` of `src/`: no compiler warning, and every runtime code within 24,576 bytes.
- solhint 6.2.5 with `.solhint.json`: security rules (no `tx.origin`, no inline assembly or low-level calls without a reviewed suppression, reentrancy, unchecked calls) plus custom errors, explicit types, no unused imports, one contract per file and comprehensive interfaces; zero warnings.

## How to run

```bash
cd contracts && script/security-fast.sh fmt size lint build solhint
```

Configuration: `contracts/foundry.toml` (`[fmt]`, `[lint]`), `contracts/.solhint.json`, `contracts/.solhintignore`, `contracts/script/check-file-size.sh`.

## Scope

Every file under `contracts/src/`.

## How often it runs

Fast tier on every push and pull request, every contract gate, and the `fmt, lint, build` CI job.

## Latest result

2026-11-10, fast tier started 21:33: every step passed. `fmt` pass; `size` pass, largest implementation `AvanaTimelock.sol` at 346 lines of code, largest interface `IAaveV4Spoke.sol` at 266 lines; `lint` 0 findings; `build` pass with no warning; `solhint` 0 warnings. The size check re-run on 2026-11-10 at 22:4x gives the same result. Inline suppressions in `src/`: 171 comments, each at one reviewed site (counts in [slither/results/triage-summary-2026-11-10.md](../slither/results/triage-summary-2026-11-10.md)).

## Results folder

- [`security-fast-run-2026-11-10.log`](results/security-fast-run-2026-11-10.log): console output of the whole fast tier, every step.
- [`forge-lint.txt`](results/forge-lint.txt) and [`solhint.txt`](results/solhint.txt): empty, which is the passing output.
- [`build-src.txt`](results/build-src.txt): warnings-denied build with the size table.
- [`check-file-size-2026-11-10.txt`](results/check-file-size-2026-11-10.txt): the size check.
