# Echidna

## What it proves

Echidna runs every `<Subject>Properties` harness in `contracts/test/invariant/echidna/` as a coverage-guided fuzzing campaign, in property mode (each `property_` function must stay true after any call sequence) and in assertion mode (no assertion in an entry point can fail). One property per `INV` row on the contract's spec page.

## How to run

From `contracts/`, Echidna 2.3.3 from `tools/bin/`:

```bash
script/security-slow.sh build echidna
ECHIDNA_TEST_LIMIT=1000000 ECHIDNA_TIMEOUT=1800 script/security-slow.sh build echidna      # full budget
```

Configuration: `contracts/echidna.yaml` (`testLimit` 50,000, `seqLen` 100, time delay up to 14 days, block delay up to 100,800); `ECHIDNA_TIMEOUT` 900 s per harness and mode by default. Corpora persist in `out-security/corpus/echidna/`.

## Scope

27 harnesses: AaveV3FlashSource, AvanaRoles, AvanaTimelock, Collateralization, CoverageSpoke, DebtOracle, DexPathRoute, LPOracle, LPPriceMath, Lock, LockSlot, MarketRegistry, ParameterStore, ParameterStoreAdminOracle, ParameterStoreAdminRisk, ParameterStoreListing, PayoutEscrow, PegModuleRoute, PositionProxy, ProxyManager, RiskModule, SettlementMath, SlipstreamIntegration, UniswapV3Integration, VaultTokenFactory, VaultToken, WrapperThenDexRoute (94 `property_` functions).

## How often it runs

Slow tier at each layer gate (2.1 … 2.6), full budget, over every contract of the layer; on every push to `main` in CI (`security-slow.yml`), one job per harness running both modes at 1,800 seconds each, with the harness's corpus restored from the previous run and stored again. Before audit, each layer gets a 24-hour Echidna campaign: `security-slow.yml` started by hand with `campaign` set to the layer runs eight 3-hour jobs per harness and mode, each with a fresh seed and starting from the stored corpus, then merges the eight corpora and stores the result as the harness's corpus, which every later CI run replays. Harnesses whose subject is in no layer of `security/mutation-layers.json` (RiskModule) run under `campaign: other`. AvanaRoles, the Lock and the AvanaTimelock also ran the slow tier at their contract gate.

## Latest result

| Run | Harnesses | Result |
|---|---|---|
| 2026-11-09 slow tier | AvanaRolesProperties, LockSlotProperties | Every property passes in both modes; about 50,000 calls each |
| 2026-11-10 16:02 slow tier (Lock gate) | AvanaRoles, Lock, LockSlot | Invalid for Lock: the console reported every property passing, but no log of this run shows `Total calls` above 0 for the Lock harness, and the Lock logs of the next run record `Total calls: 0` with crashed workers, so this run does not count as an Echidna campaign of Lock (Medusa and hevm passed for Lock in the same run) |
| 2026-11-10 16:4x slow tier (timelock gate) | AvanaRoles, AvanaTimelock, Lock, LockSlot | AvanaRoles and LockSlot: every property passes, about 50,000 calls per mode. AvanaTimelock and Lock: the logs record `Total calls: 0` and `Worker n Crashed: Set.elemAt: index out of range`, so these two harnesses were not exercised by Echidna in that run; Medusa exercised the AvanaTimelock harness for 14 m 57 s (1,788,580 calls, no failure) and the Lock harness passed in Medusa and hevm |

A campaign counts only when its log shows `Total calls` above 0.

## Results folder

- [`logs/`](results/logs/): the eight Echidna logs of 2026-11-10 in `out-security/echidna/` (property and assertion mode per harness).
- [`security-slow-run-lock-2026-11-10.log`](results/security-slow-run-lock-2026-11-10.log), [`security-slow-run-timelock-2026-11-10.log`](results/security-slow-run-timelock-2026-11-10.log), [`security-slow-run-2026-11-09.log`](results/security-slow-run-2026-11-09.log): console output of `security-slow.sh`.
