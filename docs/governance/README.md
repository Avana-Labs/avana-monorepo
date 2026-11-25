# governance

How Avana is governed on each chain: who holds which role on Avana's AccessManager, the delays, the Aave DAO payloads Avana's deployment and listings depend on, and how a listing or a parameter change is proposed and executed. The proposal is the [ARFC](arfc-avana-lp-collateral.md). The settings and their bounds are in [parameters.md](parameters.md). Each authority's powers are in [Authorities](#authorities).

The sources are the code: the role ids in [`contracts/src/AvanaRoles.sol`](../../contracts/src/AvanaRoles.sol), the delays and the map of every restricted function to its role in [`contracts/script/deploy/lib/AvanaAccess.sol`](../../contracts/script/deploy/lib/AvanaAccess.sol), the grants in the deploy scripts ([`contracts/script/deploy/`](../../contracts/script/deploy/), steps listed in `step.sh`), and the design records in [`contracts/design/`](../../contracts/design/).

## Layout

- Avana runs on Ethereum and Base, with one Avana Hub on each. Governance is per chain: each chain has its own OpenZeppelin `AccessManager` (deployed by `03_DeployAvana`), and no role on one chain can act on another.
- Each Hub, Lend Spoke and CDP Spoke is a standard, unmodified Aave V4 contract owned and configured by the Aave DAO. Avana holds no role on any of them.
- Avana's core contracts (LPVault, RiskModule, LiquidationModule, AaveAdapter, VaultToken, LPOracle, FlashloanRepay, FirstLossReserve) are immutable. There is no upgrade path and no Avana pause.
- Every restricted Avana function is `restricted` through the AccessManager, which maps it to one role (`AvanaAccess`). Contract-to-contract calls use core roles, one set per integration (`100 · integrationId + kind`), each held by one contract with no delay, so one integration's AaveAdapter cannot call another integration's LPVault.
- Each (Hub, debt asset) has two loss layers, both `FirstLossReserve` contracts governed by the **Aave** AccessManager: Avana's First-Loss Reserve, funded by Avana Labs, and behind it the DAO Deficit Offset, funded by the Aave DAO treasury ([reserve design record](../../contracts/design/reserve.md)).

## Roles and delays

| Role (id) | Holder (set by) | Execution delay | Functions |
|---|---|---|---|
| `ADMIN_ROLE` (0) | Aave governance executor (`03_DeployAvana`, which then renounces the deployer's admin) | 0 | Every AccessManager admin call: `grantRole`, `revokeRole`, `setTargetFunctionRole`, `setTargetClosed`, `labelRole`. As the default guardian of every role it can `cancel` any scheduled call |
| `AVANA_TIGHTEN_ROLE` (1) | Governance Safe; Joint Configuration Safe, the risk steward (`03_DeployAvana`) | 12 hours for the governance Safe; 0 for the Joint Configuration Safe | `RiskModule.removeDebtReserve`, `RiskModule.removeKeeper` |
| `AVANA_GOVERNANCE_ROLE` (2) | Governance Safe (`03_DeployAvana`) | The config's `timelockNormalDelay` when it lies between 4 and 5 days, else 4 days | `RiskModule.registerSpoke`, `setSpokeWidth`, `listPool`, `activateMarket`, `setDebtReserve`, `setCoverageRatio`, `setFee`, `addKeeper` |
| `AVANA_RESERVE_WITHDRAW_ROLE` (3) | Labelled on Avana's manager, granted to no one there: First-Loss Reserve `withdraw` is governed on the Aave AccessManager (below) | 14 days | — |
| Core roles `AVANA_I<n>_*_ROLE` | The integration's RiskModule (`LPVault.listMarket`), AaveAdapter (the LPVault's user flows, vault-token `mint` and `addValidProxy`), LiquidationModule (`LPVault.unwind`), AaveAdapter and LiquidationModule (vault-token `burn`) | 0 | Contract-to-contract calls only |

On the Aave AccessManager, the loss-layers AIP (`08_AaveLossLayersPayload`) maps each layer's functions and grants:

| Role (config `aavePayload.lossLayerRoles`) | Holder | Delay | Functions |
|---|---|---|---|
| Coverage role | `lossLayerRoles.coverageCaller`, by default the Aave governance executor | 0 | `coverDeficit` |
| Reserve-admin role | Aave governance executor | 0 | `setAllowedSpoke`, `setMinimum` |
| Withdraw role | Aave governance executor | 14 days (the reserve's `WITHDRAWAL_DELAY`) | `withdraw` |

The deployment AIP (`06_AaveDeploymentPayload`) also moves the SpokeConfigurator's one-way `freezeReserve` and `pauseReserve` to `AVANA_RESERVE_GUARDIAN_ROLE` (config `aavePayload.guardianRole`), held by the Aave Protocol Guardian and by every holder of the SpokeConfigurator Domain Admin role, so the DAO keeps both ([`AaveGuardianRole.sol`](../../contracts/script/deploy/lib/AaveGuardianRole.sol)).

**The Emergency Guardian holds no role.** Its address is recorded in the network config and the release manifest, but no deploy script grants it any role on Avana's AccessManager or on the Aave AccessManager.

## How a change runs on the AccessManager

The AccessManager schedules one call at a time ([`AccessOperations.sol`](../../contracts/script/deploy/lib/AccessOperations.sol), [`05_ExecuteOperations.s.sol`](../../contracts/script/deploy/05_ExecuteOperations.s.sol)):

1. **Write.** A script writes the operation to `contracts/deployments-local/<network>/operation-<name>.json`: each call decoded, its operation id, its required delay, and the exact `multicall` calldata that schedules and then executes it.
2. **Schedule.** The governance Safe sends one `multicall` of `schedule(target, data, 0)`, one per call. Each call is ready after its own role's execution delay; an operation is ready once its longest call is.
3. **Review.** Monitoring alerts on `OperationScheduled`. Until execution, the Aave governance executor (admin and guardian of every role) can `cancel` any call, and the Safe can cancel its own.
4. **Execute.** Once ready, the same Safe sends the matching `execute` calls in order: a call is bound to the account that scheduled it. A call not executed within one week after it is ready expires and has to be scheduled again. Each setter re-checks its bounds at execution.

The Joint Configuration Safe holds the tighten role with no delay, so it calls `removeDebtReserve` and `removeKeeper` directly, with no schedule. The DAO's own calls on the manager take effect when its AIP executes.

## Listing a pool

A listing is three Avana operations at the governance delay, one admin operation by the DAO and two Aave AIPs, in the order of `step.sh`. `09_ListMarkets` writes each Avana operation; on anvil (or with `AVANA_SCHEDULE_OPERATIONS=1`) it also schedules it as the Safe, and `05_ExecuteOperations` executes it once the delay has passed.

| Step (`step.sh`) | Who | What |
|---|---|---|
| `06-aave-deployment-aip` | Aave DAO | Debt assets on each Hub with their rate curves; the Lend Spoke and each CDP Spoke; debt reserves on the CDP Spokes, listed not borrowable; each CDP Spoke's liquidation config copied from its price Spoke; `FLASH_BORROWER` for the operator FlashLiquidators; the reserve-guardian role |
| `07-deploy-first-loss-reserves`, `08-aave-loss-layers-aip`, `07-fund-first-loss-reserves` | Avana Labs, then the Aave DAO, then Avana Labs | Both loss layers deployed; the AIP lists each on its Hub asset with no draw, grants `HUB_DEFICIT_ELIMINATOR_ROLE`, maps its roles, allows the Hub's CDP Spokes and sets its minimum; Avana Labs funds its layer to the minimum |
| `09-listing-setup`, then `09-execute-listing-setup` | Governance Safe, governance delay | `registerSpoke` (kind and price Spoke), `setDebtReserve` with its First-Loss Reserve, `setFee`, `setCoverageRatio`, `addKeeper` |
| `09-listing-markets`, then `09-execute-listing-markets` | Governance Safe, governance delay | `listPool` for each pool: Full range and Custom range markets at the listing tick of Aave's prices and the lower of the two tokens' collateral factors on the price Spoke (or the market's `eModeLtvBps` on a Correlated Spoke). Execution refuses if Aave's price has left the Custom band |
| `09-vault-tokens` | Deployer, then the Aave governance executor at once as admin | Each market's VaultToken and LPOracle deployed; the operation `vault-token-roles` maps each token's `mint` and `addValidProxy` to the adapter role and `burn` to the burn role |
| `10-aave-markets-aip` | Aave DAO | `AvanaMarkets`: each AaveAdapter a position manager on its CDP Spokes; the debt reserves made borrowable; each vault token listed on its Hub and CDP Spoke (`addCap` from the market's `marketUsdCap`, draw cap 0) with a collateral reserve priced by its LPOracle: collateral factor equal to the market's LTV, liquidation fee 0, not borrowable, receive-shares off |
| `09-listing-activate`, then `09-execute-listing-activate` | Governance Safe, governance delay | `activateMarket` for each market. It reverts `ActivationCheckFailed` with a named reason unless the Aave side matches the listing (`AaveConfigLogic.checkActivation`) |
| `11-fund-keepers` | Keeper top-up wallet | Refills each keeper signer below its minimum ([keeper gas](../keeper-gas.md)) |

A later listing on a registered Spoke reuses the same steps from `09-listing-markets`: `listPool`, the vault tokens, the markets AIP and `activateMarket`.

## Changing a parameter

Every Avana setting is a RiskModule setter ([parameters.md](parameters.md)):

1. **Propose.** Avana Labs or the Aave DAO's risk service providers publish the change and its reason in the forum, with the current and new values.
2. **Build.** A script writes `operation-<name>.json`: the calls, their role and delay, and the `schedule` calldata.
3. **Schedule.** The governance Safe schedules it. `setFee`, `setCoverageRatio`, `setSpokeWidth`, `setDebtReserve`, `registerSpoke` and `addKeeper` wait the governance delay (4 to 5 days); `removeDebtReserve` and `removeKeeper` wait 12 hours.
4. **Review and execute** as above.

A risk reduction that cannot wait 12 hours goes to the Joint Configuration Safe, which removes a debt reserve or a keeper at once. Aave-side values (collateral factors, caps, bonuses, rate curves, freezes, the loss layers' minimums and coverage caller) change only through Aave governance.

A band never changes once listed, and a listed market cannot be deactivated by Avana: a market is retired on Aave, with Aave's freeze and a collateral factor of 0 ([RiskModule design record](../../contracts/design/risk.md)).

## Emergency actions in code

| Action | Who | Effect |
|---|---|---|
| `removeKeeper` | Joint Configuration Safe at once; governance Safe after 12 hours | A compromised keeper is dropped. With no keeper registered, `checkBorrow` refuses every new borrow on that RiskModule (`NoActiveKeeper`); liquidation stays open to anyone |
| `removeDebtReserve` | Joint Configuration Safe at once; governance Safe after 12 hours | `checkBorrow` refuses new borrows of that reserve (`DebtReserveNotListed`); repayment and liquidation are unaffected |
| `cancel` | Aave governance executor (admin and guardian of every role); the scheduling Safe for its own calls | A scheduled call never executes |
| `revokeRole`, `setTargetClosed`, `setTargetFunctionRole` | Aave governance executor, through an AIP | Removes a holder, or closes a target. Closing an LPVault blocks its user flows and its `unwind`, so liquidation too: it is a last resort, not a pause |
| `freezeReserve`, `pauseReserve` on a Spoke reserve | Aave Protocol Guardian, and the Aave DAO | Aave's own controls. A freeze stops new supply and borrowing of that reserve; a pause also stops repayment, withdrawal and liquidation, so it is for exploits only |
| Draw-cap cut, Spoke pause, Hub halt | Aave DAO | Aave's own controls |
| `coverDeficit` | The coverage role holder (Aave AccessManager) | Burns a loss layer's Hub shares against a CDP Spoke's recorded deficit, Avana's layer first |

The Emergency Guardian has no on-chain power: none of these actions is granted to it.

## Deployment AIP (per chain)

`06_AaveDeploymentPayload` writes the Aave-side actions Avana's deployment depends on. On Ethereum and Base it writes the AIP actions for the AIP author; on test networks it executes them as the PayloadsController stand-in.

- `AvanaDeployment`: for every Hub and debt asset of `aavePayload.debtAssets`, the Hub asset with its kinked rate curve; the Lend Spoke on it (open to lenders, no draw) and each CDP Spoke of that Hub (its draw cap, no supply); the debt reserves on those Spokes, the CDP ones not borrowable until the markets AIP; each CDP Spoke's liquidation configuration (target health factor, health factor for the max bonus, bonus factor) copied from its price Spoke.
- `AvanaBootstrapSupply` (test networks): the DAO treasury's bootstrap supply of each Lend Spoke.
- `AvanaFlashBorrowers` (Aave V3): `FLASH_BORROWER` for Avana's operator FlashLiquidators.
- The Aave Protocol Guardian's `AVANA_RESERVE_GUARDIAN_ROLE` on the SpokeConfigurator's `freezeReserve` and `pauseReserve`.

The loss layers are registered by their own AIP (`08_AaveLossLayersPayload`) and the markets by `10_AaveListingPayload`, as in the listing table above.

## Multisig and key security

This is Avana Labs' operating policy for the governance Safe (4-of-7), the Joint Configuration Safe (2-of-3), the Avana treasury Safe and the keeper signers on each chain. The contracts do not enforce it.

### Signing procedure

For every transaction, each signer:

1. decodes the calldata from the raw transaction (the `operation-<name>.json` calldata), never from the proposer's description;
2. recomputes the Safe transaction hash and compares it with the hash on the device;
3. simulates the `schedule` call on a fork and, at execution, the resulting state change;
4. checks that each call's delay matches its role and that the target is the intended chain's contract.

Two signers also check every target address against the chain's release manifest.

### Keys and rotation

- Every Safe signer key is on a dedicated hardware wallet that displays EIP-712 typed data; no hot keys, browser-extension keys or shared devices. Keeper signers use encrypted keystores or a KMS.
- No person signs on two Safes of the same chain, and no signer key is shared between Safes.
- A departing signer, or one suspected of compromise, is replaced within 72 hours; every key is rotated at least every 24 months.

### Compromise response

- **One Safe signer:** the remaining signers swap the owner.
- **Governance Safe quorum:** the Aave governance executor cancels every unexpected scheduled call and revokes the Safe's roles by AIP.
- **Joint Configuration Safe:** it can only remove debt reserves and keepers; the governance Safe re-adds them at the governance delay, and the DAO revokes its role by AIP.
- **Keeper key:** `removeKeeper` by the Joint Configuration Safe at once; liquidation stays open to anyone throughout.

## Releases

Avana's core contracts are immutable, so a fix is a new deployment and a new listing, never an upgrade. Every deployment is made from a release tag (`vX.Y.Z`, [`docs/release.md`](../release.md)). Before a release is deployed, the long suite of [`contracts.yml`](../../.github/workflows/contracts.yml), the slow security tier and the mutation gates are run by hand on its commit ([audit evidence](../audit/README.md)).

## Authorities

Every authority that can act on Avana, what it can do, with what delay, and who can remove it. Governance is per chain: Ethereum and Base each have their own AccessManager and their own Safes, and no role on one chain can act on another. The grants are made by the deploy scripts (`03_DeployAvana`, `06_AaveDeploymentPayload`, `08_AaveLossLayersPayload`, `09_ListMarkets`); the role ids and delays are in `AvanaRoles.sol` and `contracts/script/deploy/lib/AvanaAccess.sol`.

### At a glance

| Authority | Composition (per chain) | Acts | Main powers |
|---|---|---|---|
| Aave DAO (governance executor) | Aave governance; on Base, its Base executor | Through Aave governance | Admin of Avana's AccessManager and guardian of every role; owns every Hub and Spoke; holds the loss layers' reserve-admin, withdraw (14 days) and, by default, coverage roles |
| Governance Safe | 4-of-7 Safe | Schedules; 12 hours or 4 to 5 days | Every Avana setting, listing and activation |
| Joint Configuration Safe (risk steward) | 2-of-3 Safe | At once | `removeDebtReserve`, `removeKeeper` |
| Aave Protocol Guardian | Aave's guardian multisig | At once | One-way `freezeReserve` and `pauseReserve` on the chain's SpokeConfigurator; no role on Avana's AccessManager |
| Emergency Guardian | 3-of-5 Safe | — | None: recorded in the config and the release manifest, granted no role |
| Keepers | Registered keeper signers; anyone can liquidate | At once | Liquidation, open to every address; the registry only gates borrowing (at least one keeper must be registered) |
| Avana treasury | The RiskModules' `feeRecipient` | Own funds only | Receives Avana's fee share; funds Avana's First-Loss Reserves and the keeper top-up wallet |
| Keeper top-up wallet | An account | Own funds only | Refills keeper signers (`11_FundKeepers`); holds no role |
| Risk service providers | The Aave DAO's risk service providers | Through proposals | Size listings, caps and coverage; no on-chain role |

### Aave DAO

**Holds:** `ADMIN_ROLE` of Avana's AccessManager on each chain, granted by `03_DeployAvana`, which then renounces the deployer's admin. Ownership and configuration of every Hub, Lend Spoke and CDP Spoke. On the Aave AccessManager, for every loss layer: the reserve-admin role (`setAllowedSpoke`, `setMinimum`) with no delay, the withdraw role with the reserve's 14-day `WITHDRAWAL_DELAY`, and the coverage role (`coverDeficit`) unless the loss-layers AIP names another `coverageCaller`.

**Can do:** grant and revoke every Avana role, map functions to roles, close a target (`setTargetClosed`), and, as the default guardian of every role, cancel any scheduled call. Sends the Aave payloads (deployment, loss layers, markets) and the `vault-token-roles` operation. Every Aave-side setting: caps, collateral factors, bonuses, rate curves, reserve freeze and pause, Spoke pause, Hub halt.

**Cannot do:** move a listed band, re-price an open credit or take a user's position: those are fixed in the immutable contracts.

### Governance Safe

**Holds:** `AVANA_GOVERNANCE_ROLE` at the governance delay (4 to 5 days) and `AVANA_TIGHTEN_ROLE` at 12 hours on Avana's AccessManager.

**Can do:** schedule and then execute `registerSpoke`, `setSpokeWidth`, `listPool`, `activateMarket`, `setDebtReserve`, `setCoverageRatio`, `setFee`, `addKeeper` (governance delay), and `removeDebtReserve`, `removeKeeper` (12 hours); cancel its own scheduled calls.

**Cannot do:** act without the delay, grant roles, close a target, touch a loss layer or any Aave setting. It is not the AccessManager's admin.

**Removed by:** the Aave DAO, with `revokeRole`.

### Joint Configuration Safe

**Holds:** `AVANA_TIGHTEN_ROLE` with no delay (granted when the config names a Safe other than the governance Safe).

**Can do:** `removeDebtReserve` and `removeKeeper` at once. Either stops new borrowing (of one reserve, or of every reserve of the RiskModule once no keeper is left) and leaves repayment, withdrawal and liquidation open.

**Cannot do:** anything else on Avana; it holds no Aave role.

**Removed by:** the Aave DAO, with `revokeRole`.

### Aave Protocol Guardian

**Holds:** `AVANA_RESERVE_GUARDIAN_ROLE` on the Aave AccessManager (`06_AaveDeploymentPayload`, `AaveGuardianRole.sol`): the SpokeConfigurator's `freezeReserve` and `pauseReserve`, which set their flag and never clear it. The grant is chain-wide, since one SpokeConfigurator serves every Spoke of the chain.

**Can do:** freeze a reserve (stops new supply and borrowing; the depeg response) or pause it (also stops repayment, withdrawal and liquidation; exploits only). Unfreezing and unpausing stay with the Aave DAO.

**Cannot do:** anything on Avana's AccessManager.

### Emergency Guardian

The network config and the release manifest name an Emergency Guardian Safe, but the deploy scripts grant it no role on Avana's AccessManager or on the Aave AccessManager. It has no on-chain power.

### Keepers

**Holds:** a place in each RiskModule's keeper registry (at most 16), added by `addKeeper` at the governance delay. An operator FlashLiquidator's `OPERATOR` is fixed at its deployment.

**Can do:** liquidate through `LiquidationModule.liquidate`, as any address can. The registry gates no call; while it is empty, `checkBorrow` refuses every new borrow.

**Removed by:** `removeKeeper`, by the Joint Configuration Safe at once or the governance Safe after 12 hours.

### Avana treasury

Receives Avana's share of each liquidation bonus as the RiskModules' `feeRecipient` (changed only by `setFee` at the governance delay), funds Avana's First-Loss Reserve of each (Hub, debt asset) to its minimum (`07-fund-first-loss-reserves`; `fund` is open to anyone) and the keeper top-up wallet. It holds no role and cannot withdraw from a First-Loss Reserve: only the withdraw role, held by the Aave DAO with a 14-day delay, can.

### Risk service providers

Size each listing's caps, the draw caps, the coverage ratio and the loss layers' minimums in the listing and funding ARFCs. They hold no on-chain role; their proposals go through the governance Safe or Aave governance.

### Contracts that act on each other

One set of core roles per integration, each held by one contract with no delay (`AvanaAccess.coreRole`):

| Role | Holder | Functions |
|---|---|---|
| `AVANA_I<n>_RISK_MODULE_ROLE` | RiskModule | `LPVault.listMarket` |
| `AVANA_I<n>_ADAPTER_ROLE` | AaveAdapter | the LPVault's `pledge`, `addLiquidity`, `removeLiquidity`, `release`, `collectFees`; each vault token's `mint` and `addValidProxy` |
| `AVANA_I<n>_LIQUIDATION_ROLE` | LiquidationModule | `LPVault.unwind` |
| `AVANA_I<n>_BURN_ROLE` | AaveAdapter and LiquidationModule | each vault token's `burn` |

The vault-token mappings are set by the `vault-token-roles` operation the DAO sends at listing (`09_ListMarkets`, `vault-tokens`). The loss layers hold `HUB_DEFICIT_ELIMINATOR_ROLE` on their Hub (`08_AaveLossLayersPayload`).

### Who can stop what

| To stop | Who | How fast |
|---|---|---|
| New borrowing of one debt reserve | Joint Configuration Safe (`removeDebtReserve`); governance Safe | At once; 12 hours |
| All new borrowing on one RiskModule | Joint Configuration Safe (remove every keeper) | At once |
| New supply and borrowing of one Spoke reserve | Aave Protocol Guardian, Aave DAO (`freezeReserve`) | At once; Aave governance |
| Borrowing of one asset by a CDP Spoke | Aave DAO (draw cap 0) | Aave governance |
| A scheduled Avana change | Aave DAO (`cancel`); the scheduling Safe | Aave governance; at once |
| Every restricted function of one Avana contract | Aave DAO (`setTargetClosed`); on an LPVault this also stops liquidation | Aave governance |

Repayment, debt-free withdrawal, fee collection and liquidation are never stopped by an Avana control; only Aave's pause and halt, or the DAO closing an LPVault, stop them.

## Licence

The payloads and documents in this folder are Avana's under the Business Source License 1.1 in the root [`LICENSE`](../../LICENSE). A payload that imports Aave or other third-party code compiles that code under its own licence ([`docs/licenses/LICENSING.md`](../licenses/LICENSING.md)).
