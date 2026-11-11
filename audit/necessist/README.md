# Necessist

## What it proves

Necessist removes statements and method calls from the tests one at a time and reports each removal after which the test still passes: a setup step or an assertion the test does not need, which usually means the test checks less than its name says.

## How to run

Necessist is added to `script/install-security-tools.sh` and runs over `contracts/test/` with the Foundry framework at each layer gate.

## Scope

Every test file of the layer's contracts.

## How often it runs

Layer gate (decided 2026-11-10). First run at the layer 2.1 gate.

## Latest result

Not run yet; the first run is at the layer 2.1 gate. `results/` is empty until then.
