# governance

Governance payloads for Avana: the Aave DAO AIPs that configure the Aave V4 Hubs and Spokes Avana uses, and the operations the governance Safe schedules on each chain's AvanaTimelock. Roles and delays are defined in [1.4 Permissions and Roles](../spec/01-architecture/04-permissions-and-roles.md) and [2.15 Governance and Timelock](../spec/02-contracts/15-governance-and-timelock.md); parameter values and delay classes in [1.5 Protocol Parameters](../spec/01-architecture/05-parameters.md); the listing order in [3.8 Market Lifecycle](../spec/03-operations/08-market-lifecycle.md).

The proposal is the [ARFC](arfc-avana-lp-collateral.md). The current parameter values, who sets each one and why, and the v1 breakers are in [parameters.md](parameters.md).

## Layout

- Avana runs on Ethereum and Base, with one Avana Stable LP Hub on each. Governance is per chain: each chain has its own AvanaTimelock, 4-of-7 governance Safe and 3-of-5 Emergency Guardian, and nothing on one chain can act on the other (`REQ-ACCESS-173`). On Base the Aave DAO acts through its Base executor over Aave's cross-chain governance.
- Each CDP Spoke is a standard, unmodified Aave V4 Spoke owned by the Aave DAO, one per (chain, Hub, AMM protocol, risk tier): "Uniswap v3 Stable" on Ethereum and "Aerodrome Slipstream Stable" on Base at launch. Every Avana collateral reserve carries the three required settings: `receiveSharesEnabled = false`, `liquidationFee = 0` and no reinvestment controller (`REQ-HUB-092`). With the vault token's transfer rule, which accepts seized tokens only to LPVaultSwap, they make LPVaultSwap the only contract that can complete a liquidation. The drift check stops new activity on a Spoke where one of them changes, never liquidation.
- Each wallet has one immutable, logic-free PositionProxy per (wallet, CDP Spoke, market), created by the immutable ProxyManager with CREATE2. A proxy has no implementation pointer and no upgrade path; it executes only the AaveAdapter's calls, so account logic changes only with an AaveAdapter upgrade at the normal delay (`REQ-ACCESS-147`).
- Liquidation flash-borrows the debt asset from the Aave V3 Pool through the chain's flash source. The premium is 0 only once the Aave DAO grants the `FLASH_BORROWER` role by AIP; until then the Pool's premium applies, bounded by `maxFlashFeeBps` (`REQ-ACCESS-174`).
- Each (Hub, debt asset) has one Avana Umbrella (Coverage Spoke), Avana's protocol safety module, controlled by the Aave DAO and funded by Avana Labs. It holds that pair's first-loss reserve.
- There is no settlement budget and no in-kind settlement: every liquidation settles in the debt asset or reverts with nothing changed. The keeper sizes `debtToCover` and its funding for Aave V4's dust rule, including the exact flash principal and premium, and pays any rounding gap through its shortfall top-up (`Q-397`, `Q-401`). Other mechanisms removed in v1 are listed in [parameters.md](parameters.md#removed-in-v1-and-why).

## Operation folders

Every AvanaTimelock operation and every Aave DAO payload Avana prepares has its own folder, `operations/YYYYMMDD_<Chain>_<Title>/`, named by the date it is scheduled, the chain (`Ethereum`, `Base`, or `Multi` for a payload on both) and a short title in PascalCase, for example `operations/20270115_Ethereum_RaiseUsdcCreditLine/`. [`operations/_template/`](operations/_template/) is the starting point. A folder holds:

| File | Written by | Contents |
|---|---|---|
| `operation.md` | the author | Front matter (`title`, `chain`, `delay` normal or short, `proposer`, `cancel` authority, `spec` IDs, `fork_block`), the reason with current and new values, the call table and the expected changes |
| `operation.json` | the operation's script | The exact batch scheduled on the timelock: `targets`, `values`, `payloads`, `predecessor`, `salt`, `delay` |
| `before.json`, `after.json` | `contracts/test/governance/<Title>.fork.t.sol` with `FOUNDRY_PROFILE=governance` | ParameterStore values, MarketRegistry state and the role map at the pinned block, before and after the batch executes through the real timelock |
| `diff.md` | `contracts/script/governance-diff.py` | One row per value that changes |

Targets come from the generated address library (`packages/protocol/sol/Avana<Chain>.sol`) rather than pasted hex, so an operation names the same addresses as the verified manifest. The `governance` profile in `contracts/foundry.toml` is the only one with write access to `governance/operations/`. Reviewers sign only once `diff.md` shows exactly the changes `operation.md` lists, and the folder stays in the repository after execution as the record of the change.

## Who controls what

| Authority | Controls | Delay |
|---|---|---|
| Aave DAO | Each chain's Avana Stable LP Hub and its CDP, Lend and Avana Umbrella (Coverage) Spokes: deployment and upgrades of each standard CDP Spoke and its AaveOracle, the three required settings, collateral factors, caps, reserve flags, which reserves are borrowable, bonus curve, target health factor, collateral risk, risk-premium threshold, debt-asset rates, credit lines and draw caps, each Umbrella's coverage ratio and `firstLossReserveMinimum`, the `FLASH_BORROWER` role, and the unfreeze and unpause of Aave reserves. Its executor holds `PROPOSER_ROLE` (the second proposer, `REQ-ACCESS-160`), `CANCELLER_ROLE` and `DAO_CANCELLER_ROLE` on the AvanaTimelock: it can schedule through Aave governance, cancel any queued Avana operation, and is the only account that can cancel a role-change or restoring operation (`REQ-ACCESS-156`). On the MarketRegistry it undoes a guardian's standby switch at once (`cancelStandbySwitch`). | Aave governance |
| Governance Safe (4-of-7 per chain, Avana Labs plus external signers) | `PROPOSER_ROLE`, `CANCELLER_ROLE` and `EXECUTOR_ROLE` on its chain's AvanaTimelock: schedules every Avana change (upgrades, the three deployment operations and market activation, price sources, routes, parameters, keepers, role changes) and can cancel outside the DAO-only sets. No role on any other Avana contract and no instant power; a Safe guard limits it to calls to the AvanaTimelock and to itself. | Short (12 hours) or normal (5 days) per operation |
| AvanaTimelock (one per chain) | `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` on every upgradeable Avana contract, which no grant can give to any other account (`REQ-ACCESS-153`), and the `TIMELOCK` address of every immutable one. Runs each ready operation, executable by anyone while public execution is on, for 14 days (`GRACE_PERIOD`) after it becomes ready. | As scheduled; the normal delay never below `MIN_NORMAL_DELAY` (4 days) |
| Emergency Guardian (3-of-5 per chain: three Avana Labs seats, one Aave Labs seat, one LlamaRisk seat; no seat acts alone) | `APPLICATION_PAUSE_GUARDIAN` and `APPLICATION_FREEZE_GUARDIAN` on the MarketRegistry: `freeze(hub)`, `freezeAll`, `pause(hub, reason)`, `pauseAll(reason)`, `unfreeze`, `unpause`; `freezeAddress` (at most 20 in any 24 one-hour buckets, never the protected set, with no keeper floor, `REQ-ACCESS-157`); `tripMarketBreaker`, `tripDebtBreaker` and the breaker resets (`REQ-ACCESS-158`); `useStandbyRoute` and, through `APPLICATION_PAUSE_GUARDIAN` on the ParameterStore, `useStandbySecondSource` (`REQ-ACCESS-159`, `REQ-ACCESS-179`). `CANCELLER_ROLE` on the AvanaTimelock. `COVERAGE_ROLE` on each Coverage Spoke, granted by the Aave DAO: `coverDeficit` within the deficit and the funded balance. | Immediate |
| Aave Protocol Guardian | The same Avana roles as the Emergency Guardian, `COVERAGE_ROLE` included. On the Aave side, one-way `freezeReserve` and `pauseReserve` only. | Immediate |
| Joint Configuration Safe (2-of-3 per chain: Avana Labs, Aave Labs, LlamaRisk) | `APPLICATION_RISK_STEWARD` on the ParameterStore: the 20 `tighten*` setters, each only strictly safer within its bounds, and Avana's fee share `setAvanaFeeShareBps` within 0 – 5,000 bps (`REQ-ROLE-117`). `APPLICATION_PAUSE_GUARDIAN` and `APPLICATION_FREEZE_GUARDIAN` on the MarketRegistry, with the guardians' limits. No loosening, upgrade, route, source, keeper or role change, no coverage and no cancel. | Immediate |
| Risk service providers (Aave V4) | Pool risk factors, USD caps, `minPledgeUsd` and per-pool `poolShareMaxBps` in each listing package, each with the cap-sizing calculation; the deficit-breaker materiality of each non-GHO debt reserve. With the Aave DAO, the credit lines, draw caps and each Umbrella's coverage ratio and minimum in the funding ARFC. They hold no on-chain Avana role and propose changes through the governance Safe under the process below. | Through the governance Safe |

No signer key is shared between the governance Safe, the Emergency Guardian, the Joint Configuration Safe and the Aave Protocol Guardian (`REQ-ROLE-007`, `REQ-ACCESS-104`); an organisation may hold seats on several Safes, each through a different person and key.

The pause state is per Hub: `None`, `Frozen` or `Paused`, held by the MarketRegistry, and a pause carries a reason (`REQ-ACCESS-162`). Frozen blocks new pledges by accounts with no debt, and borrowing. `Paused(General)` blocks new accounts, non-rescue top-ups, borrowing, withdraw-with-debt and repay with collateral, and admits rescue top-ups (an indebted account adding collateral within its restore amount). `Paused(MintPathSuspect)`, used when the minting code itself is suspect, also refuses every top-up and re-credit. `freezeAll` and `pauseAll` apply to every Hub of the chain. The v1 breakers ([parameters.md, section C](parameters.md#c-breakers-v1)) stop new activity in one market or debt reserve: the oracle and stablecoin-band gate and the 10 % pool-share gate clear after 30 minutes of healthy observations; the deficit freeze (10,000 GHO outstanding on a CDP Spoke's GHO reserve) latches until a guardian or the timelock resets it; price drops, seizure surges and swap-route failures are alerts, and a guardian trips a breaker for routes only once they are confirmed unable to settle valid liquidations at the required size. An address freeze stops new activity by one wallet. Liquidation (both entry points), pending settlement, repay, fee collection, debt-free withdrawal and partial removal, and zero-credit release never read the pause state, a breaker or the freeze.

## Aave DAO payloads

### Deployment AIP (per chain)

Documents the Aave-side settings Avana depends on and asks the DAO to keep them (`REQ-HUB-044`):

- CDP Spokes: each a standard Aave V4 Spoke with its AaveOracle, deployed under the chain's Stable LP Hub; GHO listed as reserve 0 before any vault-token reserve; a `LiquidationConfig` with the target health factor and bonus curve the DAO decides (Avana recommends a target of 1.10 and a bonus of at least 2 % just below health factor 1, `Q-393`); `riskPremiumThreshold` above every collateral risk by at least 1 bps; `spokeUserReservesLimit` counting collateral and debt reserves;
- vault-token reserves: the three required settings, `borrowable = false`, collateral factor `floor(min(CF₁, …, CFₙ) × poolRiskFactor)` and never 0, price source = the market's LPOracle feed;
- vault-token Hub assets: only the CDP Spoke and the fee receiver registered, `drawCap = 0` for both, fee receiver `addCap = 0`, `liquidityFee = 0`;
- GHO, the first debt reserve: flat rate at or above the Core Hub GHO base rate, Aave's fixed GHO price source, `collateralFactor = 0` on the GHO reserve; Lend Spoke `addCap` equal to the chain's credit line (a proposed 2,000,000 GHO on Ethereum; Base set in the funding ARFC), filled by the treasury before any CDP Spoke `drawCap` is raised; CDP Spoke `drawCap`s summing to at most the line, each within the chain's GHO flash liquidity and swap-route depth (`SPEC-HUB-003`);
- `FLASH_BORROWER` in the Aave V3 ACLManager for LPVaultSwap's flash source on the chain's Aave V3 Pool;
- Avana Umbrella (Coverage Spoke), one per (Hub, debt asset): supply-only, zero draw capacity, the only holders of `HUB_DEFICIT_ELIMINATOR_ROLE`, each covering deficits only in its own asset and only for CDP Spokes on a DAO-set allowlist; funded to its `firstLossReserveMinimum` before any `drawCap` on that asset rises above 0, with `fundedBalance × 10⁴ ≥ coverageRatioBps × Σ drawCap` (`DEF-019`); the ratio and minimum are set in the funding ARFC;
- every later debt reserve: its DebtOracle as the Aave price source, a credit line from Lend Spoke supply or a source-Hub `drawCap`, and its own funded Umbrella;
- the Aave governance executor's `PROPOSER_ROLE`, `CANCELLER_ROLE` and `DAO_CANCELLER_ROLE` on the AvanaTimelock and its use of `cancelStandbySwitch`; the Aave Protocol Guardian's Avana guardian roles and one-way `freezeReserve` / `pauseReserve`;
- the containment order for a CDP Spoke (reserve freeze, `drawCap = 0`, Avana's pause; never `haltSpoke` or `pauseReserve` while debt exists unless the Spoke itself is faulty), and the request that the DAO pause Avana reserves only for exploits and unpause within the 48-hour incident window that caps are sized for.

### Listing payload (per market, `MKT-023`)

On the first market of a CDP Spoke, step 1 executes before the Avana batch, because `deployCdpSpoke` and `enableDebtReserve` read its result. Steps 2 to 5 execute after the `listCollateralMarket` batch has executed on the AvanaTimelock and the market's LPOracle holds a valid price (`MKT-018` to `MKT-022`). In order:

1. First market of a CDP Spoke only: deploy and register the standard CDP Spoke and its AaveOracle, list its debt reserves (GHO with Aave's fixed source), grant `FLASH_BORROWER`, register each Umbrella funded to its minimum, give the Aave Protocol Guardian one-way `freezeReserve` / `pauseReserve`, and set the Spoke's `LiquidationConfig`.
2. Raise `riskPremiumThreshold` if the new market's collateral risk requires it.
3. `HubConfigurator.addAssetWithDecimals` for the vault token with its decimals and a valid interest-rate strategy; set the fee receiver's `addCap` and `drawCap` to 0.
4. `HubConfigurator.addSpoke` for the CDP Spoke with the `addCap` from `SPEC-HUB-002` and `drawCap = 0`.
5. `SpokeConfigurator.addReserve` with the LPOracle feed, the required flags and the three required settings, collateral factor, `maxLiquidationBonus` and `collateralRisk`.

The payload carries the risk service providers' `marketUsdCap`, `tokenUsdCap`, `depositorUsdCap` and `poolRiskFactor` (at most 0.40). After it executes and the live-config check passes (`MKT-024`), the governance Safe schedules `MarketRegistry.activateMarket` at the short delay; activation reverts `ActivationCheckFailed` unless the Aave side matches (`MKT-026`).

### Later DAO payloads

| Payload | Rule |
|---|---|
| Collateral-factor cut | By AIP with no risk steward, after the Avana `poolRiskFactor` tightening (short delay) has executed so the drift check stops new borrowing while Aave's factor is above the new expected one (`MKT-052`); edits every existing dynamic key with `updateDynamicReserveConfig`, paired with an Aave freeze of the vault-token reserve when the market is offboarding; CF stays above 0 while any account holds the reserve |
| Collateral-factor raise | The Avana `poolRiskFactor` change (normal delay) executes first, then the AIP (`MKT-052`) |
| Collateral-risk increase | Raises `riskPremiumThreshold` to the new top risk + 1 bps first, then raises `collateralRisk`, then refreshes users |
| User refresh | The DAO's position-updater role calls `updateUserRiskPremium(proxy)` for every proxy listed from the indexer |
| Credit-line change | Per (Hub, debt asset): raises the Lend Spoke `addCap` (or the source-Hub `drawCap`) and the CDP Spoke `drawCap`s together, each draw cap within flash liquidity, route depth and the Umbrella coverage bound; recall lowers the `drawCap`s to 0 |
| Debt-reserve listing | The reserve on the standard CDP Spoke with its DebtOracle as price source, the asset's Umbrella funded to its minimum, then the credit line; paired with the Avana `enableDebtReserve` operation (`MKT-044`, `MKT-057`) |
| Offboarding | Avana `setMarketOffboarding` (short delay) plus an Aave freeze of the vault-token reserve and the wind-down ramp; no force-close |

Avana-authored payloads change vault-token reserves only through `SpokeConfigurator` single-field helpers, never `updateReserveConfig` with a full struct.

## AvanaTimelock operations

Every Avana change is an operation scheduled on the chain's AvanaTimelock by a proposer: the governance Safe, or the Aave governance executor through Aave governance (`REQ-ACCESS-160`). Its delay is set by its calldata: the short delay (12 hours) when every call is in the immutable `SHORT_ELIGIBLE` set and enabled on the short-delay list (`REQ-ACCESS-155`), otherwise the normal delay (5 days, never below `MIN_NORMAL_DELAY` of 4 days) (`SPEC-GOV-001`). Anyone can execute it once ready and until 14 days later, when it expires (`SPEC-GOV-002`). Any canceller (governance Safe, Emergency Guardian, Aave Protocol Guardian, Aave governance executor) can cancel during the delay, except that only the Aave governance executor can cancel a role-change operation or an operation whose every call restores reviewed configuration (`restoreRoute`, `useStandbyRoute`, `addKeeper`, `unfreezeAddress`; `REQ-ACCESS-156`). A batch that mixes such calls with any other call keeps the ordinary cancel rule.

The three deployment operations add everything new (`REQ-ARCH-209`), each at the normal delay:

- `deployCdpSpoke` registers a standard Spoke and its AaveOracle, created by the Aave DAO payload of the same listing, as the CDP Spoke of (Hub, AMM protocol, risk tier); it reverts unless the Spoke's code is the canonical Aave V4 Spoke and the three required settings hold.
- `listCollateralMarket` is one batch: the market's LPOracle, `VaultTokenFactory.deployVaultToken`, `listToken` for new tokens, `listCollateralMarket` (exact range, the integration's LPVault, the Spoke reserve), `setInitialMarketParams`, `setInitialMarketCaps`, `setInitialTokenCap` and the swap routes. `activateMarket` completes it at the short delay.
- `enableDebtReserve` records the reserve's funding Hub and asset and enables borrowing; it reverts unless the draw caps fit the credit line, each draw cap fits the asset's flash liquidity and route depth, the asset's Umbrella lists the Spoke and holds its minimum, and every market of the Spoke has a usable swap route and passes the liveness bound.

| Operation | Delay |
|---|---|
| Upgrade an upgradeable contract (AaveAdapter, RiskModule, MarketRegistry, ParameterStore, an LPOracle, a DebtOracle, LPVaultSwap). PositionProxies, the ProxyManager, LPVaults and the VaultTokenFactory are immutable | 5 days |
| `deployCdpSpoke`, `listCollateralMarket`, `enableDebtReserve`, `removeDebtReserve` (zero drawn only) | 5 days |
| New price source or standby route (`setPriceSource`); `restorePriceRoute` after a standby switch; new or changed swap route (`setRoute`); `setFlashSource`; cross-Hub lines; fee share or fee recipient | 5 days; the fee share also at once by the Joint Configuration Safe, within 0 – 5,000 bps |
| Loosen a risk parameter, within its loosening step and at most once per `normalDelay` per parameter (`REQ-ACCESS-161`); `addKeeper` (DAO-only cancel); `unfreezeAddress` (DAO-only cancel); `unfreeze`, `unpause` or a breaker reset by `APPLICATION_ADMIN`; `setNormalDelay`, short-delay list and public-execution changes | 5 days (the guardians can unfreeze, unpause and reset at once) |
| `activateMarket`, `cancelRegistration`, `setMarketOffboarding` | 12 hours |
| Tighten a parameter (`tighten*` on the ParameterStore, including the caps, `poolRiskFactor`, `breakerDeficitMax`, `gateRecoverySeconds`, `maxShortfallBps`, `debtStressRiseBps` and the optional `hardFloorHealthFactor`); `disableRoute`; `restoreRoute` to a previously approved route (DAO-only cancel); `removeKeeper` (not below `keeperFloor`, 1) | 12 hours; a ParameterStore tightening also at once by the Joint Configuration Safe |
| `freeze`, `pause(reason)`, `freezeAddress`, `tripMarketBreaker`, `tripDebtBreaker` by `APPLICATION_ADMIN`; `useStandbyRoute` by `APPLICATION_ADMIN` (DAO-only cancel) | 12 hours, so the governance Safe can stop new activity, one Hub per call, when both guardians are unavailable |
| `freezeAll`, `pauseAll(reason)` by `APPLICATION_ADMIN` | 5 days: the guardians pause and freeze every Hub at once, so the admin path waits public review |
| Role changes (`grantRole`, `revokeRole` on any Avana contract or the timelock) | 5 days, cancellable only by the Aave governance executor; a grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to any account but the timelock reverts (`REQ-ACCESS-153`) |
| Guardian `freeze`, `freezeAll`, `pause(reason)`, `pauseAll(reason)`, `unfreeze`, `unpause`, `freezeAddress`, breaker trips and resets, `useStandbyRoute`, `useStandbySecondSource`; `cancelStandbySwitch` by the Aave governance executor; `cancel` | Immediate, outside the timelock |
| Joint Configuration Safe: every ParameterStore `tighten*` setter and `setAvanaFeeShareBps` within 0 – 5,000 bps; the MarketRegistry guardian powers above (no `useStandbySecondSource`, no `cancel`) | Immediate, outside the timelock |

An operation that must apply on both chains is scheduled separately on each, with its own delay and cancellers.

Handover to the Aave DAO follows the agreed plan on each chain: the governance Safe schedules one role-change operation that grants `EXECUTOR_ROLE` to the Aave governance executor, which already holds `PROPOSER_ROLE`, grants `PROPOSER_ROLE` and `EXECUTOR_ROLE` to a second DAO-named holder, and revokes the Safe's `PROPOSER_ROLE` and `EXECUTOR_ROLE`, revoking last, so the proposer set never falls below two holders (`REQ-ACCESS-160`); the guardian, canceller and DAO canceller roles are unchanged, and `APPLICATION_ADMIN` and `DEFAULT_ADMIN_ROLE` stay with the timelock (`REQ-ACCESS-105`).

## Risk-parameter change process

Every Avana-side risk parameter changes through one process (`REQ-ACCESS-161`, `SPEC-GOV-011`):

1. **Publish.** The risk service providers publish the change with the cap-sizing calculation: the 48-hour incident term and the tail term for one pool token going to zero (`SPEC-CAP-007`), with the Lens tail coverage before and after.
2. **Build.** The governance Safe builds the operation, and every signer follows the signing procedure below.
3. **Schedule.** The operation is scheduled with `delay ≥ requiredDelay`. The short delay applies only when every call is a tightening in `SHORT_ELIGIBLE`; one loosening call makes the whole batch wait the normal delay.
4. **Review.** Monitoring alerts on `CallScheduled`, and any canceller may cancel during the delay.
5. **Execute.** Anyone executes it from its ready time until 14 days later. Each setter re-checks its bounds at execution, so a value that became unsafe while queued reverts.
6. **Confirm.** The live-configuration check and the Lens cap headroom confirm the result.

The ParameterStore bounds each loosening (`REQ-PSTORE-017`): any USD cap up by at most 50 %, `slippageAllowanceBps` up by at most 25 bps, the optional per-market `hardFloorHealthFactor` (off at launch, `Q-398`) down by at most 0.03, and at most one loosening of each parameter per `normalDelay` (`LoosenStepTooLarge`, `LoosenTooSoon`). Tightening is bounded only by the hard and liveness bounds, so it stays fast in an incident. For example, from a `marketUsdCap` of $2,000,000 one loosening reaches at most $3,000,000, and the next loosening of that cap executes no earlier than 5 days later, each with its own public review. `usdBandLow`, `usdBandHigh`, `graceDuration` and `graceHealthFactor` change only at the normal delay in both directions.

Aave-side values (collateral factor, bonus curve, target health factor, Hub and Spoke caps, credit lines and draw caps, Umbrella coverage ratio and minimum) change through Aave governance. For a collateral-factor cut, Avana first tightens `poolRiskFactor` at the short delay so the drift check stops new borrowing while Aave's factor is above the new expected one, and the Aave payload then lowers it; for a raise, the Avana change at the normal delay executes first (`MKT-052`).

## Multisig and key security

This standard applies, on each chain, to the governance Safe (4-of-7), the Emergency Guardian (3-of-5), the Joint Configuration Safe (2-of-3), the Avana treasury Safe and the keeper operators (`Q-245`).

### Hardware

- Every signer key of the governance Safe, the Emergency Guardian, the Joint Configuration Safe and the Avana treasury Safe is on a dedicated hardware wallet that displays EIP-712 typed data on the device.
- No hot keys, browser-extension keys or shared devices.
- Each keeper operator keeps its keys in its own HSM or KMS.

### Distribution

- Governance Safe: at most 3 of its 7 signers belong to Avana Labs; the signers span at least 3 independent organisations and at least 3 jurisdictions.
- Emergency Guardian: 5 different people across at least 3 time zones: three Avana Labs signers, one Aave Labs signer and one LlamaRisk signer.
- Joint Configuration Safe: one Avana Labs, one Aave Labs and one LlamaRisk signer.
- No person signs on two Safes of the same chain, no signer key is shared between Safes, and the Aave Protocol Guardian's signers are disjoint from every Avana Safe (`REQ-ROLE-007`, `REQ-ACCESS-104`).

### Signing procedure

For every transaction, each signer:

1. decodes the calldata from the raw transaction, never from the proposer's description;
2. recomputes the Safe transaction hash and compares it with the hash on the device;
3. runs a fork simulation of the `schedule` call and, at execution, of the resulting state change;
4. checks that the operation's `requiredDelay` matches the class intended for it and that the target is the intended chain's timelock.

Two signers also check every target address against the chain's deployment manifest.

### Quorum health and drills

- Every signer of each Safe sends a signed liveness message each month. Monitoring alerts when fewer than threshold + 1 signers answer within 72 hours.
- Each quarter the Safes of both chains run drills on a fork: guardian pause and unpause, address freeze, standby switch, breaker trip and reset, and a governance schedule-and-cancel drill.

### Rotation

- A departing signer, or one suspected of compromise, is replaced within 72 hours.
- Every key is rotated at least every 24 months.
- Owner changes are announced in advance.

### Safe guard and owner-change delay

- A Safe guard limits each governance Safe to calls to its chain's AvanaTimelock and to itself.
- A delay module makes every owner and threshold change of a governance Safe wait 48 hours, so four compromised keys cannot replace the other three at once.

### Backup proposer

The Aave governance executor holds `PROPOSER_ROLE` beside the governance Safe on each chain (`REQ-ACCESS-160`). If a Safe loses its quorum or renounces the role by mistake, repairs still reach the timelock through Aave governance, which every canceller watches. The live-configuration check requires at least two proposers and no role holder outside the 1.4 role table.

### Compromise response

The full steps are in [3.6 Emergency Operations](../spec/03-operations/06-emergency-operations.md), playbook P-07 (`EMG-081`):

- **One signer:** the remaining signers swap the owner through the Safe, after the 48-hour delay.
- **Governance quorum:** the guardians and the Aave governance executor cancel every unexpected operation; the guardians pause new activity if one nears its ready time; the executor schedules revocation of the compromised Safe's roles (a role change with DAO-only cancel).
- **Guardian quorum:** the Aave Protocol Guardian unpauses and resets breakers; governance revokes the compromised roles at the normal delay.
- **Keeper key:** `removeKeeper` at the short delay, or a guardian freezes the keeper address at once while the active keepers stay at or above `keeperFloor`; permissionless liquidation stays open throughout.

## Fork checks

- During each payload's delay, reviewers simulate it on a fork of its chain.
- After every DAO payload that touches an Avana Hub, a funding Hub's Avana draw or a CDP Spoke, a fork check asserts every required Aave-side value against chain state, including the reserve flags, the three required settings, every dynamic key, the target health factor and the fee receivers' caps (`REQ-HUB-007`).
- Before each upgrade proposal, the invariant suite reruns on a fork after executing the upgrade payload, and CI diffs the storage layout against the deployed version (`TEST-137`).
- A fork test proves every operation type can be cancelled by its cancel authority, and that a role-change or restoring operation cannot be cancelled by any account other than the Aave governance executor (`TEST-244`).
- Each chain's deployment is simulated end to end with `forge script` through the real Safe transaction format and the timelock, then the live-configuration check confirms `SHORT_ELIGIBLE`, the DAO-only cancel set, `MIN_NORMAL_DELAY`, at least two proposers, the ProxyManager's PositionProxy creation-code hash, the standby routes and the DebtOracle sources (`TEST-224`).
- The guardians' `freeze`, `freezeAll`, `pause(reason)`, `pauseAll(reason)`, `unfreeze`, `unpause`, `freezeAddress`, breaker trip and reset, `useStandbyRoute` and `cancel` payloads and the Aave Protocol Guardian's `freezeReserve` and `pauseReserve` payloads are rehearsed on a fork with the real Safes of each chain before launch and quarterly, with a playbook for each emergency type in 3.6 (`REQ-ROLE-077`).

## Licence

The payloads, operation files and documents in this folder are Avana's under the Business Source License 1.1 in the root [`LICENSE`](../LICENSE). A payload that imports Aave or other third-party code compiles that code under its own licence ([`LICENSING.md`](../LICENSING.md)).
