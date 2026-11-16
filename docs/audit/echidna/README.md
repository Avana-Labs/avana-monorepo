# Echidna

## What it proves

Echidna runs every `<Subject>Properties` harness in `contracts/test/invariant/echidna/` as a coverage-guided fuzzing campaign, in property mode (each `property_` function must stay true after any call sequence) and in assertion mode (no assertion in an entry point can fail). One property per `INV` row on the contract's spec page.

## How to run

From `contracts/`, Echidna 2.3.3 from `tools/bin/`:

```bash
script/security-slow.sh build echidna
ECHIDNA_TEST_LIMIT=100000 ECHIDNA_TIMEOUT=600 script/security-slow.sh build echidna        # nightly CI budget
```

Configuration: `contracts/echidna.yaml` (`testLimit` 50,000, `seqLen` 100, time delay up to 14 days, block delay up to 100,800); `ECHIDNA_TIMEOUT` 900 s per harness and mode by default. Corpora persist in `out-security/corpus/echidna/`.

## Scope

35 harnesses: AaveAdapter, AaveAdapterBorrow, AaveAdapterWithdraw, AaveV3FlashSource, AvanaFirstLossReserve, AvanaRoles, AvanaTimelock, Collateralization, DebtOracle, DexPathRoute, FlashLiquidator, LPOracle, LPPriceMath, LPVaultSwap, LPVaultSwapLiquidation, Lens, Lock, LockSlot, MarketRegistry, ParameterStore, ParameterStoreAdminOracle, ParameterStoreAdminRisk, ParameterStoreListing, PayoutEscrow, PegModuleRoute, PositionProxy, ProxyManager, RiskModule, SettlementMath, SlipstreamIntegration, SpeedLimitMath, UniswapV3Integration, VaultTokenFactory, VaultToken, WrapperThenDexRoute (148 `property_` functions, counting the five the two AaveAdapter path harnesses share). AaveAdapterBorrow, AaveAdapterWithdraw and LPVaultSwapLiquidation run the borrow path (pledge, borrow, repay), the withdrawal path and the liquidation path (price moves to HF 0.70–0.99, `liquidate` over the routes, escrowed payouts, claims) on the production logic contracts over stand-ins of Aave V4 and the policy contracts; the other harnesses test one contract or library each. The real Aave V4 stack is exercised by the Foundry invariant suites (`FullStack`, `Integration`, `AaveAdapter`).

## How often it runs

Slow tier at each layer gate (2.1 … 2.6), full budget, over every contract of the layer; on every push to `main` in CI (`security-slow.yml`), one job per harness running both modes at 1,800 seconds each, with the harness's corpus restored from the previous run and stored again. Before audit, each layer gets a 24-hour Echidna campaign: `security-slow.yml` started by hand with `campaign` set to the layer runs eight 3-hour jobs per harness and mode, each with a fresh seed and starting from the stored corpus, then merges the eight corpora and stores the result as the harness's corpus, which every later CI run replays. Harnesses whose subject is in no layer of `security/mutation-layers.json` (RiskModule) run under `campaign: other`. AvanaRoles, the Lock and the AvanaTimelock also ran the slow tier at their contract gate.

## Latest result

| Run | Harnesses | Result |
|---|---|---|
| 2026-11-09 slow tier | AvanaRolesProperties, LockSlotProperties | Every property passes in both modes; about 50,000 calls each |
| 2026-11-10 16:02 slow tier (Lock gate) | AvanaRoles, Lock, LockSlot | Invalid for Lock: the console reported every property passing, but no log of this run shows `Total calls` above 0 for the Lock harness, and the Lock logs of the next run record `Total calls: 0` with crashed workers, so this run does not count as an Echidna campaign of Lock (Medusa and hevm passed for Lock in the same run) |
| 2026-11-10 16:4x slow tier (timelock gate) | AvanaRoles, AvanaTimelock, Lock, LockSlot | AvanaRoles and LockSlot: every property passes, about 50,000 calls per mode. AvanaTimelock and Lock: the logs record `Total calls: 0` and `Worker n Crashed: Set.elemAt: index out of range`, so these two harnesses were not exercised by Echidna in that run; Medusa exercised the AvanaTimelock harness for 14 m 57 s (1,788,580 calls, no failure) and the Lock harness passed in Medusa and hevm |
| 2026-11-14 slow tier on main, run 43653574421 (48864ef) | FlashLiquidatorProperties | First run of this harness in CI (the scheduled run 43595414156 of the same day was planned on aa340fb, before PR #27 added the harness, so it had no job for it). Echidna: both properties and the four assertion entry points passing, 1,000,241 calls in property mode and 1,000,267 in assertion mode. Medusa: 6 of 6 tests passed, 5,003,738 calls in 28 m 58 s. hevm: `callbackOutsideContext`, `foreignInitiator` and `liquidate` QED; `noMinterCallback` explored only partially (its symbolic first argument shares the selector's calldata word, so hevm explored every function of the helper), fixed by choosing among four concrete initiators |
| 2026-11-15 slow tier (run 43653574421, `48864ef`) | DebtOracleProperties | `property_nonLiveServesAtLeastAccepted` falsified after 5 calls (shrunk: two standby switches, `move(0, 1)` raising the primary 50 %, two more switches): Drifting, primary 149,985,000, alternate and accepted 99,990,000, served 99,990,000. The property expected `max(p, b, A)` while Drifting; `SPEC-ORC-018` and `DebtOracleEvaluation._serve` serve `max(min(p, b), A)`, so the property was wrong, not the oracle. Fixed to `max(min(p, b), A)`; `test/unit/DebtOracle.FuzzHarness.unit.t.sol` replays Medusa's one-call form of the same failure ([register](../findings-register.md) `SLOW-03`). The other 3 properties and every assertion passed |

A campaign counts only when its log shows `Total calls` above 0.

## Results folder

- [`logs/`](results/logs/): the eight Echidna logs of 2026-11-10 in `out-security/echidna/` (property and assertion mode per harness).
- [`security-slow-run-lock-2026-11-10.log`](results/security-slow-run-lock-2026-11-10.log), [`security-slow-run-timelock-2026-11-10.log`](results/security-slow-run-timelock-2026-11-10.log), [`security-slow-run-2026-11-09.log`](results/security-slow-run-2026-11-09.log): console output of `security-slow.sh`.
