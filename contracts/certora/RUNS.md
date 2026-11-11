# Run log

Every run of this folder's checks, newest last.

## 2026-11-10 — methods check against the final interfaces

- **Scope**: the 27 spec files in `specs/` (22 contract specs, 5 setup models) and the 25 confs in `conf/`, written against the interfaces in `contracts/src/` and `PROP-001` … `PROP-074` of 5.2.
- **Commands** (from `contracts/`):
  - `python3 certora/check-methods.py` against `out/` (`forge build`);
  - `python3 certora/check-methods.py --out out-security/build/src` against the fast tier's build;
  - `script/security-fast.sh cvl`.
- **Tools**: Python 3.9.6 (standard library only), Foundry `forge` 1.9.0, solc 0.8.28.
- **Counts**: 735 methods entries checked, 0 errors, in each of the first two runs; every one of `PROP-001` … `PROP-074` has at least one tagged rule or invariant (299 rules and invariants in all).
- **Exit codes**: 0, 0, 0.
- **Prover**: not run. `contracts/src/` holds interfaces only, so no conf compiles; the machine has no Java runtime and no `CERTORAKEY`. certora-cli 8.20.3 is installed in `contracts/.venv`.
- **Traceability**: `spec/05-verification/trace.py` reports no error from `contracts/certora/`.

## 2026-11-10 — methods check after the alignment with the final 5.2 text

- **Scope**: the rules of `PROP-045`, `PROP-046`, `PROP-058`, `PROP-062`, `PROP-071` and `PROP-072` rewritten to the final 5.2 text (findings `CVL-F-01` … `CVL-F-07`), and the interface additions `IGhoFlashMinter` (`contracts/src/interfaces/external/gho/`), `ILPVaultSwap.TIMELOCK()`, `ISettlementRoute.AAVE_ADAPTER()` and `IDebtBuyRoute.AAVE_ADAPTER()`.
- **Rules changed**: `RiskModule.spec` `minimumPledgeUsesAcceptedPrice` (accepted price; `min(minPledgeUsd, RESCUE_MIN_PLEDGE_USD)` for a rescue top-up) and `borrowRefusesFrozenCollateral` (supplied shares > 0); `MarketRegistry.spec` `noCallFreezesAProtectedAddress` (protected at call time); `AvanaTimelock.spec` `expiredOperationOnlyCleanedUp` (or a permitted `cancel`); `LPVaultSwap.spec` `deleverageMakesNoDrawFeeOrBonusPayment` (the buy route of a non-GHO debt is a GHO recipient), the new invariant `adminRolesHeldOnlyByTimelock` and the `flashFee` summary; `SettlementRoute.spec` and `DebtBuyRoute.spec` lock rules (holder is LPVaultSwap or `AAVE_ADAPTER()`).
- **Commands** (from `contracts/`): `PATH=$HOME/.foundry/bin:$PATH forge build`; `python3 certora/check-methods.py`.
- **Counts**: 739 methods entries checked, 0 errors.
- **Exit codes**: 0, 0.
- **Prover**: not run, for the reasons of the previous entry.

## 2026-11-10 — methods check with the rule stubs for the AMM-neutral design

- **Scope**: the new rule stubs for `PROP-075`, `PROP-076`, `PROP-078`, `PROP-080`, `PROP-083` (`FlashSource.spec`, `UniswapV3Integration.spec`, `SlipstreamIntegration.spec`, `ProxyManagerIsolation.spec`, `RiskModuleDrift.spec` and their confs; `Lock.spec` restated for the two members), against the interfaces in `contracts/src/` while they are being rewritten for the AMM-neutral design.
- **Change to `check-methods.py`**: ABIs are read from every `out/**/<File>.sol/` folder, so interfaces that share a name in different folders (the Uniswap v3 and the Slipstream `INonfungiblePositionManager`) are both checked; `AaveV3FlashSource` binds to `IFlashSource` and `IAaveV3FlashLoanReceiver`.
- **Commands** (from `contracts/`): `forge build --out <scratch>/forge-out`; `python3 certora/check-methods.py --out <scratch>/forge-out`.
- **Counts**: 760 methods entries in 32 spec files, 160 errors. The six new and restated spec files have 0 errors; the 160 errors are in 16 earlier spec files whose methods entries name functions the rewritten interfaces changed or removed (beacon proxy, two-token LPVault, GHO flash minter, global pause).
- **Exit code**: 1.
- **Prover**: not run, for the reasons of the first entry.


## 2026-11-10 — methods check after regenerating the methods blocks

- **Scope**: every spec in `specs/`, with the methods blocks, call sites and summaries rewritten to the AMM-neutral interfaces (`positionKey`, n-token arrays, `PositionRef`, per-Hub pause, logic-free PositionProxy, `IFlashSource`, `ISettlementRoute.swap`). `DebtBuyRoute.spec` and its two confs are removed with the debt-buy leg; the route confs are `PegModuleRoute.conf`, `DexPathRoute.conf` and `WrapperThenDexRoute.conf`. `AaveAdapter.conf` and `AaveAdapterGates.conf` link the real PositionProxy to the Adapter.
- **Commands** (from `contracts/`): `forge build --out <scratch>/forge-out`; `python3 certora/check-methods.py --out <scratch>/forge-out`.
- **Counts**: 712 methods entries in 31 spec files, 0 errors.
- **Exit code**: 0.
- **Prover**: not run, for the reasons of the first entry.

## 2026-11-10 — methods check after the final interface names

- **Scope**: `VaultTokenFactory` keyed by (CDP Spoke, market key) (`tokenOf(spoke, marketKey)`, `predictAddress(spoke, marketKey)`); `ISettlementBudget` with the per-call cap per (Spoke, debt reserve) and the market and asset windows (`SettlementBudget.spec` rewritten, new rule `drawLeavesOtherMarketsWindows` for `PROP-084`); `recredit` with its top-up bytes; the ParameterStore Hub-keyed tighteners and `tightenConsistencyToleranceBps`; the rule stubs retagged to `PROP-075`, `PROP-076`, `PROP-078`, `PROP-080`, `PROP-083`.
- **Commands** (from `contracts/`): `forge build --force`; `script/security-fast.sh` (its `cvl` step runs `certora/check-methods.py`).
- **Counts**: 718 methods entries in 31 spec files, 0 errors.
- **Exit code**: 0.
- **Prover**: not run, for the reasons of the first entry.

## 2026-11-10 — methods check after removing the settlement budget and in-kind settlement

- **Scope**: `SettlementBudget.spec` and `SettlementBudget.conf` deleted with the contract (Q-397); LPVaultSwap.spec rules rewritten for the caller top-up that pays any settlement gap (`everySeizedUnitIsBurnedAndSettled` for `PROP-020` and `PROP-047`, `callerTopUpClosesTheGap` for `PROP-019`) and for the removal of in-kind settlement, shortfall reports and the probe (`liquidatePaysNoPoolTokensOut` for `PROP-021`, Q-401); `PROP-063` and `PROP-084` now map to the LPVaultSwap waterfall rules; the registry model drops the in-kind window; MarketRegistry.spec and ParameterStore.spec drop `autoEnableInKind`, `SETTLEMENT_BUDGET` and `perCallCap`.
- **Commands** (from `contracts/`): `forge build --force`; `python3 certora/check-methods.py`.
- **Counts**: 678 methods entries in 30 spec files, 0 errors.
- **Exit code**: 0.
- **Prover**: not run, for the reasons of the first entry.

## 2026-11-10/11 — first prover runs of the confs with merged implementations

- **Scope**: the 16 confs whose implementation is merged: Lock, AvanaTimelock, ParameterStore, MarketRegistry, VaultToken, VaultTokenFactory, PositionProxy, ProxyManager, ProxyManagerIsolation, PayoutEscrow, CoverageSpoke, FlashSource, Collateralization, DexPathRoute, WrapperThenDexRoute, PegModuleRoute. No conf exists for AvanaRoles (a constants library). The confs of unwritten contracts (LPOracle, DebtOracle, LPVault and AMM integrations, RiskModule, RiskModuleDrift, AaveAdapter, AaveAdapterGates, LPVaultSwap, Hub) were not run.
- **Tools**: certora-cli 8.20.3 (prover 8.20.3, cloud), Java 21 (Temurin, local type checking), solc 0.8.28 (`tools/bin/solc-0.8.28`). Every conf runs with `rule_sanity: basic`; a vacuous rule or a tautological invariant is reported as SANITY_FAIL.
- **Commands** (from `contracts/`, with `JAVA_HOME` set to `tools/jdk-21` and `CERTORAKEY` loaded from `.env`):
  - `.venv/bin/certoraRun certora/conf/<X>.conf --compilation_steps_only` for each conf: exit 0 for all 16 after the fixes below.
  - `.venv/bin/certoraRun certora/conf/<X>.conf --global_timeout 2400` (submit, then poll the job), with `--rule <names>` for the re-runs of single rules. A job that reaches the global timeout is halted and writes no `output.json`; its rules without a result in the job log are counted as TIMEOUT.
  - `python3 certora/check-methods.py`, `script/security-fast.sh cvl`: 0 errors.
- **Compile and type-check fixes**: `lastReverted` read after view calls (Lock.spec `acquireRefusedOutsideTheTwoMembers`, AvanaTimelock.spec `setNormalDelayOnlyFromTheTimelock`, ParameterStore.spec tighten rules): the flag is now captured right after the `@withrevert` call; invariants without a block end with `;` (AvanaTimelock.spec); user-defined types are qualified by a contract in the scene (`ParameterStore.MarketParams`, `MarketRegistry.PauseState`, `VaultTokenFactory.PositionShape`, `Collateralization.PledgeCharge`, `CollateralizationBase.Bucket`, …); ProxyManager.spec no longer imports `RegistryModel.spec` (its pause ghosts name MarketRegistry types) and keeps a local freeze ghost.
- **Conf fixes**: `ParameterStore.conf` lists the five logic contracts and links the router's `_*_LOGIC` immutables; `MarketRegistry.conf` links the safety logic through `certora/harness/MarketRegistrySafetyLogicHarness.sol` and adds `-disableInputSizeValidation true` (the router forwards undecoded calldata, which aborted the first run with an internal size check); `VaultToken.conf` and `VaultTokenFactory.conf` `loop_iter` 7 (constructor binding check); route confs `loop_iter` 5 (held-token loops); `hashing_length_bound` 2,048 in `ProxyManager.conf`, `ProxyManagerIsolation.conf` and `AvanaTimelock.conf`; `-enableStorageSplitting false` in the route confs and `FlashSource.conf` (transient-storage hooks).

### Results (latest run of each rule)

Job links: `https://prover.certora.com/output/6758641/<job>`.

| Conf | Job(s) | Verified | Violated | Sanity fail | Timeout |
|---|---|---|---|---|---|
| Lock | `0f0bbe338f844d87ba9968713df8b185` | all 11 | — | — | — |
| AvanaTimelock | `494cd1ef04884c39bcf51cc31aa1375c`, `a5fde9a1d4354ed5be462d155a5649a1` | 18 (incl. `openExecutorOnlyByToggle`, `openExecutorRoleCallsRevert`, `togglingFlagClearBetweenCalls` in the second job) | — | — | `executeBatchWindow`; the constructor step of `shortListWithinEligible`, `timelockIsItsOwnOnlyAdmin`, `timelockNeverShortEligible` (UNKNOWN: solver gave up) |
| ParameterStore | `5cf1a73b625f4624b65c99923de6cb24` (halted at 40 min) | 11: `tightenHardHealthFloorIsSafer`, `tightenGateRecoverySecondsIsSafer`, `tightenSlippageStaysAboveMarketMinimum`, `tightenConsistencyStaysAboveGlobalMinimum`, `tightenMinPledgeUsdOnlyRaisesWithinBound`, `loosenMinPledgeUsdOnlyLowers`, `livenessFloorsStayBelowTheirAllowances`, `loosenHealthFactorStepHasNoUnderflow`, `capStepArithmeticFits`, `tightenIsReachable`, envfree | — | — | `tightenFeedToleranceStaysAboveTokenMinimum`, `graceSettersStayInsideGlobalBounds`, `tightenLowersScalars`, `minPledgeUsdChangesOnlyThroughItsSetters`, `settersNeedApplicationAdmin`, `gateRecoveryInBoundsOnceAdministered`, `adminRolesOnlyTimelock` |
| MarketRegistry | `82741daf7f694336b3b4eab5a93165c6` (halted at 40 min), `bd8d01133b1449b0bdef298911f9da8e` | 10: `freezeLimitIsTwenty`, `pauseIsReachable`, `initializeSetsTheRoleMap`, `unfreezeRevertsWhilePaused`, `pauseRefusesNoneAndTheCurrentReason`, `freezeAddressIsReachable`, `freezeAddressCanFreezeTheLastKeeper`, `removeDebtReserveOnlyWhenNothingOwed`, `roleChangesNeedTheRoleAdmin`, envfree | — | — | `pauseTransitions`, `reasonIsNoneExactlyWhenNotPaused`, `freezeGuardianCannotLift`, `onlyUnfreezeAddressLiftsAFreeze`, `noCallFreezesAProtectedAddress`, `activateMarketRunsTheDriftCheck`, `onlyRoleCanCall`, `roleAdminsNeverChange`, `adminRolesOnlyTimelock`; in the second job (two rules), `freezeAddressGates` and `appAdminAdministeredByDefaultAdmin` (constructor step and every function step verified except `freezeAll` and `setPriceSource`, still running at the halt) |
| VaultToken | `6bfe727afcd349819354fa4acf36fa35` | all 20 | — | — | — |
| VaultTokenFactory | `09bac6e98f04415491e094669d3d7f3a` | all 7 | — | — | — |
| PositionProxy | `58d4d482ec8442e0ba96406d32591f0d` | all 6 | — | — | — |
| ProxyManager | `195a664988f54afa9c5ddd05dd0e92e0` | all 4 | — | — | — |
| ProxyManagerIsolation | `8da8ab97dc3d4df797db7b55bfd7125e` | all 4 | — | — | — |
| PayoutEscrow | `3f8731c0a94045939591ca3eb7b4a5f7` | all 9 | — | — | — |
| CoverageSpoke | `6c2c483a5deb4928b4a05800c9db65d0` | all 4 | — | — | — |
| FlashSource | `ff2175f568234aca99b9fe4be2fbdecf` | all 9 | — | — | — |
| DexPathRoute | `830e0ae334d84b7c912eb85e7bfad7fa` | all 6 | — | — | — |
| PegModuleRoute | `5a933370372743d1ae44af2bedb59604` | all 6 | — | — | — |
| WrapperThenDexRoute | `ffbc2d72c7ec43ae82c2f58e5f4580c9` | 5: `swapOnlyForLpVaultSwapUnderLock`, `swapDeliversAtLeastMinOut`, `swapIsReachable`, `swapCallbackRefusedOutsideHop`, envfree | — | — | `routeBindingsSet` constructor step (UNKNOWN; the same invariant is verified on DexPathRoute and PegModuleRoute) |
| Collateralization | `8a8379652a2f4faaacd36ef1e8a3c13a` (halted at 40 min), `0d48d8c06bc64e41a7efbdb328c8b69f`, `d82d27ef94ad4668a6dc6d31c839d64b` | 8: `settlePendingRefusedDuringSeizure`, `settlePendingKeepsSupplyBacked`, `settlePendingLowersGapByItsUnits`, `pledgeOfRecordedPositionReverts`, `pledgeCreditsUnitsReadAfterCustody`, `pledgeIsReachable`, `recreditAddsUncreditedLiveUnits` (third job), envfree | `pledgeInsertsInOrder` (rule precondition, below) | — | `settlePendingChecksBurnAndPaysOnlyLpVaultSwap` (third job, after its fix); the remaining 33 of the 43 rules and invariants had no result when the first job halted |

### Rules changed after a counterexample or a sanity failure

Every change keeps the rule's meaning; where a rule was wrong against the spec it now states the spec.

- Lock.spec `acquireOnlyByMembersWhileFree`, `secondAcquireFails`: counterexample with `AAVE_ADAPTER() == 0` and a zero caller (immutables are unconstrained in a rule). Both now require `lockMembersDistinctAndSet`, proved from the constructor.
- AvanaTimelock.spec `openExecutorRoleCallsRevert`, `openExecutorOnlyByToggle`: counterexample with the storage flag `_toggling` set in the pre-state. New invariant `togglingFlagClearBetweenCalls` (verified), required by both. `executeBatchWindow` and `scheduleBatchNeedsRequiredDelay` were vacuous at `hashing_length_bound` 224 (every batch id exceeded it); verified at 2,048.
- ParameterStore.spec `capStepArithmeticFits`: the rule claimed `cap * 3 < 2^256` for every `cap < 2^255`, which is false arithmetic. It now states the code's step check `value * 10_000 <= old * 15_000` inside the listing bound `USD_CAP_MAX = 2^128 - 1` (`PROP-044`: no overflow inside the listing bounds). `tightenGateRecoverySecondsIsSafer`: counterexample from a pre-state below 600; new invariant `gateRecoveryInBoundsOnceAdministered` (once an admin role exists the window is in [600, 7,200]), required by the rule. `tightenFeedToleranceStaysAboveTokenMinimum`: the liveness floor depends on the registry's `activePriceRoutes`, which was unresolved and returned different routes to the setter and to the rule; it is now summarised as a fixed function of the token (routes of at most two feeds).
- MarketRegistry.spec `roleChangesNeedTheRoleAdmin`, `initializeSetsTheRoleMap`: counterexamples from pre-states where `APPLICATION_ADMIN` had another admin or a Hub was already paused. New invariant `appAdminAdministeredByDefaultAdmin`, required by both; `initializeSetsTheRoleMap` now checks that `initialize` writes no pause state (on the fresh proxy storage it runs on, every Hub stays at None). `freezeAddressGates`, `noCallFreezesAProtectedAddress`: the protected set is checked in the safety logic against its own copy of the immutables, unconstrained in the prover; the rules now state the equality the router's constructor enforces (`REQ-CONFIG-005`) through the harness view `immutablesMatch`.
- VaultToken.spec `supplyChangesOnlyThroughAdapter`, `burnNeedsNoAllowanceAndLowersExactly`: counterexample with a balance above `totalSupply`, where OpenZeppelin's unchecked supply decrement wraps. Both now require the verified invariant `totalSupplyIsSumOfBalances`.
- PositionProxy.spec `executeCallsOnlyTheNamedTarget`: added that `execute` calls the named target exactly once and sends no ETH (review finding).
- ProxyManagerIsolation.spec `distinctAccountsHaveDistinctProxies`: the old rule asserted that distinct triples predict distinct addresses, which fails on a 160-bit truncation collision (the accepted assumption of `REQ-PROXY-055`). It now states `PROP-076`: a deployment whose predicted address already holds a proxy reverts, so two successful deployments never share an address. (A two-deployment form was vacuous in the prover's creation model at `dynamic_bound` 1 and 2.)
- CoverageSpoke.spec `coverDeficitOnlyAllowlistedOwnAssetAndBounded`: the Hub view ghosts were havocked by the AccessManager's unresolved `canCall`, so `fundedBalance()` differed between the rule and the call; the ghosts are persistent (a STATICCALL cannot change the Hub).
- FlashSource.spec `executeOperationRevertsWithoutActiveContext`: counterexample with an open flash context in transient storage at rule start; every rule now starts with empty transient storage (`setup/TransientModel.spec`). `flashLoanWithinPremiumCap`: the cap ghost was read after the call, past unresolved calls; it is read before the call, where the source reads it.
- SettlementRoute.spec: every rule starts with empty transient storage (the callback rule failed with a stale hop pool); new invariant `routeBindingsSet` (constructor check) required by `swapOnlyForLpVaultSwapUnderLock`, which failed with a zero AaveAdapter binding; peg-module and wrapper steps are summarised as paying their output (unresolved, they paid nothing, so every PegModuleRoute and WrapperThenDexRoute swap reverted and the swap rules were vacuous).
- Collateralization.spec `settlePendingChecksBurnAndPaysOnlyLpVaultSwap`: compared the output length with the length of `pending[vt].amounts` and picked `k` past the market's tokens; it now states one amount per market token and picks `k` among them. `recreditAddsUncreditedLiveUnits`: the LPVault's `topUpPosition` was unresolved and havocked the ledger; it is summarised in the custody model (adds arbitrary liquidity to the held position).

### Open

- `pledgeInsertsInOrder` (Collateralization.spec): the counterexample starts from a seizure list that already holds the fresh record id (list `[6663]`, new record `6663` at the maximum credit), which no reachable state has. The insert code is correct for every list without that id; the rule needs a list-membership invariant (every entry is an open record below `_nextRecordId`), which needs ghost mirrors of the seizure-list arrays.
- TIMEOUTs: the parametric rules and invariants of ParameterStore and MarketRegistry (every router function delegatecalls into its logic contract) and most Collateralization rules (via-IR, 8-record lists) did not finish within the 40-minute job limit; the AvanaTimelock constructor steps of three invariants (role loops) return UNKNOWN. These need per-rule jobs with longer limits, or narrower method filters.
- No contract bug was found: every violation traced to a rule precondition, a summary or a conf bound, listed above.

## 2026-11-11 — closing the halted and partial confs (one job per rule)

- **Why the earlier jobs halted**: the first round passed `--global_timeout 2400`; a job that reaches it is halted with no `output.json`. Jobs now run without it, one rule per job (`--rule`), up to six at a time, and wait with `--wait_for_results all`.
- **Scene fault found**: in ParameterStore.conf and MarketRegistry.conf the parametric rules and invariants also ranged over the logic contracts' own functions, called directly (they ran on the logic contracts' own storage, and `settersNeedApplicationAdmin` reported every direct logic call as a violation). Every parametric filter now has `routerEntry(f)` (`f.contract == currentContract`). In the deployment, the MarketRegistry logic contracts refuse direct calls (`_onlyDelegated`); the ParameterStore logic contracts do not, but a direct call writes only the logic contract's own storage.
- **Commands**: `.venv/bin/certoraRun certora/conf/<X>.conf --rule <rule> --wait_for_results all`; extra options per job are listed below.

### Rules changed in this round

- MarketRegistry.spec `pauseTransitions`, `onlyRoleCanCall`: the rules predated `freezeAll` and `pauseAll` (REQ-CONFIG-082) and the three functions anyone may call (`stepWindDown`, `closeMarket`: REQ-CONFIG-080; `syncDrawCap`: REQ-CONFIG-081), and reported them as violations. `pauseTransitions` now checks `freezeAll` (None to Frozen, freeze guardian or admin) and `pauseAll` (Paused with its reason, pause guardian or admin); `onlyRoleCanCall` checks both guardian sets with them and exempts the three permissionless functions. Stronger: two more functions are checked.
- MarketRegistry.spec `freezeAll`: the prover leaves the router's 4-byte `freezeAll` delegatecall unresolved (an AUTO summary that may write any router storage; `pauseAll`, with an argument, resolves), which made every state rule fail on it. The state rules leave `freezeAll` out (`resolvedEntry`), and the new rules `freezeAllFreezesOnlyFreeHubs` and `freezeAllCanFreezeAHub` check its body on the safety logic's own copy of the layout, through new harness views. Its caller check is in `onlyRoleCanCall`.
- MarketRegistry.spec `freezeGuardianCannotLift`: calls `f@withrevert`, so a function that always reverts for a caller without the pause guardian or admin role is not reported as vacuous; the assertions are unchanged.
- ParameterStore.spec: new invariant `adminRolesAdministeredByDefaultAdmin`, used in the preserved block of `gateRecoveryInBoundsOnceAdministered`, which failed on `grantRole` from a pre-state where `APPLICATION_ADMIN` had another admin.
- Collateralization.spec `pledgeInsertsInOrder`: requires the new invariant `seizureListEntriesBelowNextId` (ghost mirror of every seizure list; every entry is a record id below `_nextRecordId`), so the counterexample with the fresh id already in the list is excluded by a proved invariant, not by an assumption.
- SettlementRoute.spec `routeBindingsSet`: the induction again includes `swap` (only the always-reverting callback of PegModuleRoute is left out), so the invariant is checked over every function that can succeed.
- New confs `ParameterStoreRoles.conf` and `MarketRegistryRoles.conf`: the two role-map rules on the router without its logic contracts. The router checks the caller before it delegatecalls, and the rules read only the roles before the call, so the unresolved delegatecall (which may write any router storage) is a sound over-approximation.

### Results of this round (job IDs)

| Conf | Rule | Status | Job |
|---|---|---|---|
| ParameterStoreRoles | `settersNeedApplicationAdmin` | Verified | `4e7024600f6e49179c3d4c57ca617353` |
| MarketRegistryRoles | `onlyRoleCanCall` | Verified | `64b019d802284238bcda1b390f66903c` |
| MarketRegistry | `freezeAllFreezesOnlyFreeHubs`, `freezeAllCanFreezeAHub` | Verified | `81d051de15b34632b83e59fd44ae1adc` |
| MarketRegistry | `roleAdminsNeverChange` over `pauseAll` (resolution check) | Verified | `e8772bc4a37b43e78226dfab6ac652e8` |
| MarketRegistry | `pauseTransitions`, `reasonIsNoneExactlyWhenNotPaused` | every router function verified except `setPriceSource` (running) and `listCollateralMarket` (vacuous: no path through it succeeds in the model; open) | `df86d976031046debce0c1bc260cfcb3`, `2da17625cfdb4079bd1425566ed651fe` |
| AvanaTimelock | `shortListWithinEligible`, `timelockIsItsOwnOnlyAdmin`, `timelockNeverShortEligible` | Verified: constructor step at the conf's loop bound 6 in `51a4165fa4db461e888652ad6b397943` (`--method cancel(bytes32)`), induction step of all 16 functions in `494cd1ef04884c39bcf51cc31aa1375c` | — |
| AvanaTimelock | `executeBatchWindow` | TIMEOUT in `435e0ce6e3924472a7016229d7c15dc2`; re-run with `--smt_timeout 1800` running | `731940b165484f9bac6855e3bc19d498` |
| Collateralization | `pledgeInsertsInOrder` | Verified (requires `seizureListEntriesBelowNextId`, running) | `f74075e4fa864a22a79f11ad8ade964f` |
| Collateralization | `settlePendingChecksBurnAndPaysOnlyLpVaultSwap` | TIMEOUT in `1fece06a8377498d8b837a66d3a5e78e`; re-run with `--multi_assert_check --smt_timeout 1200` running | `2f122f4ed13c498e8137458cfe94f80a` |
| Collateralization | `seizureListEntriesBelowNextId`, `recordsBeyondNextIdAreEmpty` | running (the release, recredit and settleSeizure steps are the slow ones) | `2c7a32b20a054875a016cb91fd54e19b`, `5907b04834364d6f926f683aa273279e` |

### Submissions of 2026-11-11 (afternoon), results not yet collected

Submitted without waiting (`--split_rules`, one cloud job per rule from one local compilation):

| Conf | Rule | Job |
|---|---|---|
| ParameterStore | `gateRecoveryInBoundsOnceAdministered` | `14da6d4bd7df4e43866e5d780eb3107a` |
| ParameterStore | `graceSettersStayInsideGlobalBounds` | `67776056eb6d4d0486c9c25963610a87` |
| ParameterStore | `tightenFeedToleranceStaysAboveTokenMinimum` | `099660d3fe6e4e2fb657fcc959982369` |
| ParameterStore | `adminRolesAdministeredByDefaultAdmin` | `812766f87b434dbeb5f6c45844645190` |
| ParameterStore | `minPledgeUsdChangesOnlyThroughItsSetters` | `3e3362a39c3a4d8f8290e91f8052657e` |
| MarketRegistryListingProbe | `p1` … `p7` (how far `listCollateralMarket` gets before it reverts) | `bafa2d46244f411fb9fbec10f600a3de` |

Still running from the morning: Collateralization `seizureListEntriesBelowNextId` (`2c7a32b20a054875a016cb91fd54e19b`), `recordsBeyondNextIdAreEmpty` (`5907b04834364d6f926f683aa273279e`), `settlePendingChecksBurnAndPaysOnlyLpVaultSwap` with `--multi_assert_check` (`2f122f4ed13c498e8137458cfe94f80a`).

Cancelled to stop spending the monthly allowance on single stuck SMT tasks (logs kept): AvanaTimelock `executeBatchWindow` (`731940b165484f9bac6855e3bc19d498`, one task open for over two hours); MarketRegistry `pauseTransitions` (`df86d976031046debce0c1bc260cfcb3`) and `reasonIsNoneExactlyWhenNotPaused` (`2da17625cfdb4079bd1425566ed651fe`), each open only on `setPriceSource` for over 90 minutes.

Not submitted: Certora refused further jobs with "Usage limit reached … each unfinished job is counted as 120 minutes against a 2120-minute submission limit (9 unfinished, 2066 minutes projected)". Waiting: ParameterStore `tightenLowersScalars`, `adminRolesOnlyTimelock`, `tightenGateRecoverySecondsIsSafer`; MarketRegistry `freezeGuardianCannotLift`, `onlyUnfreezeAddressLiftsAFreeze`, `noCallFreezesAProtectedAddress`, `activateMarketRunsTheDriftCheck`, `roleAdminsNeverChange`, `adminRolesOnlyTimelock`, `freezeAddressGates`, `appAdminAdministeredByDefaultAdmin`, then `pauseTransitions` and `reasonIsNoneExactlyWhenNotPaused` once the probe has located the `listCollateralMarket` check; AvanaTimelock `executeBatchWindow`; `routeBindingsSet` on the three route confs; the remaining 31 Collateralization rules.
