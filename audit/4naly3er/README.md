# 4naly3er

## What it proves

4naly3er reports the common audit-report issue classes (low-severity and non-critical patterns, gas notes, centralization notes) over `contracts/src/`, giving a second static view in the format external audit contests use. Findings go through the same triage gate as Slither and Aderyn.

## How to run

4naly3er is added to `script/install-security-tools.sh` and run as a fast-tier step over `contracts/src/` when it lands.

## Scope

Every file under `contracts/src/`.

## How often it runs

Fast tier (decided 2026-11-10). First run at the layer 2.1 gate.

## Latest result

Not run yet; the first run is at the layer 2.1 gate. `results/` is empty until then.
