# 2.18 PayoutEscrow

> **Status:** In review · **Owner:** Avana Labs · **Last reviewed:** 2026-11-11
>
> **Requirement prefix:** `REQ-ESCROW-NNN`

## Purpose

The payout escrow is a small immutable contract, one per chain, that holds any payout LPVaultSwap cannot deliver to its recipient: the borrower surplus of a liquidation ([2.11](11-lpvaultswap.md) `SPEC-LIQ-022`, `Q-337`), Avana's fee to `feeRecipient`, route residues and dust legs owed to the caller, and the route residue of a pending settlement (`Q-389`). Holding failed payouts is its only job (`Q-401`). The caller's payout `keeperOut` is never escrowed: LPVaultSwap transfers it directly to `msg.sender` or the liquidation reverts ([2.11](11-lpvaultswap.md) `REQ-SWAP-026`, `Q-404`). For each escrowable payout ([2.11](11-lpvaultswap.md) `REQ-SWAP-076`) LPVaultSwap first tries to send the amount to its recipient with a gas-limited call that cannot revert the liquidation. If that transfer reverts, returns `false` or runs out of its gas (a token that blocks the recipient's address, a recipient contract that rejects the token), LPVaultSwap deposits the amount here, credited to that recipient and token. The recipient claims it later, in full, to any address it names (`Q-214`). Avana has no in-kind settlement (`Q-401`): every liquidation pays out in the debt asset, apart from a dust leg or a route residue returned in the token it was released as, and the escrow takes whichever token the failed payout is in.

Without the escrow a recipient whose address a token blocks could make every liquidation that owes it a payout revert: a borrower surplus is paid in the debt asset, which for USDC, USDT and GHO can block addresses, so a blocklisted borrower's account could not be liquidated at all. A blocklisted `feeRecipient` (an issuer blocking the treasury Safe) would do the same to every routed liquidation with a surplus and every pending settlement with a residue on the chain, until a normal-delay change of `feeRecipient` executed (N2a).

It is not responsible for:

- deciding, valuing or addressing a payout: LPVaultSwap computes `B` (`SPEC-LIQ-022`), `A` and each residue, and names the recipient;
- holding the caller's payout `keeperOut`, which LPVaultSwap pays directly to `msg.sender` or reverts;
- returning tokens sent to it by plain transfer: only deposits are credited, and there is no sweep.

## Inputs

- From LPVaultSwap, inside a liquidation while it holds the Lock: `deposit(token, account, amount)`, with an exact allowance for `amount` of `token`, pulled by `transferFrom`.
- From a credited account (a borrower, the fee recipient or a liquidation caller owed a residue or dust leg): `claim(token, recipient)`.
- Reads: the Lock's `holder()` (deposit), `isLocked()` (claim) and, once at construction, `LP_VAULT_SWAP()`.

## Outputs

- The whole credited amount of `token` to the recipient the credited account names in `claim`.
- Events.

## Storage

The contract has no proxy, no owner, no role and no setter.

| Variable | Type | Description | Written by |
|---|---|---|---|
| `LP_VAULT_SWAP` | `address` immutable | The chain's LPVaultSwap fixed proxy address; the only depositor | Constructor |
| `LOCK` | `address` immutable | Protocol lock contract ([2.16](16-lock.md)) | Constructor |
| `claimable` | `mapping(address token => mapping(address account => uint256))` | Amount of `token` credited to `account`, in token base units | `deposit` (add), `claim` (clear) |
| `totalClaimable` | `mapping(address token => uint256)` | Sum of `claimable[token][·]` | `deposit`, `claim` |
| Reentrancy flag | transient storage (EIP-1153), one `bool` at the constant `REENTRANCY_SLOT` | Set for the duration of `deposit` and `claim`; slot = `keccak256(abi.encode(uint256(keccak256("avana.escrow.reentrancy")) - 1)) & ~bytes32(uint256(0xff))` = `0xa75fff4cb584554d1fc59956357ed91e22a866262ee7022db6d589f2ebdb4400` | `deposit`, `claim` |

## Functions

| Function | Description | Caller (role / contract) | Requirements |
|---|---|---|---|
| `deposit(address token, address account, uint256 amount)` | Pulls `amount` of `token` from LPVaultSwap and credits it to `account` | LPVaultSwap while it holds the lock | `REQ-ESCROW-002`, `REQ-ESCROW-003` |
| `claim(address token, address recipient) returns (uint256 amount)` | Pays the caller's whole credit of `token` to `recipient` | Any address with a credit (the credited account) | `REQ-ESCROW-004`, `REQ-ESCROW-005` |
| `claimable(address token, address account) returns (uint256)`, `totalClaimable(address token) returns (uint256)` | Views | Anyone | `REQ-ESCROW-006` |

## Permissions

Permission is by immutable address and by `msg.sender`, not by role. No Avana role (timelock, `APPLICATION_ADMIN`, either guardian) and no Aave role can call `deposit`, move a credit, claim for an account, change an address or upgrade the contract.

| Function | Who | Delay | Cancel |
|---|---|---|---|
| `deposit` | LPVaultSwap (immutable address check), only while the Lock is held by LPVaultSwap | None | None |
| `claim` | The credited account (`msg.sender`) | None | None |
| Views | Anyone | None | None |

## Dependencies

| Dependency | Type (internal / external) | Calls made | Why |
|---|---|---|---|
| Lock contract | Internal (immutable) | `holder()`, `isLocked()` | Deposits only inside a liquidation; no claim inside an Avana call tree |
| LPVaultSwap | Internal (fixed address) | Caller of `deposit` | Only depositor |
| A market's released tokens and the debt assets of its Spoke | External | `transferFrom`, `transfer`, `balanceOf` | Pull deposits, pay claims |

## Restrictions

- `REQ-ESCROW-001` The PayoutEscrow MUST be immutable: no proxy, no `delegatecall`, no `selfdestruct`, no owner, no role, no setter, no pause, and no sweep, rescue or arbitrary-call function. Its constructor MUST revert with `ZeroAddress` unless `LP_VAULT_SWAP` and `LOCK` are both non-zero, and with `LockMismatch` unless `LOCK` has code and `ILock(LOCK).LP_VAULT_SWAP() == LP_VAULT_SWAP`. Why: the Lock is deployed before the escrow (deployment step 4 against step 9), so the check is always possible, and a mis-wired escrow would otherwise be permanent: with another LPVaultSwap, `holder()` could never equal `LP_VAULT_SWAP`, every deposit would revert `NotLocked` and every liquidation or `settlePending` with a failed payout would revert until LPVaultSwap was upgraded to a new escrow after the 5-day delay; with the AaveAdapter passed as `lpVaultSwap`, the Adapter could deposit while it holds its own Lock. `07_VerifyDeployment` also asserts `PayoutEscrow.LOCK().LP_VAULT_SWAP() == PayoutEscrow.LP_VAULT_SWAP() == LPVaultSwap proxy`. Tokens leave the escrow only through `claim`, to the recipient the credited account names, so a compromised Avana or Aave key, or a hostile LPVaultSwap upgrade, cannot take a credited payout. (Source: Q-214, Q-049, Q-124)
- `REQ-ESCROW-002` `deposit` MUST revert with `NotLPVaultSwap` unless `msg.sender == LP_VAULT_SWAP`, with `NotLocked` unless `LOCK.holder() == LP_VAULT_SWAP`, with `ZeroAmount` if `amount == 0` and with `InvalidAccount` if `account == address(0)`. LPVaultSwap never deposits a zero payout (`Q-217`), so the zero check only rejects a faulty caller. (Source: Q-214, Q-148, Q-217)
- `REQ-ESCROW-003` `deposit` MUST request `amount` of `token` from `LP_VAULT_SWAP` with `SafeERC20.safeTransferFrom`, measure `received` as the rise of its own `token` balance, revert with `TransferMismatch` if the balance did not rise (`received == 0`, or a balance that fell, which is never read as a negative credit), cap `received` at `amount`, then add `received` to `claimable[token][account]` and to `totalClaimable[token]` and emit `RemainderEscrowed(token, account, received)`. A rise above the request (a rounding-up token, or an aToken-style balance that rises by `amount + 1`) credits `amount` and leaves the surplus in the escrow as an unattributed donation, so it never reverts the liquidation. Why: a credit must equal what the escrow actually holds for it, or `REQ-ESCROW-006` would fail and a later claim could pay one account with another's tokens; crediting the measured amount keeps that true when an issuer switches on a transfer fee after listing (USDT's `basisPointsRate`), while an exact-amount check would make every liquidation that escrows a payout of that token revert. Example: with USDT's fee at 10 bps, a 1,612,848 USDT deposit arrives as 1,611,236 and the recipient is credited 1,611,236. A revert of `deposit` (including a token that blocks the escrow's own address) reverts the whole liquidation; that case is a token blocking an Avana contract, handled by the token-issuer playbook ([3.6](../03-operations/06-emergency-operations.md)), which contains it per market with the Aave reserve freeze of the market's vault-token reserve and `Offboarding` and ends in a migration ([2.11](11-lpvaultswap.md) `REQ-SWAP-064`, `Q-227`). Fee-on-transfer and rebasing tokens are still excluded at listing ([2.11](11-lpvaultswap.md) `REQ-SWAP-123`). Checked by: TEST-221. (Source: Q-214, Q-124, Q-058, Q-271)
- `REQ-ESCROW-004` `claim(token, recipient)` MUST revert with `LockHeld` while `LOCK.isLocked()` is true, so a claim never runs inside an Avana call tree; with `InvalidRecipient` if `recipient` is `address(0)` or the escrow itself; and with `NothingToClaim` if `claimable[token][msg.sender] == 0`. Otherwise it MUST set `amount = claimable[token][msg.sender]`, set that credit to 0 and subtract `amount` from `totalClaimable[token]` before the transfer, transfer `amount` to `recipient` with `SafeERC20.safeTransfer`, revert with `TransferMismatch` if its own `token` balance fell by more than `amount`, emit `RemainderClaimed(token, msg.sender, recipient, amount)` and return `amount` (the amount sent; a recipient-side fee lowers what arrives, not what the escrow pays). Why the balance check: a token that takes a fee from the sender on top of the amount would pay each claim partly out of other accounts' credits and break `REQ-ESCROW-006`; reverting keeps every credit backed, and the account claims once the fee is off. The whole credit is paid in one call; if the token refuses `recipient`, the call reverts, the credit stays, and the account claims again to another recipient. Checked by: MATH-ST-30. (Source: Q-214, Q-124, Q-217)
- `REQ-ESCROW-005` A credit MUST be claimable only by the account it was credited to, as `msg.sender`; the escrow has no claim-on-behalf, no signature path and no way to move a credit to another address. LPVaultSwap credits three kinds of account, each an address that can call `claim` itself: the borrower, which is the wallet bound to the liquidated PositionProxy (`AaveAdapter.walletOf(proxy)`, equal to the proxy's immutable `WALLET()` and fixed for its life, `Q-225`, `Q-349`) and already signs its own transactions to the AaveAdapter; `feeRecipient`, the chain's treasury Safe, which executes `claim` as a Safe transaction; and the caller of the liquidation (`msg.sender` of LPVaultSwap), credited only a route residue or dust leg it could not receive, whose EOA or contract calls `claim`: an operator's flash liquidation helper claims through `claimEscrowed` to its funding Safe, and the public helper has no claim function, because such a credit arises only when a market token refuses transfers to it ([2.11](11-lpvaultswap.md) `REQ-HELPER-010`, `REQ-HELPER-011`). The caller's payout `keeperOut` is never credited here. The claim does not pass through the Adapter or the proxy. Credits never expire, and a credit to an earlier `feeRecipient` stays claimable by that address after `feeRecipient` changes. (Source: Q-214, Q-107, Q-225, Q-389, Q-404)
- `REQ-ESCROW-006` For every token, `totalClaimable[token]` MUST equal the sum of `claimable[token][b]` over all credited accounts, and, while no one but the escrow moves its balance, the escrow's `token` balance MUST be at least `totalClaimable[token]`. Tokens sent to the escrow by plain transfer, and any rise of a deposit above its request, raise the balance without any credit and stay in the escrow; no function can move them. If the token's issuer burns from the escrow (USDT's `destroyBlackFunds`) or a negative rebase lowers its balance, the balance can fall below `totalClaimable[token]`: claims are then paid first come, first served, and the last ones revert with the token's balance error, keeping their credits, until the balance is restored; the escrow cannot prevent this and does not try. Example: a liquidation escrows 1,627,460 raw USDC for borrower `b1` and a later one 3,100,000 for the fee recipient `b2`, so `totalClaimable[USDC] = 4,727,460`; someone sends 10 USDC directly, so the balance is 14,727,460 while `totalClaimable` stays 4,727,460; after `b1` claims, both fall by 1,627,460. Checked by: MATH-ST-29, MATH-ST-31. (Source: Q-214, Q-124)
- `REQ-ESCROW-007` `deposit` and `claim` MUST hold a transient reentrancy flag for their whole duration and revert with `Reentrancy` if it is already set, and `claim` MUST follow checks-effects-interactions as stated in `REQ-ESCROW-004`, so a token callback during a claim can neither claim the same credit twice nor deposit. The flag check is the first check of both functions, so a reentrant call reverts with `Reentrancy` whatever its caller and arguments; the other checks then run in the order `REQ-ESCROW-002` and `REQ-ESCROW-004` list them (`NotLPVaultSwap`, `NotLocked`, `ZeroAmount`, `InvalidAccount` for `deposit`; `LockHeld`, `InvalidRecipient`, `NothingToClaim` for `claim`), and a call that fails several reverts with the first. Example: a claim to `address(0)` by an account with no credit, while the Lock is free, reverts with `InvalidRecipient`. (Source: Q-148, Q-214)
- `REQ-ESCROW-008` The escrow MUST NOT check prices, price states, the application pause state or its reason, circuit breakers, the address freeze, market status or token listings and MUST NOT call any Avana contract other than the Lock views; it never reads the MarketRegistry, the RiskModule or the ParameterStore. Deposits come only from LPVaultSwap with a market's released token or a debt asset, and a claim for any other token address finds no credit and reverts with `NothingToClaim`. A claim therefore runs in every application state (None, Frozen, `Paused(General)` and `Paused(MintPathSuspect)`), under every breaker, for an `Offboarding` market and for an account whose address is frozen (`Q-242`): a credit is that account's own property, held only because delivery failed, so no Avana switch may hold it. The escrow is in the address-freeze protected set, so `freezeAddress` cannot name it. Only the token itself (a blocklist or a token pause) can stop a claim. Checked by: TEST-229, PROP-066. (Source: Q-214, Q-051, Q-227, Q-241, Q-242, Q-252)

- `REQ-ESCROW-017` A borrower surplus that LPVaultSwap could not deliver is deposited and credited to the borrower's wallet: `deposit`, credit key `(token, borrower)`, `claim` by the borrower. Example: a routed USDC liquidation owes borrower `b1` a surplus `B = 4,500,000` (4.5 USDC, [2.11](11-lpvaultswap.md) `SPEC-LIQ-022`); `b1` is on USDC's blocklist, so the gas-limited transfer reverts and LPVaultSwap deposits 4,500,000 USDC here for `b1`, which `b1` later claims to another wallet. (Source: Q-214, Q-337)
- `REQ-ESCROW-018` Avana's fee, a route residue or dust leg owed to the caller, and the residue of `settlePending` that LPVaultSwap could not deliver are deposited and credited exactly like a borrower payout: same `deposit`, credit key `(token, recipient)`, same `claim` by the recipient. A failed delivery of any of them never reverts the liquidation or the pending settlement; only a revert of `deposit` does (`REQ-ESCROW-003`). Example: Circle blocklists the treasury Safe that is `feeRecipient` on Ethereum; a routed USDC liquidation owes `A = 19.5` USDC; the gas-limited transfer to the Safe reverts, LPVaultSwap deposits 19,500,000 units credited to the Safe, the liquidation completes, and after the Safe's owners move the treasury they call `claim(USDC, newTreasury)` from the old Safe. The caller's payout `keeperOut` is not deposited: a failed transfer of it reverts the liquidation ([2.11](11-lpvaultswap.md) `REQ-SWAP-026`). Checked by: FV-LIQ-05. (Source: Q-214, Q-389, Q-404)

### Worked example

A routed USDC liquidation owes borrower `b1` a surplus `B = 1,627,460` raw USDC (1.627460 USDC, [2.11](11-lpvaultswap.md) `SPEC-LIQ-022`), Avana's fee and the caller's payout. The borrower's wallet `b1` is on USDC's blocklist. LPVaultSwap pays the fee and the caller's payout normally; its gas-limited USDC transfer to `b1` reverts, so it approves the escrow for 1,627,460 USDC and calls `deposit(USDC, b1, 1,627,460)`; the escrow's USDC balance rises by 1,627,460 and `claimable[USDC][b1] = 1,627,460`. The liquidation completes. Later `b1` calls `claim(USDC, b2)` with a second wallet `b2` that USDC accepts; the credit is cleared and 1,627,460 USDC reaches `b2`. A second `claim(USDC, b2)` reverts with `NothingToClaim`.

## Events

| Event | Emitted when | Fields |
|---|---|---|
| `RemainderEscrowed` | `deposit` succeeds | `token` (indexed), `account` (indexed), `amount` |
| `RemainderClaimed` | `claim` succeeds | `token` (indexed), `account` (indexed), `recipient`, `amount` |

LPVaultSwap's `LiquidationSettled` reports an escrowed borrower surplus (`borrowerEscrowed`) and any escrowed fee, route residue or dust leg, in the same transaction ([2.11](11-lpvaultswap.md)). The indexer shows each account's unclaimed credits from these events; the Lens reads them from `claimable` ([2.17](17-lens.md)).

Preserved invariants (every escrowed payout backed by the escrow's balance, only the credited account can move it) are stated in [4.1 Global Invariants](../04-security/01-global-invariants.md).

## Failure Conditions

| ID | Condition | Behavior (revert / pause / fallback) |
|---|---|---|
| `REQ-ESCROW-019` | Constructor with a zero `lpVaultSwap` or `lock`, a `lock` without code, or a `lock` whose `LP_VAULT_SWAP()` is not `lpVaultSwap` | reverts with `ZeroAddress` or `LockMismatch`; the escrow is not deployed (Source: Q-214) |
| `REQ-ESCROW-009` | `deposit` from any caller other than LPVaultSwap, or while the Lock is not held by LPVaultSwap | reverts with `NotLPVaultSwap` or `NotLocked` (Source: Q-214, Q-148) |
| `REQ-ESCROW-010` | `deposit` with `amount == 0` or `account == address(0)` | reverts with `ZeroAmount` or `InvalidAccount` (Source: Q-214, Q-217) |
| `REQ-ESCROW-011` | Escrow balance did not rise in `deposit` or the token refuses the transfer to the escrow; in `claim`, the escrow's balance fell by more than the amount paid (a sender-side fee) | reverts with `TransferMismatch` or the token's error; for `deposit` the whole liquidation reverts and the market is handled as a token blocking an Avana contract; for `claim` every credit stays and the account claims once the fee is off (Source: Q-214, Q-124, Q-271) |
| `REQ-ESCROW-012` | `claim` while the Lock is held | reverts with `LockHeld` (Source: Q-148, Q-214) |
| `REQ-ESCROW-013` | `claim` with no credit for the caller and token | reverts with `NothingToClaim` (Source: Q-214, Q-217) |
| `REQ-ESCROW-014` | `claim` to `address(0)` or to the escrow itself | reverts with `InvalidRecipient` (Source: Q-214) |
| `REQ-ESCROW-015` | The token refuses the transfer to the claim's `recipient` | reverts with the token's error; the credit is unchanged and the credited account claims again to another recipient (Source: Q-214) |
| `REQ-ESCROW-016` | Reentry into `deposit` or `claim` during either call | reverts with `Reentrancy` (Source: Q-148, Q-214) |
