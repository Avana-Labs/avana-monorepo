# Roles and responsibilities

Last updated: 2026-11-11

This page lists every authority that can act on Avana, who sits on it, what it can do at once, what it can do only through the timelock, what it can never do, and who can remove it. Governance is per chain: Ethereum and Base each have their own AvanaTimelock and their own Safes, and nothing on one chain can act on the other (`REQ-ACCESS-173`). The role definitions are in [1.4 Permissions and Roles](../spec/01-architecture/04-permissions-and-roles.md) and [2.15 Governance and Timelock](../spec/02-contracts/15-governance-and-timelock.md); parameter values are in [parameters.md](parameters.md).

## At a glance

| Authority | Composition (per chain) | Acts | Main powers |
|---|---|---|---|
| Aave DAO (governance executor) | Aave governance; on Base, the Base executor over Aave's cross-chain governance | Through Aave governance | Owns the Hubs and Spokes, every Coverage Spoke's admin role; second proposer and only role-change canceller on the AvanaTimelock |
| AvanaTimelock | Contract, its own admin | After each operation's delay | Holds every admin role on every Avana contract |
| Governance Safe | 4-of-7, at most 3 Avana Labs signers, at least 3 organisations and 3 jurisdictions | Schedules; waits 12 hours or 5 days | Proposes every Avana change; cancels |
| Emergency Guardian | 3-of-5: Avana Labs signers plus one Aave Labs seat and one LlamaRisk seat | Immediate | Freeze, pause, unpause, breakers, address freeze, standby switches, coverage, cancel |
| Aave Protocol Guardian | Aave's guardian multisig | Immediate | The Emergency Guardian's Avana powers, plus Aave-side reserve freeze and pause |
| Joint Configuration Safe | 2-of-3: Avana Labs, Aave Labs, LlamaRisk | Immediate | Risk tightenings, Avana's fee share within bounds, the guardians' MarketRegistry powers |
| Keepers | Approved keeper addresses on LPVaultSwap, plus anyone through the permissionless path | Immediate | Liquidate accounts Aave marks liquidatable |
| Avana treasury Safe | Avana Labs Safe | Immediate, own funds only | Funds each Coverage Spoke; receives Avana's fee as `feeRecipient` |
| Risk service providers | LlamaRisk and the Aave DAO's other risk providers | Through proposals | Size listings, caps and coverage; no on-chain Avana role of their own |

No single person signs on two Safes of the same chain, no signer key is shared between the Emergency Guardian, the governance Safe, the Joint Configuration Safe and the Aave Protocol Guardian (`REQ-ROLE-007`), and the Aave Protocol Guardian's signers are disjoint from every Avana Safe (`REQ-ACCESS-104`). An organisation may hold seats on several Safes, each through a different person and key.

## Aave DAO

**Holds:** ownership and configuration of each chain's Avana Stable LP Hub and its CDP, Lend and Coverage Spokes. On the AvanaTimelock, its executor holds `PROPOSER_ROLE`, `CANCELLER_ROLE` and `DAO_CANCELLER_ROLE`. On each Coverage Spoke, the DAO executor holds `RESERVE_ADMIN_ROLE` and is the admin of `COVERAGE_ROLE`.

**Does:**
- Deploys and upgrades each standard CDP Spoke and its AaveOracle; sets collateral factors, caps, reserve flags, the bonus curve, target health factor, collateral risk, debt-asset rates, credit lines and draw caps.
- Sets the three required settings on every Avana collateral reserve: `receiveSharesEnabled = false`, `liquidationFee = 0`, no reinvestment controller (`REQ-HUB-092`).
- Grants the `FLASH_BORROWER` role on the Aave V3 Pool.
- On each Coverage Spoke: sets the allowlisted CDP Spokes and `firstLossReserveMinimum`, requests, cancels and executes reserve withdrawals (14-day delay, and never while a covered Spoke has an open deficit), and grants `COVERAGE_ROLE`.
- On the AvanaTimelock: schedules Avana operations (same delays as everyone), cancels any queued operation, and is the only account that can cancel a role-change or restoring operation (`REQ-ACCESS-156`). On the MarketRegistry it undoes a guardian's standby switch at once (`cancelStandbySwitch`).

**Cannot:** mint vault tokens, move positions, or execute an Avana operation before its delay.

## AvanaTimelock

**Holds:** `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` on every upgradeable Avana contract, which no grant can give to any other account (`REQ-ACCESS-153`); the `TIMELOCK` address of every immutable Avana contract.

**Does:** runs each ready operation. Anyone can execute it while public execution is on, for 14 days after it becomes ready. Delays:
- **Short, 12 hours:** operations whose every call only reduces risk or stops new activity (the short-delay list).
- **Normal, 5 days (never below 4):** upgrades, listings, every loosening, routes, price sources, keepers and every role change.

**Cannot:** act on another chain, or let any account bypass a delay.

## Governance Safe

**Composition:** 4-of-7 per chain, at most 3 Avana Labs signers, signers from at least 3 independent organisations and 3 jurisdictions. A Safe guard limits it to calls to its chain's AvanaTimelock and to itself; owner and threshold changes wait 48 hours.

**Holds:** `PROPOSER_ROLE`, `CANCELLER_ROLE` and `EXECUTOR_ROLE` on the AvanaTimelock. No role on any other Avana contract.

**Does:** schedules every Avana change (upgrades, the deployment operations, market listing and activation, price sources, routes, parameters, keepers, role changes) and cancels queued operations outside the DAO-only sets.

**Cannot:** act immediately on any Avana contract, execute before a delay, grant an admin role to anyone but the timelock, or cancel a role-change or restoring operation.

**Removed by:** a role-change operation, which only the Aave governance executor can cancel.

## Emergency Guardian

**Composition:** 3-of-5 per chain, five different people across at least 3 time zones. Two seats are held by Aave Labs and LlamaRisk, one each; the other three by Avana Labs. No seat can act alone, and no two seats of one organisation reach the threshold without a signer from another.

**Holds:**
- `APPLICATION_PAUSE_GUARDIAN` and `APPLICATION_FREEZE_GUARDIAN` on the MarketRegistry.
- `APPLICATION_PAUSE_GUARDIAN` on the ParameterStore, for `useStandbySecondSource` only.
- `CANCELLER_ROLE` on the AvanaTimelock.
- `COVERAGE_ROLE` on each Coverage Spoke, granted by the Aave DAO.

**Does, immediately:**
- `freeze(hub)`, `freezeAll`, `pause(hub, reason)`, `pauseAll(reason)`, `unfreeze`, `unpause`.
- `freezeAddress`: at most 20 in the 24 one-hour buckets ending with the current hour, never an address of the protected set; no keeper floor applies, so the last active keeper can be frozen and new borrowing then halts (`REQ-ACCESS-157`, `REQ-MREG-021`).
- Trip and reset market and debt breakers (`REQ-ACCESS-158`).
- Switch a token to its standby price route or standby second source, both recorded at listing (`REQ-ACCESS-159`, `REQ-ACCESS-179`).
- `coverDeficit`: spend a Coverage Spoke's reserve on recorded deficits of allowlisted CDP Spokes, in that Coverage Spoke's own asset, never above the deficit or the funded balance, within the 72-hour coverage window (`REQ-FLR-021`).
- Cancel queued operations that are neither role-change nor restoring.

**Cannot:** upgrade, change a parameter, choose a price source not recorded at listing, unfreeze an address, schedule an operation, cancel a role-change or restoring operation, move collateral, or stop liquidation, pending settlement, repay, fee collection or debt-free withdrawal (`REQ-ROLE-076`).

**Removed by:** a role-change operation on the timelock (DAO-only cancel); `COVERAGE_ROLE` also by the Aave DAO directly.

## Aave Protocol Guardian

**Composition:** Aave's guardian multisig; its signers are disjoint from every Avana Safe.

**Holds:** the same Avana roles as the Emergency Guardian (`APPLICATION_PAUSE_GUARDIAN`, `APPLICATION_FREEZE_GUARDIAN`, `CANCELLER_ROLE`, `COVERAGE_ROLE`). On the Aave side, one-way `freezeReserve` and `pauseReserve`.

**Does:** everything the Emergency Guardian does, independently of Avana's Safes, so Avana's markets can be stopped and deficits covered without Avana Labs' cooperation. Aave-side reserve pauses follow the AIP commitment: exploits only, unpaused within the 48-hour incident window.

**Cannot:** everything the Emergency Guardian cannot; unpause an Aave reserve (the Aave DAO does).

## Joint Configuration Safe

**Composition:** 2-of-3 per chain: one Avana Labs signer, one Aave Labs signer, one LlamaRisk signer. Any two act; none acts alone.

**Holds:** `APPLICATION_RISK_STEWARD` on the ParameterStore (`REQ-ROLE-117`); `APPLICATION_PAUSE_GUARDIAN` and `APPLICATION_FREEZE_GUARDIAN` on the MarketRegistry.

**Does, immediately:**
- Calls the 20 ParameterStore tighten setters. Each one only moves a limit in the safe direction (for example a lower cap, a shorter price age, a higher hard floor), and each keeps its own bounds.
- Sets Avana's fee share of a liquidation's oracle gain (`avanaFeeShareBps`) within its on-chain bound of 0–5,000 bps (`SPEC-LIQ-009`).
- Everything the two MarketRegistry guardian roles allow, with the same limits as the guardians: freeze, pause, unfreeze, unpause, address freezes, breaker trips and resets, and the standby route switch.

**Cannot:** loosen any limit, upgrade, change routes, price sources or keepers, change roles, cover a deficit, cancel a queued operation, or execute anything else without the timelock. Loosening the same parameters still waits the normal delay and its loosening step (`REQ-PSTORE-016`).

**Removed by:** a role-change operation on the timelock (DAO-only cancel).

## Committed operators (keepers)

**Who:** addresses on LPVaultSwap's committed-operator registry (the keeper list) that are not frozen: Avana's keeper at launch, others added through the timelock at the normal delay. There is no keeper role, and the registry gates no call: any address that is not frozen liquidates through `liquidate`, with either route mode, directly or through the public flash liquidation helper (`Q-404`).

**Does:** commits to liquidate every account below health factor 1, whatever its size, at Aave's sizing, funding each call in the debt asset and bearing any rounding loss below the debt it repaid. The registry feeds `keeperFloor` and the borrowing halt at zero active committed operators.

**Cannot:** liquidate a healthy account, choose records, take more than the recovery floor allows, redirect payouts, or act on stale prices; registration grants no power any other caller lacks.

**Removed by:** `removeKeeper` at the short delay while active committed operators stay at or above `keeperFloor`, or `freezeAddress` by a guardian at once (which stops its direct calls; a frozen address can still liquidate through the public helper).

## Avana treasury Safe

**Composition:** an Avana Labs Safe, under the key standard of [README](README.md#multisig-and-key-security).

**Does:** funds each Coverage Spoke's first-loss reserve (`fund`, which gives the funder no claim on it); receives Avana's fee share as `feeRecipient`.

**Cannot:** withdraw from a Coverage Spoke (only the Aave DAO can, after 14 days), or act on any Avana contract.

## Risk service providers

**Who:** LlamaRisk and the Aave DAO's other risk service providers.

**Does:** sizes each listing package (pool risk factors, USD caps, `minPledgeUsd`, per-pool `poolShareMaxBps`) with its cap-sizing calculation, the deficit-breaker materiality of each non-GHO debt reserve, and, with the Aave DAO, the credit lines, draw caps and each Coverage Spoke's coverage ratio and minimum. Changes reach Avana through the governance Safe and the timelock. LlamaRisk also holds one seat on the Emergency Guardian and one on the Joint Configuration Safe.

## Contracts that act on each other

These are fixed in bytecode, not held by people:

| Caller | Called | What |
|---|---|---|
| AaveAdapter | Vault tokens, ProxyManager, PositionProxies, Collateralization | Mint, burn and register proxies; create proxies; drive each proxy's Aave account |
| LPVaultSwap | Collateralization, LPVaults, PayoutEscrow, Coverage Spokes | Seize and settle; deposit failed payouts; fund pending settlement |
| MarketRegistry | Each AMM integration | `bindMarket` at listing |
| AvanaTimelock | LPVaults, VaultTokenFactory | `returnStray`, `registerIntegration`, `deployVaultToken` |

No Avana contract and no deployer holds a role on a Coverage Spoke.

## Who can stop what

| Action | Emergency Guardian | Aave Protocol Guardian | Joint Configuration Safe | Governance Safe | Aave DAO |
|---|---|---|---|---|---|
| Freeze or pause a Hub | Immediate | Immediate | Immediate | 12-hour operation | Through its executor |
| Unfreeze or unpause | Immediate | Immediate | Immediate | 5-day operation | Through its executor |
| Freeze an address | Immediate | Immediate | Immediate | 12-hour operation | Through its executor |
| Unfreeze an address | — | — | — | 5-day operation | Through its executor |
| Trip a breaker | Immediate | Immediate | Immediate | 12-hour operation | Through its executor |
| Reset a breaker | Immediate | Immediate | Immediate | 5-day operation | Through its executor |
| Switch to a standby route | Immediate | Immediate | Immediate | 12-hour operation | Undoes a switch at once |
| Tighten a risk parameter | — | — | Immediate | 12-hour operation | Through its executor |
| Loosen a risk parameter | — | — | — | 5-day operation | Through its executor |
| Change Avana's fee share | — | — | Immediate, within 0–5,000 bps | 5-day operation | Through its executor |
| Cover a recorded deficit | Immediate | Immediate | — | — | Grants `COVERAGE_ROLE` |
| Cancel a queued operation | Immediate | Immediate | — | Immediate | Immediate, including role changes |
| Upgrade a contract | — | — | — | 5-day operation | Through its executor |
| Aave reserve freeze or pause | — | Immediate | — | — | Aave governance |

Liquidation (both entry points), pending settlement, repay, fee collection, debt-free withdrawal and zero-credit release never read the pause state, a breaker or an address freeze, so no one in this table can block an exit.
