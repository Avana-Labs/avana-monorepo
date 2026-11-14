# 4naly3er

## What it proves

4naly3er reports the common audit-report issue classes (low-severity and non-critical patterns, gas notes, centralization notes) over `contracts/src/`, giving a second static view in the format external audit contests use. Findings go through the same triage gate as Slither and Aderyn.

## How to run

`script/install-security-tools.sh --4naly3er` installs 4naly3er in `tools/4naly3er`; `script/security-fast.sh` runs it over `contracts/src/` as a fast-tier step, with triage in `contracts/security/4naly3er-triage.json`.

## Scope

Every file under `contracts/src/`.

## How often it runs

Fast tier (decided 2026-11-10).

## Latest result

No run is recorded in this folder; the accepted findings are in `contracts/security/4naly3er-triage.json`.
