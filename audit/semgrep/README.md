# Semgrep

## What it proves

Semgrep runs the smart-contract rule set (`contracts/tools/semgrep-smart-contracts/solidity/`) over `contracts/src/`: patterns from known exploits and audit findings (unchecked transfers, oracle misuse, access-control and proxy mistakes, ERC-20 and ERC-721 pitfalls) that complement Slither's and Aderyn's detectors. Findings go through the same triage gate as Slither and Aderyn.

## How to run

```bash
cd contracts && .venv/bin/semgrep --config tools/semgrep-smart-contracts/solidity --metrics=off src/
```

Installed: `contracts/.venv/bin/semgrep` and the rule set in `contracts/tools/semgrep-smart-contracts/`.

## Scope

Every file under `contracts/src/`.

## How often it runs

Fast tier (decided 2026-11-10). First run at the layer 2.1 gate, as a fast-tier step from then on.

## Latest result

Not run yet; the first run is at the layer 2.1 gate. `results/` is empty until then.
