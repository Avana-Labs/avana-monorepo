# 2.23 AvanaGasVault

> **Status:** In review · **Owner:** Avana Labs · **Last reviewed:** 2026-11-16
>
> **Requirement prefix:** `REQ-GASV-NNN`

## Purpose

The AvanaGasVault is a small immutable periphery contract, one per chain, that holds the chain's native gas token and refills Avana's own keeper signers (`Q-413`). Avana's keeper is the only party that must spend gas on maintenance: oracle pokes, breaker and drift pokes, unprofitable and dust liquidations, and the lazy jobs ([3.6](../03-operations/06-emergency-operations.md) `EMG-114`). Third parties are paid only through `keeperOut` and need no gas source. The vault removes the human latency of a treasury Safe refill: anyone can trigger a top-up, which pays only an allowlisted signer, only while it is below its refill trigger, and never more than a per-signer cap over any 24 hours.

It is outside the audited core: no core contract calls it or reads it, and it holds no Avana role. One vault and one signer pair (primary and standby) per chain serve every Hub and every tier on that chain; nothing in it depends on the number of chains, Hubs or markets.

It is not responsible for:

- refunding per-transaction gas: it reads neither `tx.gasprice` nor `gasleft()` (a refund at the caller's gas price is drainable, `ATTACK-207`);
- funding third-party operators: the allowlist holds Avana's own keeper signers only (`Q-413`, D7);
- converting keeper liquidation profits into gas: those stay in `FUNDING_SAFE`, and any conversion is a manual treasury decision (`EMG-115`);
- holding ERC-20s, bridging, or calling any Avana contract.

## Inputs

- From anyone: ETH through `fund()` or a plain transfer; `topUp(signer)` and `topUpAll()`.
- From the chain's AvanaTimelock: `addSigner`, `setSignerConfig`, `unpause`, `withdraw`.
- From the chain's Emergency Guardian Safe (or the timelock): `tightenSigner`, `removeSigner`, `pause`.
- Reads: each signer's native balance and the vault's own balance.

## Outputs

- ETH to an allowlisted signer (top-up) or to `TREASURY` (withdrawal); nothing else.
- Events.

## Storage

| Field | Type | Meaning |
|---|---|---|
| `TREASURY` | `address` immutable | The chain's `feeRecipient` treasury Safe (`Q-196`); the only withdrawal destination; never `FUNDING_SAFE` |
| `TIMELOCK` | `address` immutable | The chain's AvanaTimelock |
| `GUARDIAN` | `address` immutable | The chain's Emergency Guardian Safe |
| `MAX_SIGNERS` | `uint256` immutable | Allowlist bound, `1 ≤ MAX_SIGNERS ≤ MAX_SIGNERS_LIMIT = 8` |
| `PERIOD`, `MAX_SENDS_PER_PERIOD` | constants | 86,400 s; 4 |
| `paused` | `bool` | Top-ups paused |
| signer list | `address[]` | Allowlist, swap-and-pop on removal |
| per signer | `uint80 minBalance`, `uint80 targetBalance`, `uint80 periodCap`, `uint8 position` | One slot; `position` 0 = not listed |
| per signer sends | `uint128[4]` | The last four sends, each `(uint48 timestamp, uint80 amount)`; kept on removal |

## Functions

| Function | Description | Caller | Requirements |
|---|---|---|---|
| `fund()`, `receive()` | Adds ETH | Anyone | `REQ-GASV-003` |
| `topUp(address signer) returns (uint256)` | Refills one due signer toward its target | Anyone | `REQ-GASV-004`, `REQ-GASV-005`, `REQ-GASV-013` |
| `topUpAll() returns (uint256 count, uint256 total)` | Refills every due signer, skipping the rest | Anyone | `REQ-GASV-006`, `REQ-GASV-013` |
| `addSigner(signer, minBalance, targetBalance, periodCap)` | Lists an Avana keeper signer | `TIMELOCK` | `REQ-GASV-007` |
| `setSignerConfig(signer, minBalance, targetBalance, periodCap)` | Sets a signer's values either way | `TIMELOCK` | `REQ-GASV-008` |
| `tightenSigner(signer, minBalance, targetBalance, periodCap)` | Lowers a signer's values | `GUARDIAN` or `TIMELOCK` | `REQ-GASV-009` |
| `removeSigner(signer)` | Delists a signer | `GUARDIAN` or `TIMELOCK` | `REQ-GASV-010` |
| `pause()`, `unpause()` | Stops or restarts top-ups | `pause`: `GUARDIAN` or `TIMELOCK`; `unpause`: `TIMELOCK` | `REQ-GASV-011` |
| `withdraw(uint256 amount)` | Sends ETH to `TREASURY` | `TIMELOCK` | `REQ-GASV-012`, `REQ-GASV-013` |
| `signers()`, `isSigner`, `signerConfig`, `sentInPeriod`, `quoteTopUp`, `paused` | Views | Anyone | `REQ-GASV-014` |

## Permissions

Permission is by immutable address, not by role (`REQ-ROLE-001`, `REQ-ROLE-118`): the vault keeps no role storage. The split follows the code base's tighten/loosen rule: the guardian can only make the vault send less, at once; anything that makes it send more, or moves ETH out other than a top-up, waits a timelock delay.

| Function | Who | Delay | Cancel |
|---|---|---|---|
| `topUp`, `topUpAll`, `fund` | Anyone | None | None |
| `addSigner`, `setSignerConfig` | `TIMELOCK` | Normal | Any canceller |
| `unpause` | `TIMELOCK` | Normal (the timelock's `SHORT_ELIGIBLE` set is fixed when it is deployed, so a vault deployed later cannot be on it) | Any canceller |
| `withdraw` | `TIMELOCK` | Normal | Any canceller |
| `tightenSigner`, `removeSigner`, `pause` | `GUARDIAN` immediately, or `TIMELOCK` | None (guardian) | None |

## Dependencies

| Dependency | Type (internal / external) | Calls made | Why |
|---|---|---|---|
| AvanaTimelock | Internal (immutable address) | Caller only | Adds, raises, unpauses, withdraws |
| Emergency Guardian Safe | Internal (immutable address) | Caller only | Removes, lowers, pauses |
| Keeper signers, `TREASURY` | External | ETH transfer with empty calldata | Top-up, withdrawal |

## Restrictions

- `REQ-GASV-001` The AvanaGasVault MUST be immutable periphery outside the audited core: no proxy, no `delegatecall`, no `selfdestruct`, no owner and no role storage; it MUST NOT hold or move ERC-20s, read `tx.gasprice` or `gasleft()`, call any Avana contract, or make any external call other than an ETH transfer with empty calldata to a listed signer or to `TREASURY`; no core contract calls or reads it. One vault per chain serves every Hub on the chain; no value in it depends on the number of chains, Hubs or markets. Why: the only party Avana must pay is its own keeper, so a refund design or a core dependency adds attack surface without adding a payee. (Source: Q-413)
- `REQ-GASV-002` The constructor MUST take `treasury`, `timelock`, `guardian` and `maxSigners`, revert `InvalidAddress` if any address is zero or `treasury` equals `timelock` or `guardian`, and revert `InvalidMaxSigners` unless `1 ≤ maxSigners ≤ 8`. The deploy script MUST check that `treasury` equals the chain's ParameterStore `feeRecipient` and differs from the operator liquidator's `FUNDING_SAFE`. (Source: Q-196, Q-413)
- `REQ-GASV-003` `fund()` and a plain transfer MUST accept ETH from anyone and emit `Funded(from, amount)`. Funding is a lump sum from the `feeRecipient` treasury Safe (`EMG-115`). (Source: Q-413)
- `REQ-GASV-004` `topUp(signer)` MUST revert `VaultPaused` while paused, `UnknownSigner` unless `signer` is listed, and `NotBelowMinimum` unless `signer.balance < minBalance`; it MUST send `amount = min(targetBalance − balance, periodCap − sentInPeriod(signer), address(this).balance)` (with `targetBalance − balance` read as 0 when the balance is at or above the target) to `signer` and never to `msg.sender`, revert `NothingToSend` if `amount == 0`, record the send before the transfer, revert `SendFailed` if the transfer fails, and emit `ToppedUp(signer, caller, amount, requested)` with `requested = targetBalance − balance`. Why permissionless: the caller chooses only which listed signer, and the amount and destination come from on-chain state, so no caller gains. Example: `minBalance = 0.3 ETH`, `targetBalance = 1 ETH`, `periodCap = 1 ETH`, a signer at 0.2 ETH with nothing sent in 24 h: `topUp` sends 0.8 ETH; once it falls to 0.1 ETH, a second `topUp` in the same 24 h sends 0.2 ETH (`ToppedUp(…, 0.2 ETH, 0.9 ETH)`, the cap-limited case M-36 pages on). (Source: Q-413)
- `REQ-GASV-005` The ETH sent to a signer in any window `(t − 86,400 s, t]` MUST NOT exceed the `periodCap` in force at each send in it: the vault keeps the signer's last `MAX_SENDS_PER_PERIOD = 4` sends, `sentInPeriod` sums those in the window ending now, and a send is allowed only into a slot that is empty or older than the window, so at most four sends fall in any window. A removed signer's sends are kept, so re-adding it inside 24 h does not reset its window. Why a window and not a calendar period: a period reset would let a stolen key take one cap just before the reset and another just after; with the window the loss on a stolen key is at most its balance (≤ `targetBalance`) plus one `periodCap` before the guardian removes it. Example: 0.1 ETH sent at `t0` and 0.9 ETH at `t0 + 23 h` with `periodCap = 1 ETH`: at `t0 + 24 h` only 0.1 ETH has left the window, so a top-up sends at most 0.1 ETH. Checked by: PROP-113. (Source: Q-413)
- `REQ-GASV-006` `topUpAll()` MUST revert `VaultPaused` while paused and otherwise apply the rule of `REQ-GASV-004` to every listed signer in order, skipping a signer not below its minimum or with a zero amount, and, for a signer whose transfer fails, undo its record, emit `TopUpFailed(signer, amount)` and continue; it returns the count paid and the total sent. Its gas is bounded by `MAX_SIGNERS ≤ 8`: with 8 due signers, 236,944 gas once each signer's send slots are in use and 373,088 on their first sends, which write zero slots (measured, `contracts/snapshots/AvanaGasVault.json`). (Source: Q-413)
- `REQ-GASV-007` `addSigner(signer, minBalance, targetBalance, periodCap)` MUST revert `NotTimelock` unless `msg.sender == TIMELOCK`; `InvalidSigner` for `address(0)`, the vault, `TREASURY`, `TIMELOCK`, `GUARDIAN` or a listed signer; `TooManySigners` when `MAX_SIGNERS` are listed; and `InvalidConfig` unless `0 < minBalance ≤ targetBalance`, `0 < periodCap`, and every value `≤ 2^80 − 1`. The timelock lists only Avana's own keeper signers (KMS-backed), primary and standby per chain (D7). (Source: Q-413)
- `REQ-GASV-008` `setSignerConfig` MUST revert `NotTimelock` for any other caller, `UnknownSigner` for an unlisted signer and `InvalidConfig` as in `REQ-GASV-007`; it sets the three values in either direction and emits `SignerConfigChanged(signer, TIMELOCK, …)`. (Source: Q-413)
- `REQ-GASV-009` `tightenSigner` MUST revert `NotGuardianOrTimelock` unless the caller is `GUARDIAN` or `TIMELOCK`, `UnknownSigner` for an unlisted signer, `NotTighter` if any new value is above the current one, and `InvalidConfig` unless `minBalance ≤ targetBalance`; zeros are allowed (a signer with `minBalance = 0` is never topped up). The guardian can never raise a value, list a signer, unpause or withdraw. Checked by: PROP-113. (Source: Q-413)
- `REQ-GASV-010` `removeSigner` MUST revert `NotGuardianOrTimelock` for any other caller and `UnknownSigner` for an unlisted signer; it delists at once, and a removed signer receives nothing from either top-up. (Source: Q-413)
- `REQ-GASV-011` `pause()` (guardian or timelock) MUST stop `topUp` and `topUpAll`; `unpause()` MUST revert `NotTimelock` for any other caller. `unpause` runs at the timelock's normal delay: `SHORT_ELIGIBLE` is fixed when the timelock is deployed, so a vault deployed later is not on it. Funding, withdrawal and the guardian's removals and lowerings stay open while paused. (Source: Q-413)
- `REQ-GASV-012` `withdraw(amount)` MUST revert `NotTimelock` for any other caller and `InvalidWithdrawal` if `amount` is 0 or above the vault's balance, send `amount` to `TREASURY` only, revert `SendFailed` if the transfer fails, and emit `Withdrawn(amount)`. ETH leaves the vault only to a listed signer through a top-up or to `TREASURY` through `withdraw`. Checked by: PROP-113. (Source: Q-196, Q-413)
- `REQ-GASV-013` `topUp`, `topUpAll` and `withdraw` MUST hold a transient reentrancy guard for their whole duration, so a signer's code cannot re-enter a top-up during its own transfer, and MUST forward at most 100,000 gas with each ETH transfer and copy no return data (as LPVaultSwap's payouts do), so a recipient's code cannot burn the caller's gas; a transfer that runs out of it fails like any other. (Source: Q-413)
- `REQ-GASV-014` The views MUST report the allowlist, each signer's values (zeros when unlisted), `sentInPeriod(signer)` over `(now − 86,400 s, now]` and `quoteTopUp(signer)`: what `topUp` would send now and request, `(0, 0)` when not listed or not due and an amount of 0 while paused, so the keeper and the monitor read the vault without simulating. (Source: Q-413)

### Worked example

Ethereum, primary signer `K1` with `minBalance = 0.6 ETH`, `targetBalance = 1.6 ETH`, `periodCap = 1.6 ETH` (`D = 0.2 ETH` per day, `minBalance = 3 × D`, `targetBalance = 7 × D + B` with burst reserve `B = 0.2 ETH`, [1.5](../01-architecture/05-parameters.md)). On a quiet day K1 falls from 1.6 to 0.59 ETH in about five days; the keeper's own balance check calls `topUpAll()`, which sends 1.01 ETH to K1 and nothing to the standby. In a crash K1 spends 1.5 ETH in an hour: the first top-up of the day sends 1.5 ETH; a second fall below 0.6 ETH three hours later finds 0.1 ETH of cap room, sends it, emits `ToppedUp(K1, …, 0.1 ETH, 1.5 ETH)`, and the monitor pages M-36; treasury raises the cap through the timelock or waits for the window to roll.

## Events

| Event | Emitted when | Fields |
|---|---|---|
| `Funded` | ETH received | `from` (indexed), `amount` |
| `ToppedUp` | A top-up sent ETH | `signer` (indexed), `caller` (indexed), `amount`, `requested` |
| `TopUpFailed` | `topUpAll` skipped a refused transfer | `signer` (indexed), `amount` |
| `SignerAdded` | `addSigner` | `signer` (indexed), `minBalance`, `targetBalance`, `periodCap` |
| `SignerConfigChanged` | `setSignerConfig` or `tightenSigner` | `signer` (indexed), `by` (indexed), the three values |
| `SignerRemoved` | `removeSigner` | `signer` (indexed), `by` (indexed) |
| `PauseChanged` | `pause` or `unpause` | `paused`, `by` (indexed) |
| `Withdrawn` | `withdraw` | `amount` |

Preserved invariant (the 24 h cap per signer) is `INV-111` in [4.1 Global Invariants](../04-security/01-global-invariants.md).

## Failure Conditions

| ID | Condition | Behavior (revert / pause / fallback) |
|---|---|---|
| `REQ-GASV-015` | A top-up while paused, of an unlisted signer, of a signer not below its minimum, with a zero amount, or whose transfer fails | reverts `VaultPaused`, `UnknownSigner`, `NotBelowMinimum`, `NothingToSend` or `SendFailed`; `topUpAll` skips instead, except while paused (Source: Q-413) |
| `REQ-GASV-016` | A privileged call by the wrong caller, a guardian raise, an invalid signer or configuration, or an allowlist at `MAX_SIGNERS` | reverts `NotTimelock`, `NotGuardianOrTimelock`, `NotTighter`, `InvalidSigner`, `InvalidConfig` or `TooManySigners` (Source: Q-413) |
| `REQ-GASV-017` | The vault runs dry | top-ups send what is left, then revert `NothingToSend`; the keeper keeps running on its own balance, M-35 pages the treasury, and every keeper job stays callable by anyone (Source: Q-413) |
