# 2.2 LP Vault

> **Status:** In review · **Owner:** Avana Labs · **Last reviewed:** 2026-11-10
>
> **Requirement prefix:** `REQ-VAULT-NNN`

## Purpose

An LPVault is the immutable custodian of every pledged position of one AMM protocol on one chain (`Q-224`, `Q-240`, `Q-291`): the Uniswap v3 LPVault on Ethereum ([2.20](20-uniswap-v3-integration.md)) and the Slipstream LPVault on Base ([2.21](21-aerodrome-slipstream-integration.md)) at launch, and one more LPVault for each AMM protocol listed later ([2.22](22-amm-integration-readiness.md)). Every LPVault implements the AMM integration interface ([2.19](19-amm-integration-interface.md)). It is responsible for:

- validating and storing, write-once, the pool and exact shape of each market of its AMM protocol at listing;
- taking custody of a position from its owner when Collateralization records a pledge, checking its shape is exactly the market's, and remembering that owner as the depositor of record;
- returning the position, whole, only to its depositor of record when Collateralization closes the record;
- removing exactly the units Collateralization debits and sending only their principal to the recipient Collateralization names (LPVaultSwap or Collateralization), or to the depositor of record for a partial removal;
- reporting a custodied position's live units;
- fee collection for the depositor of record, where the AMM protocol keeps fees apart from principal;
- returning a stray position through a timelock operation.

It is not responsible for: the backing ledger, credited units, seizure order, reconciliation, the pending-settlement balance or the exposure counters (Collateralization, [2.3](03-collateralization.md)); minting or burning vault tokens (AaveAdapter, [2.6](06-aave-adapter.md)); serving prices (LPOracle, [2.10](10-lp-oracle.md)), which compiles in the same pricing library as the LPVault's `composition` view; eligibility, caps and pauses (RiskModule, [2.7](07-risk-module.md); MarketRegistry, [2.8](08-market-registry.md)); liquidation sizing, funding, conversion and payouts (Aave Spoke and LPVaultSwap, [2.11](11-lpvaultswap.md)). It holds no vault token, no Hub or Spoke binding and no pool token.

## Inputs

| Input | From | Path |
|---|---|---|
| Market binding (`marketId`, pool, pool ID, shape, integration data) | MarketRegistry during the `listCollateralMarket` batch | `bindMarket` |
| Custody instruction (`marketId`, owner, `positionKey`) | Collateralization during a pledge, Lock held by the AaveAdapter | `receivePosition` |
| Top-up instruction (fungible LP shares only) | Collateralization during a re-credit, Lock held by the AaveAdapter | `topUpPosition` |
| Return instruction (`positionKey`) | Collateralization when it closes a record, Lock held | `returnPosition` |
| Removal instruction (`positionKey`, units, minimums, recipient) | Collateralization during seizure settlement, reconciliation or a deleverage release, Lock held | `unwind` |
| Partial-release instruction (`positionKey`, units, the depositor's minimums) | Collateralization during a partial removal, Lock held | `releaseToDepositor` |
| Live-units read (`positionKey`) | Collateralization during a re-credit, Lock held | `unitsOf` |
| Fee-collection instruction (`positionKey`, depositor) | Collateralization, inside the AaveAdapter's `collectFees` for the depositor of record | `collectFees` |
| Stray-position return | Governance multisig through an AvanaTimelock operation at the normal delay | `returnStray` |

## Outputs

| Output | To |
|---|---|
| The whole position | Its depositor of record on release; the recipient of a scheduled stray return |
| Principal of removed units (`n` token amounts) | The recipient Collateralization names: LPVaultSwap for a seizure and a deleverage release, Collateralization for a reconciliation |
| Principal of a partial removal | The depositor of record |
| Fees and any amounts owed to the position at pledge | The depositor of record |
| `depositorOf`, `marketOfPosition` custody maps; the market table (`marketOf(marketId)`) | Collateralization's consistency rule, the Lens and indexers |
| Events listed under [Events](#events) | Indexer, keepers, monitoring |

## Storage

| Variable | Type | Description | Written by |
|---|---|---|---|
| `INTEGRATION_ID` | immutable `uint32` | The integration identifier registered for this LPVault in the VaultTokenFactory; `AMM_PROTOCOL()` returns the protocol tag, for example `keccak256("UNISWAP_V3")` | Constructor |
| `COLLATERALIZATION` | immutable `address` | Collateralization ([2.3](03-collateralization.md)), the only caller of the custody, unwind and fee functions | Constructor |
| `MARKET_REGISTRY` | immutable `address` | MarketRegistry ([2.8](08-market-registry.md)), the only caller of `bindMarket` | Constructor |
| `LOCK` | immutable `address` | Protocol Lock ([2.16](16-lock.md)), whose members are the AaveAdapter and LPVaultSwap | Constructor |
| `TIMELOCK` | immutable `address` | The chain's AvanaTimelock ([2.15](15-governance-and-timelock.md)), the only caller of `returnStray` | Constructor |
| AMM protocol bindings | immutable `address` | The position manager(s) and factory the integration page names | Constructor |
| `markets` | `mapping(uint256 marketId => …)` | Write-once market table: pool, pool ID, shape, tokens, decimals and pool settings, in the integration's layout | `bindMarket` |
| `depositorOf` | `mapping(bytes32 positionKey => address)` | Depositor of record of a position in custody for an open record; `address(0)` = not in custody for a record | `receivePosition`, `returnPosition` |
| `marketOfPosition` | `mapping(bytes32 positionKey => uint256)` | The `marketId` a custodied position was accepted for; 0 when not in custody | `receivePosition`, `returnPosition` |

The LPVault keeps no record, total, counter, pending balance, timer or queue.

## Functions

| Function | Description | Caller (role / contract) | Requirements |
|---|---|---|---|
| `bindMarket(uint256 marketId, address pool, bytes32 poolId, PositionShape shape, bytes integrationData) returns (address[] tokens, uint8 unitDecimals)` | Validates and stores a market write-once | MarketRegistry | `REQ-VAULT-166` |
| `receivePosition(uint256 marketId, address owner, bytes32 positionKey) returns (uint128 units)` | Pulls the position from its owner, checks its shape, records the owner as depositor and returns its units | Collateralization, Lock held | `REQ-VAULT-167`, `REQ-VAULT-003` |
| `topUpPosition(bytes32 positionKey, address owner, bytes topUp) returns (uint128 unitsAdded)` | Adds LP shares to a custodied fungible position; reverts for NFT integrations | Collateralization, Lock held | [2.19](19-amm-integration-interface.md) `REQ-AMM-CORE-011` |
| `returnPosition(bytes32 positionKey) returns (address depositor)` | Sends the whole position to its depositor of record and clears the entry | Collateralization, Lock held | `REQ-VAULT-168`, `REQ-VAULT-094` |
| `unwind(bytes32 positionKey, uint128 units, uint256[] minAmounts, address recipient) returns (uint256[] amounts)` | Removes `units` and sends exactly the removed principal to `recipient` | Collateralization, Lock held | `REQ-VAULT-169`, `REQ-VAULT-095` |
| `releaseToDepositor(bytes32 positionKey, uint128 units, uint256[] minAmounts) returns (uint256[] amounts)` | Removes `units` with the depositor's minimums and sends exactly the removed principal to the depositor of record | Collateralization, Lock held | `REQ-VAULT-170` |
| `unitsOf(bytes32 positionKey) returns (uint128)` | Live units of a custodied position | Collateralization under the Lock; anyone while the Lock is free | `REQ-VAULT-171` |
| `collectFees(bytes32 positionKey, address depositor) returns (uint256[] amounts)` | Collects all fees and owed amounts of a custodied position to its depositor | Collateralization, Lock held by the AaveAdapter | `REQ-VAULT-064`…`REQ-VAULT-067`, `REQ-VAULT-172` |
| `returnStray(bytes32 positionKey, address recipient)` | Sends a stray position to the address governance established as its owner | AvanaTimelock (normal delay), Lock free | `REQ-VAULT-165`, `REQ-VAULT-081`…`REQ-VAULT-084` |
| `validatePosition`, `composition`, `riskMetadata`, `riskStatus`, `marketOf(uint256)`, `capabilities`, `AMM_PROTOCOL`, and the hooks `checkReadSafe`, `consistencyDeviation`, `rateProviders`, `wrappedNative`, `isAllowedPoolHook`, `effectiveSupply` | Interface views ([2.19](19-amm-integration-interface.md)) | Anyone | `REQ-AMM-CORE-005`, `REQ-AMM-CORE-012`, `REQ-AMM-CORE-013` |
| `depositorOf(bytes32)`, `marketOfPosition(bytes32)`, `isInCustody(bytes32)` | Custody views | Anyone while the Lock is free; Collateralization while it is held | `REQ-VAULT-151` |
| `INTEGRATION_ID()`, `COLLATERALIZATION()`, `MARKET_REGISTRY()`, `LOCK()`, `TIMELOCK()` and the AMM protocol bindings (`NFPM()`, `FACTORY()` on Uniswap v3; `generation(index)` on Slipstream) | Constructor immutables | Anyone | `REQ-VAULT-155` |

## Requirements

### General

- `REQ-VAULT-001` — Every LPVault MUST be deployed as a non-upgradeable contract: no proxy, no `delegatecall`, no `selfdestruct`, no owner, no admin role, and no function that changes its code, its immutables, a stored market or its custody rules. Why: it holds every pledged position of its AMM protocol on the chain, and the rule that a position returns only to its depositor of record must hold under any upgrade of the contracts around it (the Adapter, LPVaultSwap, the RiskModule). (Source: Q-226, Q-240, Q-291)
- `REQ-VAULT-002` — An LPVault MUST take every address it calls from its constructor immutables and MUST hold no Hub, Spoke, vault-token, registry or price binding; it reads no MarketRegistry, ParameterStore or other upgradeable contract. The only contract whose instructions move a custodied position or its units is the immutable Collateralization, and a market is added only by `bindMarket` from the MarketRegistry, once per `marketId` and never changed afterwards, so no configuration change or upgrade can redirect custody or change a bound market's shape. (Source: Q-226, Q-240, Q-291, Q-293)
- `REQ-VAULT-003` — An LPVault MUST take custody of a position for a record only through `receivePosition`, called by Collateralization during a pledge after Collateralization has validated the vault token, the proxy and the record limits ([2.3](03-collateralization.md)); the LPVault itself checks ownership, custody, the pool lock and the exact shape. A position that reaches it any other way is a stray position and is never recorded. (Source: Q-104, Q-224, Q-293)
- `REQ-VAULT-004` — An LPVault MUST make every state-changing call on its AMM protocol's position contracts, pools and AMM vaults for pledged positions, and MUST be the only Avana contract that does; Collateralization, the Adapter and LPVaultSwap call no AMM protocol contract for custody or removal. It never grants an approval or operator on a position contract, so no other contract can move a custodied position, its units or its fees; swap routes receive tokens only after the LPVault has removed them for LPVaultSwap. (Source: Q-030, Q-061, Q-224, Q-291)
- `REQ-VAULT-005` — An LPVault MUST NOT have a pause of its own and MUST NOT read any Avana pause state, breaker, address freeze, price state or policy: no function of it reads any. The pause, breaker and freeze gates (`Q-227`, `Q-241`, `Q-242`, `Q-252`) are applied only by the Adapter and the RiskModule, to pledges, re-credits, withdrawals and partial removals with debt and repay with collateral, before they reach Collateralization; LPVaultSwap reads no pause state, breaker or freeze, so seizures reach the LPVault in every state, and fee collection, debt-free withdrawal and partial removal, and zero-credit release are open in every state, for a frozen address too. (Source: Q-051, Q-223, Q-227, Q-241, Q-242)
- `REQ-VAULT-174` — Each chain MUST have at most one LPVault per AMM protocol, registered write-once in the VaultTokenFactory under its `INTEGRATION_ID` ([2.19](19-amm-integration-interface.md) `REQ-AMM-CORE-002`). A later AMM protocol, or a later generation of an AMM protocol's position contracts that the existing LPVault's immutables do not name, gets a new LPVault with a new `integrationId`; existing LPVaults, Collateralization and the Lock are not redeployed. (Source: Q-291, Q-301)

### Custody functions

- `REQ-VAULT-166` — `bindMarket(marketId, pool, poolId, shape, integrationData)` MUST behave per [2.19](19-amm-integration-interface.md) `REQ-AMM-CORE-003` and `REQ-AMM-CORE-004`: only the MarketRegistry may call it, once per `marketId` (`MarketBinding`), every listing guard of the integration page runs, and a stored market never changes. (Source: Q-291, Q-293, Q-305)
- `REQ-VAULT-167` — `receivePosition(marketId, owner, positionKey)` MUST behave per `REQ-AMM-CORE-005` and `REQ-AMM-CORE-006`: it reverts with `NotCollateralization` unless `msg.sender == COLLATERALIZATION`, with `LockNotHeld` unless the Lock is held by the AaveAdapter or LPVaultSwap, with `NotTokenOwner` unless `owner` owns the position and is not the LPVault, with `PoolLocked` while the pool is mid-operation, and with `PoolMismatch` or `RangeMismatch(tickLower, tickUpper)` unless the position's pool and shape equal the market's exactly; it pulls the position without running a receiver hook on the LPVault, writes `depositorOf` and `marketOfPosition`, reads the units after custody and emits `PositionReceived(positionKey, marketId, owner, units)`. The Uniswap v3 and Slipstream implementations are `REQ-VAULT-147` and [2.21](21-aerodrome-slipstream-integration.md). Why the owner check here: the depositor of record is always the wallet the position came from, whatever wallet the upgradeable Adapter names, and a stray position the LPVault holds can never become a record. (Source: Q-067, Q-073, Q-224, Q-258, Q-293)
- `REQ-VAULT-168` — `returnPosition(positionKey)` MUST behave per `REQ-AMM-CORE-007`: it deletes the custody entry before the position leaves, sends the whole position with every live unit and every fee owed to it to the depositor of record only, emits `PositionReturned(positionKey, depositor)` and takes no recipient. (Source: Q-009, Q-067, Q-105, Q-224)
- `REQ-VAULT-169` — `unwind(positionKey, units, minAmounts, recipient)` MUST behave per `REQ-AMM-CORE-008`: it reverts with `InvalidRecipient` for `address(0)` or the LPVault, removes exactly `units`, sends only their principal to `recipient` (never a fee owed to the position), skips the payout when every amount is 0, emits `UnitsUnwound(positionKey, units, recipient, amounts)` and returns the `n` amounts the AMM protocol reports. Collateralization calls it only with `units` equal to a debit of the record (`REQ-VAULT-095`) and zero minimums, and only for LPVaultSwap or itself as recipient. (Source: Q-061, Q-085, Q-131, Q-216, Q-217, Q-224, Q-271)
- `REQ-VAULT-170` — `releaseToDepositor(positionKey, units, minAmounts)` MUST behave per `REQ-AMM-CORE-008`, sending the principal only to `depositorOf(positionKey)` and enforcing the depositor's minimums (`BelowMinimum(i, received, minimum)`); it takes no recipient and emits `UnitsReleased(positionKey, units, depositor, amounts)`. Collateralization calls it only with the units it has just debited in `releasePartial`, below the record's credited units, so the position stays in custody. (Source: Q-061, Q-105, Q-217, Q-224, Q-254)
- `REQ-VAULT-171` — `unitsOf(positionKey)` MUST revert with `NotInCustody` without a custody entry and otherwise return the position's live units in its AMM protocol. Collateralization reads it in `recredit` to credit exactly the live units above `credited`. (Source: Q-224, Q-254)
- `REQ-VAULT-150` — An LPVault MUST NOT acquire the Lock: it is not a Lock member, and the Lock's members are only the AaveAdapter and LPVaultSwap ([2.16](16-lock.md)). Every function that moves a position, units, principal or fees (`receivePosition`, `topUpPosition`, `returnPosition`, `unwind`, `releaseToDepositor`, `collectFees`) MUST require `msg.sender == COLLATERALIZATION` and `LOCK.holder()` equal to the AaveAdapter or LPVaultSwap, and `collectFees` `LOCK.holder() == LOCK.AAVE_ADAPTER()` (`REQ-VAULT-064`) (`LockNotHeld`); Collateralization in turn requires the Lock held by the one member that may drive that path (the Adapter for pledge, release, partial removal, re-credit, repay with collateral, zero-credit release and fee collection; LPVaultSwap for seizure and pending settlement). `returnStray` acquires nothing and requires the Lock free. The LPVault calls no Avana contract other than `LOCK`. Why: an immutable Lock with exactly two members serves every LPVault deployed later, so adding an AMM protocol never needs a Lock redeploy (`AMMN-ARCH-01`). (Source: Q-148, Q-223, Q-224, Q-296)
- `REQ-VAULT-151` — `depositorOf`, `marketOfPosition`, `isInCustody` and `unitsOf` MUST revert with `Locked` while the Lock is held unless `msg.sender == COLLATERALIZATION`, so no other contract reads custody state in the middle of an Avana operation; `composition`, `riskMetadata`, `riskStatus`, `marketOf(marketId)`, `capabilities` and the immutable getters never revert on the Lock. (Source: Q-119, Q-148, Q-254)
- `REQ-VAULT-152` — At the end of every transaction, `depositorOf(positionKey) != address(0)` if and only if the LPVault holds that position for an open Collateralization record keyed by (`INTEGRATION_ID`, `positionKey`) whose depositor is that address ([2.3](03-collateralization.md) `REQ-COLL-006`); every other position of its AMM protocol the LPVault holds is a stray position. (Source: Q-104, Q-224, Q-292)
- `REQ-VAULT-153` — Upstream errors from the AMM protocol's contracts, the pool tokens and the Lock MUST pass through unchanged; LPVault custom errors are used only for the LPVault's own checks, and `packages/protocol` ships the upstream error ABIs. (Source: Q-119)
- `REQ-VAULT-154` — An LPVault MUST follow checks-effects-interactions: `depositorOf` and `marketOfPosition` are written before custody completes its event and deleted before the position leaves; every amount it reports is a return value of the AMM protocol or, for fungible LP shares, its own LP balance delta around the pull; it never holds a market token, because every removal names a recipient other than itself (native ETH is wrapped and forwarded in the same call, `REQ-VAULT-175`). A recipient that acts on an amount measures it by its own balance delta, since a token with a transfer fee delivers less than the AMM protocol reports (`Q-271`). (Source: Q-119, Q-124, Q-148, Q-271)
- `REQ-VAULT-155` — The constructor MUST fix `INTEGRATION_ID`, `COLLATERALIZATION`, `MARKET_REGISTRY`, `LOCK`, `TIMELOCK` and the AMM protocol bindings the integration page names (for example the NFPM and factory of Uniswap v3, or the generation allowlist of Slipstream); it reverts with `InvalidDeployment` for `INTEGRATION_ID = 0`, a zero address, two equal Avana bindings, or AMM protocol bindings that do not belong together (a position manager whose `factory()` is not the pinned factory), so no misconfigured LPVault can be deployed; deployment uses the CREATE3-predicted addresses of Collateralization, the MarketRegistry proxy, the Lock and the AvanaTimelock, and the deployment check verifies each immutable against the deployed address and the chain's manifest. (Source: Q-043, Q-226, Q-228, Q-291)
- `REQ-VAULT-175` — An LPVault whose AMM protocol pays native ETH MUST accept ETH only while the Lock is held and only from that AMM protocol's pool or vault, wrap it into WETH in the same call and forward it with the other amounts; its `receive` reverts in every other case. (Source: Q-297)

### Vault tokens

- `REQ-VAULT-039` — An LPVault MUST NOT mint, burn or hold vault tokens: the AaveAdapter is the only minter and burner of every vault token ([2.4](04-vault-tokens.md), [2.6](06-aave-adapter.md)), and the LPVault keeps no vault-token binding. (Source: Q-224)
- `REQ-VAULT-040` — An LPVault MUST NOT call any vault-token function and is never granted a vault-token allowance; the units that leave Aave on a withdrawal or a seizure are burned by the Adapter from the proxy or from LPVaultSwap before Collateralization debits them, with no token passing through the LPVault. (Source: Q-224)
- `REQ-VAULT-041` — A withdrawal burns from the proxy and a seizure or pending settlement burns from LPVaultSwap (`burnSeized`), both by the Adapter ([2.6](06-aave-adapter.md)); the LPVault MUST take no part in either and only returns or unwinds the position afterwards on Collateralization's instruction. (Source: Q-224)
- `REQ-VAULT-044` — No vault token MUST ever be held by an LPVault: it is not an allowed recipient of any vault token ([2.4](04-vault-tokens.md) `REQ-VTOKEN-006`), so a transfer or mint to it reverts. (Source: Q-224)
- `REQ-VAULT-045` — Because vault tokens cannot reach an LPVault, none is ever credited, debited or moved by it; the LPVault has no vault-token code path at all. (Source: Q-224)

### Fee collection

- `REQ-VAULT-064` — `collectFees(positionKey, depositor)` MUST revert with `NotCollateralization` unless `msg.sender == COLLATERALIZATION`, with `LockNotHeld` unless `LOCK.holder() == LOCK.AAVE_ADAPTER()` (a free Lock and a Lock held by LPVaultSwap both fail), with `NotInCustody` unless `depositorOf(positionKey) != address(0)` (a record at 0 credited units is still in custody), with `NotDepositor` unless `depositor == depositorOf(positionKey)`, and with `FeesRolledIn` when the AMM protocol compounds fees. It is not an outer entry point and acquires no Lock: fee collection runs AaveAdapter `collectFees` → Collateralization `collectFees(depositor, vaultToken, positionKey)` → LPVault `collectFees(positionKey, depositor)` ([2.19](19-amm-integration-interface.md) `REQ-AMM-CORE-010`), and Collateralization checks first that the wallet the Adapter names is the record's depositor ([2.3](03-collateralization.md) `REQ-COLL-032`). (Source: Q-030, Q-134, Q-148, Q-296)
- `REQ-VAULT-172` — `collectFees` MUST change no unit of the position, mint, burn or change no counter, and pay every fee and every amount owed to the position to `depositorOf(positionKey)` only, emitting `FeesCollected(positionKey, depositor, amounts)`; a zero result pays 0 and does not revert. Amounts owed at pledge (principal the depositor removed before pledging and never collected) are paid with the fees: they were never credited, the LPOracle never values them, and removals take only the principal their own call returned. No Avana computation derives fees as collected minus removed. The Uniswap v3 implementation is `REQ-VAULT-065`. (Source: Q-011, Q-030, Q-105, Q-218)
- `REQ-VAULT-066` — Fee collection MUST NOT read the RiskModule, the MarketRegistry, the ParameterStore, a pause state, a breaker, a freeze or a price, and MUST be available in every application pause state (None, Frozen, `Paused` with either reason), every price state, every circuit-breaker state, for a frozen address, every market status including `Offboarding`, every Aave reserve pause or freeze and every Hub halt; the Adapter's `collectFees` path reads none of them either ([2.6](06-aave-adapter.md)). Only a reverting pool, AMM vault or token can make it fail. It reads no pool price: inside a pool swap or flash callback the pool's own reentrancy lock makes the fee payout revert, so a collection never runs inside a pool callback. (Source: Q-051, Q-140, Q-223, Q-227, Q-241, Q-242, Q-252, Q-296)
- `REQ-VAULT-067` — Because `collectFees` and every `unwind` and `releaseToDepositor` run under the Lock, and each removal performs its AMM removal and principal-only payout back to back in one call, fee collection MUST NOT execute between a removal and its payout, so a fee claim can never absorb removed principal. (Source: Q-134, Q-148, Q-201)

### Donations

- `REQ-VAULT-077` — Units added to a custodied position by anyone (an NFT's `increaseLiquidity`) MUST NOT be credited, minted or counted until the depositor of record re-credits them through the Adapter (`recredit`, [2.3](03-collateralization.md) `REQ-COLL-015`), and MUST NOT be removed: the LPVault removes only the units Collateralization debits from the record. Uncredited units stay with the position and return to the depositor on release; live units may exceed credited units and can never fall below them. LP tokens sent to an LPVault of fungible shares are never attributed to a position; only `topUpPosition` adds to one. Why only the depositor's re-credit: a third party adding units cannot book cap space or borrowing power against another borrower's position. (Source: Q-067, Q-201, Q-254, Q-297)

### Stray positions

- `REQ-VAULT-165` — `returnStray(positionKey, recipient)` MUST revert with `NotTimelock` unless `msg.sender == TIMELOCK`, with `Locked` while `LOCK.isLocked()`, with `InvalidRecipient` if `recipient == address(0)` or `recipient == address(this)`, and with `NotStray` unless the LPVault holds the position and it has no custody entry at execution; it then sends the position to `recipient` without running a receiver hook and emits `StrayReturned(positionKey, recipient)`. Why `TIMELOCK` as an immutable instead of a role: the LPVault is immutable, so a fixed caller check gives the same protection with no role storage to govern; requiring the Lock free means no Avana operation is in progress. The Uniswap v3 implementation is `REQ-VAULT-080`. (Source: Q-104, Q-228, Q-296)
- `REQ-VAULT-081` — The recipient MUST be an address governance has established off-chain as the position's rightful owner; the LPVault does not infer it from the sender. (Source: Q-104)
- `REQ-VAULT-082` — The only delay on a stray return MUST be the AvanaTimelock's normal delay (`normalDelay()`, 5 days at launch, [2.15](15-governance-and-timelock.md)): the chain's governance multisig (4-of-7) schedules `returnStray` and anyone executes it after the delay and before the 14-day grace period ends. The LPVault keeps no timer, queue or delay of its own. (Source: Q-104, Q-228)
- `REQ-VAULT-083` — Because nothing is reserved when the operation is scheduled, `returnStray` MUST evaluate the stray condition only at execution: a position pledged since scheduling cannot be moved, and the scheduled operation then reverts with `NotStray`. (Source: Q-104, Q-134)
- `REQ-VAULT-084` — A scheduled stray return MUST be cancellable through the AvanaTimelock's `cancel` by any `CANCELLER_ROLE` holder (the governance multisig, the Emergency Guardian, the Aave Protocol Guardian and the Aave governance executor); the LPVault has no cancel function of its own. (Source: Q-104, Q-228)
- `REQ-VAULT-085` — An LPVault MUST NOT have any sweep or rescue function for ERC-20 tokens, vault tokens, ETH or positions of other contracts; such assets sent to it stay there, and no amount the LPVault reports is read from its own absolute balances. The stray return is the only recovery path, and only for positions of its own AMM protocol. (Source: Q-104, Q-124)

## Permissions

| Function | Allowed caller | How the permission is set |
|---|---|---|
| `bindMarket` | MarketRegistry (`MARKET_REGISTRY`) | Constructor immutable |
| `receivePosition`, `topUpPosition`, `returnPosition`, `unwind`, `releaseToDepositor`, `collectFees` | Collateralization (`COLLATERALIZATION`), while the AaveAdapter or LPVaultSwap holds the Lock; `collectFees` only while the AaveAdapter holds it (`REQ-VAULT-064`) | Constructor immutables |
| `returnStray` | AvanaTimelock (`TIMELOCK`), executing an operation the governance multisig scheduled at the normal delay, while the Lock is free | Constructor immutable; cancel by `CANCELLER_ROLE` holders through the timelock |
| Views | Anyone, while the Lock is free; Collateralization while it is held | None |

No role can move a position in custody for an open record to anyone but its depositor, send a partial removal's principal or a fee to anyone but its depositor, remove units outside Collateralization's instruction, change a stored market or an immutable, or upgrade an LPVault. A faulty or hostile Adapter can have Collateralization pledge any position whose owner approved the LPVault ([2.3](03-collateralization.md) `REQ-COLL-005`), and the position still returns only to that owner.

## Dependencies

| Dependency | Type (internal / external) | Calls made | Why |
|---|---|---|---|
| AMM protocol contracts | External | Per integration page ([2.20](20-uniswap-v3-integration.md), [2.21](21-aerodrome-slipstream-integration.md), [2.22](22-amm-integration-readiness.md)) | Custody, live units, removal, fees, pool lock, listing checks |
| Collateralization ([2.3](03-collateralization.md)) | Internal, immutable | None (it calls the LPVault) | Only source of custody instructions |
| MarketRegistry ([2.8](08-market-registry.md)) | Internal, upgradeable | None (it calls `bindMarket`) | Only source of market bindings; a bound market never changes |
| VaultTokenFactory ([2.4](04-vault-tokens.md)) | Internal, immutable | None (it reads `INTEGRATION_ID`, `COLLATERALIZATION`, `LOCK` at `registerIntegration`) | Write-once integration registry |
| Lock ([2.16](16-lock.md)) | Internal, immutable | `holder`, `isLocked`, `AAVE_ADAPTER` | Instructions arrive only inside an AaveAdapter or LPVaultSwap operation |
| AvanaTimelock ([2.15](15-governance-and-timelock.md)) | Internal, immutable | None (it calls `returnStray`) | Delay on stray returns |

## Events

| Event | Emitted when | Fields |
|---|---|---|
| `MarketBound` | `bindMarket` stores a new market | `marketId` (indexed), `pool`, `poolId`, `tickLower`, `tickUpper` |
| `PositionReceived` | `receivePosition` takes custody | `positionKey` (indexed), `marketId` (indexed), `depositor` (indexed), `units` |
| `PositionReturned` | `returnPosition` sends the position to its depositor | `positionKey` (indexed), `depositor` (indexed) |
| `UnitsUnwound` | `unwind` succeeds | `positionKey` (indexed), `units`, `recipient` (indexed), `amounts` |
| `UnitsReleased` | `releaseToDepositor` succeeds | `positionKey` (indexed), `units`, `depositor` (indexed), `amounts` |
| `PositionToppedUp` | `topUpPosition` succeeds | `positionKey` (indexed), `unitsAdded` |
| `FeesCollected` | `collectFees` succeeds | `positionKey` (indexed), `depositor` (indexed), `amounts` |
| `StrayReceived` | An NFT integration's receiver hook accepts a pushed position | `positionKey` (indexed), `from`, `operator` |
| `StrayReturned` | `returnStray` succeeds | `positionKey` (indexed), `recipient` |

Collateralization emits the record events; the AvanaTimelock emits `CallScheduled`, `CallExecuted` and `Cancelled` for stray returns. Indexers key positions by `(chainId, integrationId, positionKey)` (`Q-292`).

## Restrictions

- `REQ-VAULT-093` — An LPVault MUST NOT take custody of a position for a record except through `receivePosition` from Collateralization, and MUST NOT write `depositorOf` for a position that reached it any other way. (Source: Q-067, Q-104, Q-224)
- `REQ-VAULT-094` — An LPVault MUST NOT send a position with a `depositorOf` entry to any address other than that depositor, and MUST NOT send any position to an Avana contract, a keeper or LPVaultSwap. (Source: Q-067, Q-104, Q-105)
- `REQ-VAULT-095` — An LPVault MUST NOT reduce a position's units except in `unwind` and `releaseToDepositor` called by Collateralization, which passes only units it debited from that position's record in a seizure, reconciliation, deleverage release or partial removal, and MUST NOT pay out more than the principal that removal returned. (Source: Q-061, Q-066, Q-201, Q-224, Q-254, Q-255)
- `REQ-VAULT-096` — An LPVault MUST NOT mint, burn, transfer or approve vault tokens; it holds no vault-token binding. (Source: Q-224)
- `REQ-VAULT-097` — An LPVault MUST NOT expose a generic call, `delegatecall`, multicall, ERC-1271 or arbitrary-target function, MUST NOT grant any approval or operator on a position contract, MUST NOT stake a position in a gauge or subscribe it to a notifier, and MUST NOT burn or destroy a position. (Source: Q-119, Q-226, Q-301)
- `REQ-VAULT-098` — Fee collection and an LPVault's custody functions MUST NOT call any upgradeable Avana contract, and accept instructions only from the immutable Collateralization. Withdrawal, partial removal, repay with collateral, fee collection, zero-credit release and seizure start in the upgradeable Adapter and LPVaultSwap, which the timelock governs; whatever those do, the position, its principal on a partial removal and its fees reach only its depositor. (Source: Q-223, Q-226, Q-296)
- `REQ-VAULT-099` — An LPVault MUST NOT accept a caller-supplied recipient for a position with a depositor of record or for fees; the only caller-supplied values it acts on are `unwind`'s units, minimums and principal recipient and `releaseToDepositor`'s units and minimums from the immutable Collateralization, `bindMarket`'s parameters from the MarketRegistry (validated against the AMM protocol and written once), and the stray recipient from the timelock. (Source: Q-075, Q-105, Q-224, Q-254)

## Failure Conditions

| ID | Condition | Behavior (revert / pause / fallback) |
|---|---|---|
| `REQ-VAULT-101` | `receivePosition` for a position the named owner does not own, or naming the LPVault itself as owner | Reverts with `NotTokenOwner` (`NotTokenOwner` in the NFT integrations); the pledge reverts (Source: Q-067, Q-224, Q-258) |
| `REQ-VAULT-120` | `collectFees` for a position not in custody for a record, or on an AMM protocol whose fees compound | Reverts with `NotInCustody` or `FeesRolledIn`; a caller other than the depositor is refused by Collateralization with `NotDepositor` (Source: Q-030, Q-134, Q-296) |
| `REQ-VAULT-122` | `returnStray` for a position the LPVault does not hold or that has a depositor of record; recipient zero or the LPVault; the Lock held | Reverts with `NotStray`, `InvalidRecipient` or `Locked` (Source: Q-104, Q-296) |
| `REQ-VAULT-123` | `returnStray` called by any address other than the AvanaTimelock, including a direct call by a governance signer | Reverts with `NotTimelock`; an operation executed before its delay or after its grace period is refused by the timelock itself ([2.15](15-governance-and-timelock.md)) (Source: Q-104, Q-228) |
| `REQ-VAULT-126` | The AMM protocol, the pool or a pool token reverts during `collectFees` (pool broken, pool inside a callback, token blocklist of the depositor) | The call reverts with the upstream error; no state changes; the position and fee claim stay intact. Listing excludes fee-on-transfer, rebasing and hook tokens; a broken pool is contained by the Aave reserve freeze and market offboarding (Source: Q-075, Q-227) |
| `REQ-VAULT-156` | A custody, unwind or fee function called by an address other than Collateralization, or `bindMarket` by an address other than the MarketRegistry | Reverts with `NotCollateralization` or `NotMarketRegistry` (Source: Q-224, Q-254, Q-291) |
| `REQ-VAULT-157` | A custody, unwind or fee function called while the Lock is not held | Reverts with `LockNotHeld` (Source: Q-148, Q-254) |
| `REQ-VAULT-158` | `returnPosition`, `unwind`, `releaseToDepositor`, `unitsOf` or `collectFees` for a position not in custody for a record | Reverts with `NotInCustody` (Source: Q-224, Q-254) |
| `REQ-VAULT-159` | `unwind` with recipient zero or the LPVault | Reverts with `InvalidRecipient` (Source: Q-224) |
| `REQ-VAULT-160` | A custody view called while the Lock is held, by an address other than Collateralization | Reverts with `Locked` (Source: Q-119, Q-148, Q-254) |
| `REQ-VAULT-163` | `releaseToDepositor`'s removal returns less than a depositor minimum | The AMM protocol's slippage error passes through, or the LPVault reverts `BelowMinimum(i, received, minimum)` where the AMM protocol has no minimum of its own; the partial removal reverts as a whole (Source: Q-119, Q-254) |
| `REQ-VAULT-164` | A pool token charges a transfer fee on a payout | No LPVault check fails: the LPVault reports the AMM protocol's amounts, and the recipient measures what it received ([2.3](03-collateralization.md) `SPEC-BACK-015`) (Source: Q-271) |
| `REQ-VAULT-173` | `receivePosition` for a position whose pool or shape differs from the market's, or while the pool is mid-operation | Reverts with `PoolMismatch`, `RangeMismatch` or `PoolLocked`; nothing moves. Checked by: MATH-AMM-V3-PRICE-06 (Source: Q-293, Q-305) |
