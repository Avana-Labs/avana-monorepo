# 4.2 Attack Scenarios

> **Status:** In review · **Owner:** Avana Labs · **Last reviewed:** 2026-11-12

Attacks against Avana and the protection that blocks or bounds each one (decisions `Q-001`…`Q-278` and `Q-363`). *Attack approach* lists the calls the attacker would make; *Expected protection* states the rule that stops them.

**Attacker model.** Flash loans, block-builder access or private order flow, can deploy contracts, holds debt assets (GHO, USDC and any other listed asset) and pool tokens, can be a borrower, LP, payer or keeper, or controls one compromised key or one hostile upgrade that passed the Avana timelock's normal delay (5 days at launch, never below the 4-day `MIN_NORMAL_DELAY`) without any canceller acting. Upstream behaviour is the pinned Aave V4 `a3ef63e` with standard, unmodified CDP Spokes on every Hub and chain, each AMM protocol's position manager and pools (Uniswap v3 on Ethereum, Aerodrome Slipstream on Base), the Aave V3 Pool behind the flash liquidation helper and the `IFlashSource` of repay with collateral, each L2 sequencer-uptime feed, and the collateral and debt-asset feeds and swap routes ([4.3](03-external-dependencies.md)).

**Fields.** *Affected steps* name the operation step prefixes (`DEP` pledge, `BOR` borrow, `REP` repay, `WDR` withdraw, `LIQ` liquidation, `EMG` emergency, `FEE` fee collection, `MKT` market lifecycle, `DEF` deficit coverage); exact step IDs are linked from the operation pages. *Expected protection* names the invariants ([4.1](01-global-invariants.md)) and decisions that block the attack. *Result* is one of **Mitigated**, **Accepted risk** (with the owner who carries it and the bound on the loss) or **Launch condition** (mitigated once the named check passes before launch). *Checks* name the spec-stage model checks (`MATH`, `SYM`, `QNT`, `HYP`, `SIM`), the implementation tests ([5.1](../05-verification/01-test-requirements.md)) and the findings-register entries ([5.3](../05-verification/03-audit-findings.md)) specific to the scenario; the invariants named under *Expected protection* carry their own tests in 5.1, so `None` means no check beyond those.

## Index

| Category | Scenarios |
|---|---|
| Custody and minting | `ATTACK-001`, `ATTACK-003` … `ATTACK-017` |
| Vault-token escape and seizure paths | `ATTACK-002`, `ATTACK-018` … `ATTACK-028` |
| Proxies, Adapter, RiskModule and approvals | `ATTACK-029` … `ATTACK-039` |
| Oracle and price states | `ATTACK-040` … `ATTACK-056` |
| Liquidation griefing and economics | `ATTACK-057` … `ATTACK-081` |
| Keepers and operations | `ATTACK-082` … `ATTACK-086` |
| Caps, deficits and share math | `ATTACK-087` … `ATTACK-091`, `ATTACK-095`, `ATTACK-096` |
| Reentrancy | `ATTACK-092` … `ATTACK-094` |
| Governance | `ATTACK-097` … `ATTACK-104` |
| Off-chain, signatures and dependencies | `ATTACK-105` … `ATTACK-110` |
| Settlement recovery, Aave reserve pauses and persistent disagreement | `ATTACK-111` … `ATTACK-113` |
| Open liquidation entry point, third-party repay and payout escrow | `ATTACK-114` … `ATTACK-119` |
| CDP Spoke implementation and configuration | `ATTACK-120`, `ATTACK-121` |
| Adapter custody, immutable proxies, governance timing and multi-asset debt | `ATTACK-122` … `ATTACK-137` |
| Circuit breakers, address freeze, standby routes, rescue and new liquidation paths | `ATTACK-138` … `ATTACK-152` |
| AMM-neutral core, Hubs and chains | `ATTACK-153` … `ATTACK-197` |

## Custody and minting

### ATTACK-001: Duplicate LP Collateral Registration

| Field | Value |
|---|---|
| Target | AaveAdapter, Collateralization, LPVault, vault token |
| Objective | Make one deposited NFT back more than one collateral claim |
| Affected steps | `DEP` custody, record, mint and supply steps; `WDR` release |
| Prerequisites | One pledgeable NFT; optionally a second wallet or a second CDP Spoke, a contract receiving ERC-721 callbacks, or a hostile RiskModule upgrade |
| Attack approach | Pledge the same position (`positionKey`) twice through `AaveAdapter.pledge` (same market, another market, another CDP Spoke, from a second wallet after a transfer); send the NFT to the LPVault directly and trigger `onERC721Received` with forged data; re-enter `pledge` from a callback; have a hostile RiskModule approve the second pledge |
| Impact | Unbacked vault tokens supplied as collateral; borrowing against nothing |
| Expected protection | `INV-001`, `INV-005`, `INV-054`, `INV-066`: the AMM integration's LPVault takes custody from the wallet only when the AMM protocol records that wallet as the position's owner (for Uniswap v3 and Slipstream, `ownerOf(tokenId)` on the market's position manager, then `transferFrom`), so a second pledge fails because the LPVault already owns the position; Collateralization keeps at most one open record per (`integrationId`, `positionKey`) across every market, Spoke and Hub (`AlreadyPledged`); `onERC721Received` credits nothing; the Adapter mints only the `credited` units Collateralization returns for the new record, in the same call, and then requires `totalSupply ≤ totalCredited + pending.units` with the market's backing gap `totalCredited + pending.units − totalSupply` unchanged by the call (`BackingMismatch`); the Lock blocks re-entry into every member; a RiskModule approval cannot create a record (Source: Q-067, Q-092, Q-120, Q-123, Q-144, Q-148, Q-223, Q-224, Q-240, Q-257) |
| Result | Mitigated |
| Checks | QNT-01, QNT-T01, TEST-186 |

### ATTACK-003: Pledge of a third party's NFT

| Field | Value |
|---|---|
| Target | AaveAdapter, LPVault |
| Objective | Pledge a victim's NFT into the attacker's account and borrow against it |
| Affected steps | `DEP` custody and record steps |
| Prerequisites | Operator approval or `setApprovalForAll` from the victim (marketplace, phishing), or a victim's position-manager permit signature |
| Attack approach | Call `AaveAdapter.pledge` for the victim's `positionKey` as an approved operator; pass the victim's permit; name the victim's proxy |
| Impact | Theft of the victim's LP position through borrowing |
| Expected protection | `INV-005`, `INV-064`: the Adapter passes its `msg.sender` as the wallet and the LPVault's `receive` step requires the AMM protocol's owner of the position to be that wallet (`NotTokenOwner`), so an operator or `setApprovalForAll` holder cannot pledge; the depositor of record is that wallet; the Adapter resolves the proxy as `proxyOf(msg.sender, marketId)`, never from a parameter; no permit path exists (Source: Q-067, Q-075, Q-123, Q-223, Q-225) |
| Result | Mitigated |
| Checks | TEST-011 |

### ATTACK-004: Collateral from a counterfeit NFT, unapproved pool or partial range

| Field | Value |
|---|---|
| Target | Collateralization, RiskModule |
| Objective | Mint vault tokens against a fake position, a thin same-pair pool with another fee tier or tick spacing, or a position whose shape differs from the market's |
| Affected steps | `DEP` eligibility and custody steps |
| Prerequisites | Attacker-deployed ERC-721 or pool |
| Attack approach | Send a fake NFT with forged `positions()` data; pledge a position from an attacker-seeded pool; pledge a position whose range differs from the market's `[tickLower, tickUpper]` |
| Impact | Unbacked or overvalued collateral |
| Expected protection | `INV-005`: each LPVault serves one AMM protocol on one chain and holds that protocol's position manager and factory as immutables; its `validate` step derives the pool from the position through the market's factory and compares it with the vault token's immutable pool (`PoolMismatch`), and requires the position's shape to equal the market's exactly, for concentrated liquidity `tickLower == market.tickLower` and `tickUpper == market.tickUpper` (`RangeMismatch`, `ATTACK-153`); the pool is never taken from caller input (Source: Q-017, Q-054, Q-067, Q-126, Q-240, Q-363) |
| Result | Mitigated |
| Checks | None |

### ATTACK-005: Fake backing through an upgradeable market map

| Field | Value |
|---|---|
| Target | MarketRegistry, Collateralization |
| Objective | Map a worthless pool to a valuable market's vault token |
| Affected steps | `DEP` eligibility and mint steps |
| Prerequisites | Hostile MarketRegistry upgrade executed after the 5-day normal timelock delay without cancellation |
| Attack approach | The hostile registry maps the attacker's pool to the USDC/USDT market, or reports an attacker-deployed token as that market's vault token; `AaveAdapter.pledge` then asks the Adapter to mint against it; borrow |
| Impact | Borrowing against worthless collateral up to the CDP Spoke drawCap |
| Expected protection | `INV-005`, `INV-017`, `INV-066`: Collateralization accepts only a vault token bound to itself (`vaultToken.collateralization()`, else `InvalidVaultToken`) that the immutable VaultTokenFactory deployed, reads the pool only from the token's immutable `pool()` and compares the pool the AMM integration derives from the position through the market's factory with it (`PoolMismatch`); the market ID and LPOracle come from the token's immutables `marketId()` and `lpOracle()`; the proxy supplies to the Spoke reserve whose underlying is that token, so a token without an Aave reserve gives no borrowing power; a hostile MarketRegistry can neither attach a pool to another market's token nor point a pledge at another market's oracle (Source: Q-126, Q-224, Q-226, Q-228, Q-240) |
| Result | Mitigated |
| Checks | TEST-171, FINDING-070 |

### ATTACK-006: Pledged or zero-credit NFT released through the stray-NFT return

| Field | Value |
|---|---|
| Target | LPVault stray-NFT return |
| Objective | Take a pledged NFT, or a fully seized NFT that still holds the depositor's fees, through the governance return path |
| Affected steps | `MKT` stray-NFT return; `LIQ` full seizure; `WDR` zero-credit release |
| Prerequisites | Governance compromise whose `returnStray` operation passes the 5-day normal timelock delay without cancellation (the LPVault checks `msg.sender == TIMELOCK` and has no timer of its own), or a mistaken return |
| Attack approach | After a full seizure, treat the 0-credit record as closed and return the NFT (with fees and any donated liquidity) to an attacker address |
| Impact | Loss of the depositor's fees and residual liquidity |
| Expected protection | `INV-006`, `INV-007`, `INV-053`, `INV-068`: zero-credit records stay open in Collateralization and keep their custody entry in the LPVault; `returnStray(positionKey, recipient)` accepts only a position the LPVault holds with no depositor of record (`NotStray`), evaluated at execution with the Lock free, and the LPVault is immutable; the operation waits the 5-day normal delay and the governance multisig, the Emergency Guardian, the Aave Protocol Guardian or the Aave governance executor can cancel it (Source: Q-104, Q-134, Q-209, Q-226, Q-228) |
| Result | Mitigated |
| Checks | QNT-12, QNT-T14, FINDING-071 |

### ATTACK-007: Re-pledge during the release callback

| Field | Value |
|---|---|
| Target | LPVault, Collateralization, AaveAdapter |
| Objective | Re-enter `pledge` from the depositor's ERC-721 hook while a withdrawal is half-applied |
| Affected steps | `WDR` release; `DEP` custody |
| Prerequisites | Depositor is a contract |
| Attack approach | Withdraw through the Adapter; in `onERC721Received` call `AaveAdapter.pledge` with the same position before the record is closed |
| Impact | An NFT in custody with no record, or a record overwritten and its tokens unburnable |
| Expected protection | `INV-007`, `INV-054`: the withdrawal runs proxy withdraw, Adapter burn, Collateralization debit and counters, and only then `LPVault.returnPosition`, which uses `transferFrom` (no receiver hook); the Lock, held by the Adapter for the whole call, blocks re-entry into every member; every function follows checks-effects-interactions (Source: Q-119, Q-144, Q-148, Q-223, Q-224) |
| Result | Mitigated |
| Checks | TEST-209 |

### ATTACK-008: Operator rights over a pledged NFT

| Field | Value |
|---|---|
| Target | LPVault, the AMM protocol's position manager |
| Objective | Obtain approval over a pledged position and call `decreaseLiquidity`, `collect` or transfer |
| Affected steps | `DEP` custody; every later step that relies on custody |
| Prerequisites | An approval granted before pledge, a signature the LPVault could validate, or an LPVault-granted approval |
| Attack approach | Reuse a pre-pledge approval; submit a position-manager `permit` that the LPVault validates through ERC-1271; exploit a standing `setApprovalForAll` |
| Impact | Theft of pledged liquidity while vault tokens stay outstanding |
| Expected protection | `INV-007`: the Uniswap v3 and Slipstream position managers clear per-token approvals on transfer; the LPVault never calls `approve` or `setApprovalForAll` and does not implement `isValidSignature`, so `permit` against it fails; the custody logic is immutable, so this holds for the LPVault's lifetime (Source: Q-049, Q-092, Q-119, Q-144, Q-226) |
| Result | Mitigated |
| Checks | None |

### ATTACK-009: Unbacked mint through a position-modification flow

| Field | Value |
|---|---|
| Target | AaveAdapter, Collateralization |
| Objective | Mint from a caller-supplied delta in a top-up, range change, replacement or partial withdrawal |
| Affected steps | `DEP`, `WDR` |
| Prerequisites | None |
| Attack approach | Call a modification flow with an inflated amount, or move the position's liquidity read between steps |
| Impact | Unbacked vault tokens |
| Expected protection | `INV-006`, `INV-009`, `INV-066`: no modification flow exists; the reviewed Adapter mints only in `pledge`, exactly the `credited` units Collateralization returns from the position's liquidity read through the AMM integration after custody; withdrawal returns the whole position and burns exactly its credited units; the only other reductions are a liquidation debit sized by Aave and a reconcile debit; the Adapter's backing check after every pledge, release and settlement reverts on any difference (`BackingMismatch`) (Source: Q-060, Q-067, Q-075, Q-224) |
| Result | Mitigated |
| Checks | TEST-186, TEST-209 |

### ATTACK-010: Pledging into someone else's account

| Field | Value |
|---|---|
| Target | AaveAdapter, ProxyManager |
| Objective | Add collateral, possibly in a fragile market, to a victim's account to block their borrowing or liquidation |
| Affected steps | `DEP` proxy resolution |
| Prerequisites | Any NFT |
| Attack approach | Pledge naming the victim's proxy, wallet or CDP Spoke account |
| Impact | Griefing of the victim's account |
| Expected protection | `INV-005`, `INV-064`: the Adapter resolves the account as `proxyOf[msg.sender][marketId]`, creating it through the ProxyManager on the caller's first pledge to that market; no `onBehalfOf` exists, so a pledge always lands in the caller's own account; the feed never reverts or returns 0, so collateral added to an account cannot make its valuation revert (Source: Q-056, Q-067, Q-075, Q-123, Q-223, Q-225) |
| Result | Mitigated |
| Checks | TEST-190 |

### ATTACK-011: Unbacked mint through the minter's upgrade path

| Field | Value |
|---|---|
| Target | AaveAdapter (vault-token minter) |
| Objective | Mint unbacked vault tokens through the upgradeable minter |
| Affected steps | `DEP` mint |
| Prerequisites | Hostile AaveAdapter implementation executed through the timelock after the 5-day normal delay with no canceller acting |
| Attack approach | Upgrade the Adapter and call `VaultToken.mint` to a registered proxy, supply the tokens and borrow; or call `mint` from any other upgradeable contract |
| Impact | Unbacked vault tokens supplied as collateral; borrowing against them up to each CDP Spoke drawCap, with minting bounded by the Hub `addCap` of the vault-token asset |
| Expected protection | `INV-009`, `INV-018`, `INV-066`, `INV-068`: each vault token names the Adapter's proxy address as its only minter (`OnlyAdapter`), so no other upgradeable contract can mint; the only mint recipients are registered proxies of the market, and the Adapter is never a holder (`isAllowedTransfer`); an Adapter upgrade is an `APPLICATION_ADMIN` operation at the 5-day normal delay, visible in the queue and cancellable by the governance multisig, the Emergency Guardian, the Aave Protocol Guardian and the Aave governance executor; repay and debt-free withdrawal are never paused, so borrowers can leave inside the delay; minted supply is bounded by the Hub `addCap` and borrowing by each debt reserve's drawCap (Source: Q-092, Q-120, Q-223, Q-224, Q-226, Q-228) |
| Result | Accepted risk — owner: Avana governance (the reviewed Adapter implementation and its timelock) together with the cancellers; bound: the 5-day delay with cancellation, the Hub `addCap` of each vault-token asset and each CDP Spoke drawCap |
| Checks | TEST-130, TEST-195, FINDING-099 |

### ATTACK-012: Over-release of backing on withdrawal rounding

| Field | Value |
|---|---|
| Target | AaveAdapter, PositionProxy, Collateralization |
| Objective | Release more liquidity than the vault tokens returned by `Spoke.withdraw` |
| Affected steps | `WDR` Spoke withdrawal, burn and release |
| Prerequisites | Hub shares ≠ assets on the vault-token asset |
| Attack approach | Request a withdrawal whose `previewRemoveByShares` returns less than requested; repeat |
| Impact | Under-backed vault tokens |
| Expected protection | `INV-004`, `INV-010`, `INV-066`: the proxy measures the vault tokens it received and requires them to equal the requested units (`UnitsMismatch`); the Adapter burns exactly those units from the proxy; Collateralization requires them to equal the record's credited units after reconcile (`UnitsMismatch`) and returns the whole NFT; the Adapter's backing check follows; withdraw-with-debt requires Hub shares == assets in the RiskModule, and the drift checks keep them equal (Source: Q-066, Q-068, Q-075, Q-181, Q-224, Q-229) |
| Result | Mitigated |
| Checks | TEST-209 |

### ATTACK-013: Keeper-chosen record or allocation drift in multi-NFT seizure

| Field | Value |
|---|---|
| Target | Collateralization liquidation debit |
| Objective | Choose whose NFT loses liquidity, or gain a rounding unit per NFT on pro-rata allocation |
| Affected steps | `LIQ` debit |
| Prerequisites | Its own `liquidate` call, or a borrower splitting collateral into many NFTs |
| Attack approach | Pass a record list to the debit; split collateral to exploit per-record rounding |
| Impact | Under-backed tokens or unfair allocation |
| Expected protection | `INV-014`, `INV-015`: order is stored on-chain in Collateralization (largest first, ties lowest ID), walked from the top in exact units; no keeper input; all records of `(p, m)` belong to one depositor; each record loses exact integer liquidity units, so total liquidity removed equals total vault tokens burned (Source: Q-060, Q-066, Q-108, Q-119, Q-170, Q-194, Q-240) |
| Result | Mitigated |
| Checks | None |

### ATTACK-014: Unbacked vault tokens through liquidation fee shares

| Field | Value |
|---|---|
| Target | CDP Spoke vault-token reserve configuration |
| Objective | Have Aave credit part of the seized shares to its fee receiver so the borrower's NFT keeps the matching liquidity |
| Affected steps | `LIQ` liquidation call and debit |
| Prerequisites | Aave DAO sets a non-zero `liquidationFee` on a vault-token reserve |
| Attack approach | Liquidate after the fee change; the proxy's supply drop exceeds the tokens LPVaultSwap receives |
| Impact | Fee-receiver shares unbacked; the recovery floor stops covering debt |
| Expected protection | `INV-014`, `INV-029`, `INV-034`, `INV-073`: `INV-093`: the listing AIP sets `liquidationFee = 0` on every Avana collateral reserve of the standard CDP Spoke, with no alternative receiver, and the drift check trips the market's breaker on any other value (`LiquidationFeeNonZero`), stopping new activity; a fee is paid as Hub shares with no token transfer, which the vault token cannot refuse, so 0 is the only safe value whoever the receiver is; were a fee ever applied, Collateralization's seizure check reverts when the share drop differs from the tokens received and burned (fails closed); the drift check blocks new risk; the slippage bound uses the bonus net of the fee (Source: Q-068, Q-080, Q-119, Q-160, Q-190, Q-281) |
| Result | Mitigated |
| Checks | MATH-ST-12, MATH-AR-28 |

### ATTACK-015: Fee capture during partial settlement

| Field | Value |
|---|---|
| Target | LPVault liquidity removal |
| Objective | Sweep the borrower's uncollected fees into settlement proceeds |
| Affected steps | `LIQ` unwind and collect |
| Prerequisites | Its own `liquidate` call |
| Attack approach | Trigger many minimal liquidations so each `collect` takes principal and fees |
| Impact | Theft of borrower fees |
| Expected protection | `INV-033`: `LPVault.removeLiquidity` caps `collect` at the principal `decreaseLiquidity` returned; fees stay claimable by the depositor (Source: Q-009, Q-061) |
| Result | Mitigated |
| Checks | QNT-T17 |

### ATTACK-016: Liquidation or withdrawal DoS by liquidity donation

| Field | Value |
|---|---|
| Target | Collateralization backing checks |
| Objective | Break a strict `liquidity == credited` check |
| Affected steps | `LIQ` debit; `WDR` release |
| Prerequisites | A few wei of each pool token |
| Attack approach | `increaseLiquidity` on the AMM protocol's position manager for a pledged position before the keeper's or borrower's transaction |
| Impact | Blocked liquidation or withdrawal |
| Expected protection | `INV-002`, `INV-006`: checks are `≥`; donated liquidity stays with the NFT and is credited only if the record's depositor re-credits it through every top-up check (`INV-088`) (Source: Q-066, Q-067, Q-254) |
| Result | Mitigated |
| Checks | QNT-T16 |

### ATTACK-017: Cap or sizing manipulation through donated liquidity

| Field | Value |
|---|---|
| Target | RiskModule caps, liquidation sizing |
| Objective | Push a market over its cap to block others, or change a keeper's simulated outcome |
| Affected steps | `DEP` cap check; `LIQ` sizing |
| Prerequisites | Pool tokens |
| Attack approach | Donate liquidity to pledged NFTs before others' pledges or before a liquidation |
| Impact | Pledge denial or keeper mis-sizing |
| Expected protection | `INV-027`, `INV-028`: caps use the charge Collateralization booked at pledge; seizure removes credited units only (Source: Q-055, Q-060, Q-067, Q-174) |
| Result | Mitigated |
| Checks | None |

## Vault-token escape and seizure paths

### ATTACK-002: Liquidation Outside the Authorized Route

| Field | Value |
|---|---|
| Target | CDP Spoke, vault token, LPVaultSwap |
| Objective | Seize vault-token collateral by calling `Spoke.liquidationCall` directly instead of through LPVaultSwap |
| Affected steps | `LIQ` liquidation call, seizure and debit |
| Prerequisites | An account with HF < 1; the debt asset to cover debt |
| Attack approach | From an EOA or contract: approve the debt asset to the Spoke; `Spoke.liquidationCall(vaultReserve, debtReserve, proxy, debtToCover, false)`; Aave calls `Hub.remove(…, msg.sender)` and transfers vault tokens to the caller. Variants: route through any contract that is an allowed vault-token recipient; use alternate Spoke or Hub functions |
| Impact | Seized collateral detached from its NFT records; bonus captured outside LPVaultSwap's floor and debit |
| Expected protection | `INV-011`, `INV-013`: `INV-093`: the CDP Spoke is a standard Aave V4 Spoke with `receiveSharesEnabled = false` on every Avana collateral reserve, so every seizure moves vault tokens, and the vault token's transfer rule admits only Adapter mint to a registered proxy of the market, proxy to its home Hub (supply), home Hub to that proxy (withdraw), home Hub to LPVaultSwap (seizure) and Adapter burn, so any other liquidator's `liquidationCall` reverts on the token transfer; proxies have no liquidation path (their only functions are the Adapter-only supply, borrow, repay and withdraw); `liquidationCall` has no receiver parameter (Source: Q-064, Q-116, Q-120, Q-144, Q-281, Q-224, Q-281) |
| Result | Prevented by the CDP Spoke code. Launch condition — fork proof on the deployed configuration that no vault-token movement and no deficit report happens except via LPVaultSwap, and that every non-manager `liquidationCall` reverts (`INV-013` implementation test, `TEST-180`) |
| Checks | QNT-T06, TEST-109, TEST-180 |

### ATTACK-018: Vault-token transfer to an unrestricted holder

| Field | Value |
|---|---|
| Target | Vault token |
| Objective | Move vault tokens to an address outside Avana custody |
| Affected steps | Every step that moves vault tokens (`DEP`, `WDR`, `LIQ`) |
| Prerequisites | Any holder acting maliciously or with a bug, or a spender allowance |
| Attack approach | `transfer` or `transferFrom` to an arbitrary address; have the recipient set read from upgradeable configuration and change it |
| Impact | Vault tokens supplied or held outside the NFT mapping |
| Expected protection | `INV-011`: every `transfer` and `transferFrom`, zero amounts and spender transfers included, checks the (from, to) path against a set fixed by the immutable token, its immutables `hub()` and `lpVaultSwap()` and the proxies registered in the token: proxy → Hub, Hub → proxy and Hub → LPVaultSwap are the only transfers, and every other path reverts `UnauthorizedTransfer(from, to)` before any allowance is read or spent (2.4 `REQ-VTOKEN-006`, `REQ-VTOKEN-008`); no configuration contract takes part; the Adapter is neither a sender nor a recipient, and the LPVault, Collateralization and the Spoke are not recipients; only the Adapter registers proxies, and never one of the token's bindings (`REQ-VTOKEN-047`, `ATTACK-125`) (Source: Q-068, Q-120, Q-224, Q-300) |
| Result | Mitigated |
| Checks | TEST-189, PROP-055 |

### ATTACK-019: Detaching vault tokens from their NFT records

| Field | Value |
|---|---|
| Target | Vault token, PositionProxy |
| Objective | Move vault tokens from proxy A to proxy B so B borrows against collateral with no records |
| Affected steps | `WDR`, `LIQ` |
| Prerequisites | Control of a proxy's calls |
| Attack approach | Withdraw from the Spoke into proxy A and transfer to proxy B, which supplies them |
| Impact | B's debt cannot be liquidated through the Collateralization debit; A's NFT is stranded |
| Expected protection | `INV-008`, `INV-011`, `INV-016`, `INV-063`: the token refuses a proxy-to-proxy transfer, even between two registered proxies of the market (`UnauthorizedTransfer(from, to)`, 2.4 `REQ-VTOKEN-041`), and the proxy code adds a second barrier: its only state-changing function is the Adapter-only `execute(target, data)`, and the reviewed Adapter's call builder uses a fixed selector set (`REQ-PROXY-008`: `supply`, `setUsingAsCollateral`, `borrow`, `repay`, `withdraw` on the proxy's Spoke; `approve(SPOKE, x)` and `transfer` on its tokens); a Spoke `withdraw` leaves the units in the proxy and the reviewed Adapter burns exactly those units in the same call; the reviewed Adapter never has the proxy transfer vault tokens to another address; the proxy is a logic-free immutable account with no upgrade path, so its selector set is fixed at deployment; vault tokens rest only in the Hub, and in LPVaultSwap while a seizure is unsettled, between transactions (Source: Q-064, Q-068, Q-120, Q-123, Q-224, Q-225, Q-300) |
| Result | Mitigated for the reviewed Adapter; a hostile one is `ATTACK-122`, and `ATTACK-123` covers the proxy code |
| Checks | TEST-172, TEST-187, TEST-189 |

### ATTACK-020: Vault-token liquidity leaving through Hub share transfers, draws or sweep

| Field | Value |
|---|---|
| Target | Hub vault-token asset configuration |
| Objective | Move vault-token liquidity with `Hub.transferShares`, a second Spoke with `drawCap > 0`, `Hub.sweep` to a reinvestment controller, or a tokenization Spoke |
| Affected steps | `WDR`, `LIQ` (withdrawals and seizures fail with insufficient liquidity) |
| Prerequisites | Aave DAO configuration change |
| Attack approach | Register a second Spoke on the vault-token asset and draw it; set a reinvestment controller and sweep; transfer shares between Spokes |
| Impact | Vault tokens leave the Hub; withdrawals and liquidations fail; shares drift from assets |
| Expected protection | `INV-004`, `INV-029`, `INV-057`: single Spoke plus fee receiver, `drawCap = 0`, zero drawn shares, no reinvestment controller, checked at deployment and by the RiskModule's drift check on every new-account pledge and borrow; liquidation and withdraw-with-debt stop with an alarm if shares ≠ assets, because the debit check and the unit-for-unit backing hold only while one share equals one unit (Source: Q-080, Q-172, Q-181, Q-189, Q-206) |
| Result | Accepted risk — owner: Aave DAO (the configuration is DAO-owned and outside Avana's timelock); bound: the drift check blocks new risk, so exposure is limited to positions open at the change |
| Checks | None |

### ATTACK-021: Direct borrowing against shares obtained with `receiveShares`

| Field | Value |
|---|---|
| Target | CDP Spoke vault-token reserve flag |
| Objective | Hold vault-token supply shares outside a proxy and borrow any enabled debt reserve directly as one's own position manager |
| Affected steps | `LIQ` liquidation call; `BOR` |
| Prerequisites | `receiveSharesEnabled = true` on a vault-token reserve (Aave DAO change) |
| Attack approach | `Spoke.liquidationCall(…, true)` credits shares to the attacker's own Spoke position; `setUsingAsCollateral`; `Spoke.borrow` on any debt reserve |
| Impact | Borrowing against collateral that LPVaultSwap can never liquidate, and bad debt, bounded to the window from the Aave change until the drift check trips `CONFIG_DRIFT` and to the Spoke draw caps of the debt reserves; without the change the call reverts |
| Expected protection | `INV-013`, `INV-029`, `INV-093`: the CDP Spoke is a standard Aave V4 Spoke, and the listing AIP sets `receiveSharesEnabled = false` and `borrowable = false` on every vault-token reserve, so `liquidationCall(…, true)` reverts in Aave's validation (`CannotReceiveShares`) for every caller and no vault-token reserve can be borrowed; `listCollateralMarket` checks both before the market activates; the drift check reads them on every new-account pledge, borrow and withdraw-with-debt and on the keeper's per-block `pokeConfig`, and a change trips the market's `CONFIG_DRIFT` breaker (`ReceiveSharesOn`, `Borrowable`), which stops new activity and never liquidation; LPVaultSwap always passes `receiveShares = false`; the implementation check (`SpokeImplementation`) catches a Spoke upgrade. Seizures and borrows in the window before the first trip are the accepted residual of `ATTACK-155` (Source: Q-068, Q-080, Q-116, Q-144, Q-172, Q-281, Q-382) |
| Result | Mitigated by the standard-Spoke settings and the drift check; the window before the drift breaker trips is the accepted risk of `ATTACK-155`, owned by the Aave DAO |
| Checks | FINDING-060, TEST-180, TEST-181, TEST-204 |

### ATTACK-022: A borrower's proxy acting as liquidator

| Field | Value |
|---|---|
| Target | PositionProxy, ProxyManager |
| Objective | Make an allowed vault-token recipient the `msg.sender` of `liquidationCall` |
| Affected steps | `LIQ` |
| Prerequisites | A proxy |
| Attack approach | Use a generic execute or multicall on the proxy to call `liquidationCall` on another account |
| Impact | Seizure outside LPVaultSwap with tokens delivered legally to a proxy |
| Expected protection | `INV-009`, `INV-016`, `INV-063`: proxies are logic-free immutable accounts created by CREATE2, whose code nothing can change; the proxy executes only calls from the chain's AaveAdapter (`OnlyAdapter`), including against its bound wallet, and the reviewed Adapter never asks it to call `liquidationCall`, because its call builder has a fixed selector set with no `liquidationCall` (`REQ-PROXY-008`). The token's transfer rule does not stop this on its own: a registered proxy is an allowed Hub → proxy recipient for withdrawals, so a seizure paid to a registered address succeeds (`TEST-189`). The bound for a faulty Adapter is therefore any non-reserved address it registers, up to the Hub `addCap` of the vault-token asset (`INV-009`, `REQ-VTOKEN-013`), and it is the Adapter accepted risk of `ATTACK-122`, bounded by the 5-day delay with cancellation (Source: Q-064, Q-092, Q-116, Q-120, Q-281, Q-225, Q-224) |
| Result | Mitigated for the reviewed Adapter; a faulty Adapter's registrations are the accepted risk of `ATTACK-122` |
| Checks | TEST-172, TEST-187, TEST-189 |

### ATTACK-023: Hostile AaveAdapter calls `liquidationCall` as an allowed holder

| Field | Value |
|---|---|
| Target | AaveAdapter, vault token |
| Objective | Seize collateral of HF < 1 accounts into the Adapter |
| Affected steps | `LIQ` |
| Prerequisites | Hostile AaveAdapter implementation executed after the 5-day normal timelock delay without cancellation |
| Attack approach | The Adapter calls `Spoke.liquidationCall(…, false)`; the Hub would transfer vault tokens to the Adapter as the liquidator |
| Impact | Victims' positions stranded; per-proxy backing broken |
| Expected protection | `INV-009`, `INV-013`, `INV-018`, `INV-093`: a seizure on the standard CDP Spoke moves vault tokens from the Hub to the liquidator; the Adapter is a binding of the token, never a recipient (`REQ-VTOKEN-039` refuses to register it), so the Adapter's own `liquidationCall` reverts on the transfer (`TEST-189`); shares cannot be received instead because `receiveSharesEnabled = false` is a required setting watched by the drift check. The token does not stop the indirect route: a hostile Adapter can register an address it controls (any address that is not a binding) with `addValidProxy`, and that address's `liquidationCall` succeeds and receives the seized units as a registered recipient (review PoC `test_poc_hostileAdapterEoaLiquidator`, regression `test_TEST_189_registeredAddressCanReceiveSeizure`). That route, like the hostile Adapter's other custody powers (withdrawing supplied vault tokens through any proxy, burning from registered proxies and LPVaultSwap, borrowing up to drawCaps), is the accepted risk of `ATTACK-122`, bounded by the Hub `addCap`, the draw caps and the 5-day delay with cancellation (Source: Q-120, Q-223, Q-224, Q-228, Q-363) |
| Result | Mitigated for the Adapter's own `liquidationCall`; a registered address liquidating for a hostile Adapter is the accepted risk of `ATTACK-122` |
| Checks | TEST-180, TEST-189, FINDING-061 |

### ATTACK-024: Allowed-holder injection through the proxy registry

| Field | Value |
|---|---|
| Target | Vault-token proxy registry |
| Objective | Register an attacker contract as a "proxy" so it can receive, supply and borrow against vault tokens |
| Affected steps | `DEP` proxy registration; `BOR`; `LIQ` |
| Prerequisites | Hostile upgrade of an upgradeable Avana contract |
| Attack approach | Append attacker contract X to a vault token's registry with `addValidProxy`; move vault tokens to X, supply them on the Spoke as X's own collateral and borrow |
| Impact | Debt backed by no Collateralization record, which LPVaultSwap cannot settle; stranded NFTs |
| Expected protection | `INV-012`, `INV-018`: only the AaveAdapter can call `addValidProxy` (`OnlyAdapter`), the registry is append-only and every addition emits `ProxyAdded`; the reviewed Adapter registers only the ProxyManager's CREATE2 address for `(wallet, spoke)`, on that proxy's first pledge into the market; the MarketRegistry, ParameterStore, RiskModule, LPOracle and LPVaultSwap have no registry access, so a hostile upgrade of any of them registers nothing; a hostile Adapter can register any address, the accepted risk of `ATTACK-122` and `ATTACK-125`, bounded by the 5-day delay with cancellation, the Hub `addCap` and drawCaps (Source: Q-092, Q-120, Q-224, Q-225, Q-228) |
| Result | Mitigated for every upgradeable contract except the AaveAdapter; for the Adapter, accepted risk (`ATTACK-122`, `ATTACK-125`) |
| Checks | TEST-188, PROP-055, FINDING-062 |

### ATTACK-025: Hostile LPVaultSwap debits a healthy account's records

| Field | Value |
|---|---|
| Target | Collateralization seizure debit |
| Objective | Seize from small account A and release liquidity from healthy account B |
| Affected steps | `LIQ` burn, debit and release |
| Prerequisites | Hostile LPVaultSwap implementation executed after the 5-day normal timelock delay without cancellation |
| Attack approach | Liquidate A, receive n vault tokens, have the Adapter burn them with `burnSeized`, then ask Collateralization to settle a seizure of n units on B |
| Impact | B's liquidity paid out; B keeps phantom collateral |
| Expected protection | `INV-014`, `INV-018`, `INV-066`: Collateralization snapshots the named proxy's supplied shares and the token's total supply itself at `beginSeizure` under the Lock and requires, in `settleSeizure`, that the proxy's share drop, the units debited and the drop in total supply are equal (`SeizureMismatch`, `SupplyDropMismatch`); B's shares did not drop, so the call reverts; `burnSeized` burns only from LPVaultSwap's own balance, only while LPVaultSwap holds the Lock (Source: Q-125, Q-160, Q-165, Q-224, Q-240) |
| Result | Mitigated |
| Checks | QNT-T10, TEST-208, FINDING-064 |

### ATTACK-026: Hostile LPVaultSwap seizes and keeps vault tokens

| Field | Value |
|---|---|
| Target | LPVaultSwap, Collateralization |
| Objective | Seize vault tokens through `liquidationCall` and never settle, leaving the borrower's remaining NFTs unwithdrawable |
| Affected steps | `LIQ`; `WDR` of the affected account |
| Prerequisites | Hostile or buggy LPVaultSwap implementation executed after the 5-day normal timelock delay without cancellation |
| Attack approach | Liquidate an HF < 1 account with the attacker's own debt asset; keep the seized tokens; the proxy's Spoke supply falls below its credited records, so a later withdrawal of the remaining NFT cannot burn its full credited units |
| Impact | Seizure of HF < 1 accounts during the hostile version's lifetime, including on stale prices; the seized vault tokens stay outstanding. The borrower's remaining NFT is not stranded |
| Expected protection | `INV-001`, `INV-008`, `INV-018`, `INV-045`, `INV-058`: reconcile on exit — when the proxy's Spoke supply in a market is below its credited units, Collateralization treats the missing units as seized on the borrower's next withdrawal or a liquidation settlement, debits them from the records in list order from the head, has the LPVault remove the matching liquidity into a pending-settlement balance that keeps the outstanding vault tokens backed, and releases the rest of the NFT; a later honest LPVaultSwap has the Adapter burn the vault tokens it holds (`burnSeized`) and calls `Collateralization.settlePending`, swaps the released pool tokens into the market's pending-settlement asset and funds the Coverage Spoke of the market's (Hub, that asset) with all of it (2.11 `REQ-SWAP-066`), so the reserve absorbs the incident's losses and no party profits from it; LPVaultSwap upgrades wait the 5-day normal delay and any canceller can stop them (Source: Q-090, Q-092, Q-125, Q-160, Q-201, Q-211, Q-224, Q-228, Q-236) |
| Result | Mitigated |
| Checks | QNT-07, QNT-15, QNT-22, QNT-T09 (Quint counterexample C-QNT-1, closed by Q-201), TEST-150, TEST-151, TEST-152, TEST-153, TEST-154, TEST-170, FINDING-041 |

### ATTACK-027: Asset extraction through rescue or sweep functions

| Field | Value |
|---|---|
| Target | Every Avana contract; the AaveAdapter's `burn(from)` authority |
| Objective | Use a rescue function to move vault tokens or debt assets in flight or pledged positions, or destroy vault tokens through the Adapter's burn |
| Affected steps | All |
| Prerequisites | Rescue role or hostile upgrade |
| Attack approach | Call a sweep naming the vault token or a pledged position; with a hostile Adapter, try `vaultToken.burn(Hub, amount)` or burn a victim proxy's in-flight tokens |
| Impact | Theft of collateral or settlement funds; burning a registered proxy's in-flight units or LPVaultSwap's unsettled units would destroy units that back Aave shares or pending settlement |
| Expected protection | `INV-003`, `INV-010`, `INV-018`, `INV-053`: no generic rescue or sweep exists; the only return path is the LPVault's timelock-only `returnStray(positionKey, recipient)` for a position with no depositor of record, evaluated at execution with the Lock free (`NotStray` otherwise), identified by record, never by balance arithmetic; no Avana contract holds a settlement fund to sweep (the SettlementBudget is removed, `Q-397`); `burn(from, amount)` accepts only the Adapter and only `from` a registered proxy or LPVaultSwap, so a burn from the Hub reverts for every Adapter implementation (`REQ-VTOKEN-006`); the reviewed Adapter burns only on withdrawal (from the proxy, exactly the released credited units), on seizure (`burnSeized`, from LPVaultSwap) and on pending settlement; a hostile Adapter that burns a proxy's in-flight units or LPVaultSwap's balance destroys backing but cannot move any position, which returns only to its depositor of record — the accepted risk of `ATTACK-124`, bounded by the 5-day delay with cancellation (Source: Q-104, Q-124, Q-224, Q-226, Q-228, Q-397) |
| Result | Mitigated for rescue and sweep paths; the Adapter burn path is the accepted risk of `ATTACK-124` |
| Checks | TEST-208, FINDING-099 |

### ATTACK-028: Zero-collateral third-party liquidation

| Field | Value |
|---|---|
| Target | CDP Spoke, indexer |
| Objective | Call `liquidationCall` with a `debtToCover` so small that 0 vault-token shares are seized, so the call completes outside LPVaultSwap |
| Affected steps | `LIQ` |
| Prerequisites | An HF < 1 account; a few wei of any enabled debt asset |
| Attack approach | `Spoke.liquidationCall(vaultReserve, debtReserve, proxy, tiny, false)` for any reserve in the Spoke's enabled debt set; Aave rounds the seized collateral down to 0 shares and skips the Hub transfer |
| Impact | None to the borrower or the protocol: the call completes, because no token moves and the vault token has nothing to refuse; it repays part of the borrower's debt at the caller's expense, seizes nothing, leaves the account's collateral and Collateralization's records unchanged, reports no deficit, emits a `LiquidationCall` whose liquidator is not LPVaultSwap and refreshes the account's risk premium |
| Expected protection | `INV-013`, `INV-041`, `INV-093`: on the standard CDP Spoke any seizure of at least one share must move vault tokens to the liquidator, which the vault token admits only for LPVaultSwap, so the dust call is the only third-party liquidation that completes and it takes nothing; monitors and Collateralization never treat a `LiquidationCall` as LPVaultSwap's by its event alone (`REQ-VTOKEN-025`); inside LPVaultSwap the debt reserve must be in the Spoke's approved set (`UnknownDebtReserve`) and a call that seizes 0 units reverts with `NothingSeized` (`ATTACK-066`) (Source: Q-144, Q-281, Q-300) |
| Result | Mitigated: the call completes but transfers value only from the caller to the borrower |
| Checks | QNT-T07, FINDING-063, TEST-180, TEST-189 |

## Proxies, Adapter, RiskModule and approvals

### ATTACK-029: PositionProxy pre-deployment or initialization front-run

| Field | Value |
|---|---|
| Target | ProxyManager, PositionProxy |
| Objective | Own a victim's deterministic proxy before their first pledge |
| Affected steps | `DEP` proxy creation |
| Prerequisites | Knowledge of the victim's wallet and the CDP Spoke |
| Attack approach | Deploy code at the victim's predicted proxy address first, or front-run a separate `initialize` |
| Impact | Victim's collateral lands in an attacker-controlled account |
| Expected protection | `INV-063`, `INV-064`: only the Adapter can call `ProxyManager.deployProxy`, and the ProxyManager creates the immutable proxy with CREATE2 from its own address, salt `keccak256(abi.encode(wallet, spoke, marketId))` and constant init code that binds the wallet, Spoke and market in the constructor, so nobody else can place code at the address and there is no initialization to front-run; a deployment for another `(wallet, spoke, market)` binds that triple and never changes (Source: Q-092, Q-107, Q-123, Q-225) |
| Result | Mitigated |
| Checks | TEST-190 |

### ATTACK-030: Bypassing gates through proxy self-management

| Field | Value |
|---|---|
| Target | PositionProxy, CDP Spoke position managers |
| Objective | Borrow or withdraw on the proxy's account without the Adapter's and RiskModule's checks |
| Affected steps | `BOR`, `WDR` |
| Prerequisites | A phished signature, an active stock position manager, or a proxy ERC-1271 path |
| Attack approach | `setUserPositionManagersWithSig` with a signature validated through ERC-1271 on the proxy; use an Aave position manager activated on the Spoke |
| Impact | Borrowing outside the HF floors, price-state and nonce checks |
| Expected protection | `INV-016`, `INV-063`: the immutable proxy has no ERC-1271 and no manager-approval function, and its selector set is fixed at deployment; no position manager is activated on Avana accounts (Source: Q-064, Q-120, Q-225) |
| Result | Mitigated |
| Checks | TEST-172 |

### ATTACK-031: Settlement authority used against healthy accounts

| Field | Value |
|---|---|
| Target | LPVaultSwap |
| Objective | Use a position-manager role over every proxy to withdraw or borrow from healthy accounts |
| Affected steps | `LIQ` |
| Prerequisites | Hostile LPVaultSwap |
| Attack approach | Call `Spoke.withdraw` or `Spoke.borrow` for a proxy as its manager |
| Impact | Theft from healthy accounts |
| Expected protection | `INV-016`: LPVaultSwap is not a position manager and cannot call a proxy (`OnlyAdapter`); it acts only through `liquidationCall` (Source: Q-060, Q-064, Q-116, Q-223) |
| Result | Mitigated |
| Checks | None |

### ATTACK-032: Credit-line drain through a malicious AaveAdapter or proxy upgrade

| Field | Value |
|---|---|
| Target | AaveAdapter, PositionProxy |
| Objective | Borrow every debt reserve from every account to the attacker in one block |
| Affected steps | `BOR` |
| Prerequisites | Hostile AaveAdapter implementation executed after the 5-day normal timelock delay without cancellation |
| Attack approach | The hostile Adapter calls `proxy.borrow(debtReserveId, amount, attacker)` for every proxy and every debt reserve; any other upgradeable contract tries the same; a proxy cannot be given new code, because it has no upgrade path |
| Impact | Every debt reserve's credit line drained up to each CDP Spoke drawCap |
| Expected protection | `INV-018`, `INV-057`, `INV-063`, `INV-065`, `INV-068`: the RiskModule, MarketRegistry, ParameterStore, LPOracle and LPVaultSwap cannot call a proxy (`OnlyAdapter`); Adapter upgrades are `APPLICATION_ADMIN` operations at the 5-day normal delay, visible in the queue and cancellable by the governance multisig, the Emergency Guardian, the Aave Protocol Guardian and the Aave governance executor; repay and debt-free withdrawal are never paused, so borrowers can leave inside the delay; the drawCap of each debt reserve bounds what can be drawn (Source: Q-092, Q-093, Q-126, Q-223, Q-225, Q-226, Q-228) |
| Result | Accepted risk — owner: Avana governance (the reviewed Adapter implementation) together with the cancellers; bound: the 5-day delay with cancellation and each debt reserve's drawCap |
| Checks | TEST-130, TEST-195, TEST-210, FINDING-099, FINDING-100 |

### ATTACK-033: Re-pointing proxies or the LPVault through configuration

| Field | Value |
|---|---|
| Target | MarketRegistry, ParameterStore, PositionProxy, Collateralization |
| Objective | Point a market's or debt reserve's Spoke, reserve, Hub or asset at an attacker contract |
| Affected steps | `REP`, `WDR`, `DEP` |
| Prerequisites | Hostile MarketRegistry or ParameterStore upgrade executed after the 5-day normal timelock delay |
| Attack approach | A payer repays through the Adapter; the hostile registry reports an attacker "Spoke" or asset for the debt reserve, so the payer's funds are approved to the attacker |
| Impact | Every repay in flight up to each payer's `maxRepaySpend` |
| Expected protection | `INV-017`: each proxy's CDP Spoke is bound at creation and never changes, and the proxy approves only that Spoke, for the exact amount, resetting to 0; the debt reserve must be in the Spoke's own immutable `APPROVED_DEBT_RESERVES`, and the asset the Adapter pulls is the reserve's underlying as the Spoke reports it; market identity comes from vault-token immutables; a hostile MarketRegistry can mark reserves approved or not and change gates, but cannot redirect funds (Source: Q-092, Q-126, Q-223, Q-225, Q-281) |
| Result | Mitigated |
| Checks | TEST-171, FINDING-066 |

### ATTACK-034: Hostile RiskModule approves risky borrowing or withdrawal

| Field | Value |
|---|---|
| Target | RiskModule, AaveAdapter |
| Objective | Borrow, or withdraw with debt, in Drifting or frozen markets, with stale collateral or debt prices, during a liquidation halt or below a market's `hardHealthFloor` where one is set |
| Affected steps | `BOR`, `WDR` |
| Prerequisites | Hostile RiskModule implementation executed after the 5-day normal timelock delay without cancellation |
| Attack approach | The RiskModule passes every `preBorrowCheck`, `preWithdrawCheck` and `postHealthCheck`; a borrower who knows a token depegged borrows against the served price |
| Impact | Overvalued borrowing down to Aave HF 1, bounded by each debt reserve's drawCap |
| Expected protection | `INV-018`, `INV-019`, `INV-025`, `INV-057`, `INV-068`: the reviewed Adapter keeps the deadline, the per-proxy nonce, the receiver rules and the resolution of the proxy from the caller whatever the RiskModule returns; Aave itself enforces HF ≥ 1, the borrowed reserve's active, frozen and paused flags, and the drawCap; the RiskModule upgrade waits the 5-day normal delay, visible and cancellable by any canceller; the RiskModule takes no part in repay, fee collection, debt-free withdrawal or liquidation (Source: Q-092, Q-126, Q-161, Q-182, Q-226, Q-228, Q-229) |
| Result | Accepted risk — owner: Avana governance (the reviewed RiskModule implementation) together with the cancellers; bound: Aave HF ≥ 1, each debt reserve's drawCap and the 5-day delay with cancellation |
| Checks | TEST-155, TEST-156, FINDING-017, FINDING-043, FINDING-065 |

### ATTACK-035: Hostile RiskModule or Adapter blocks repay or exits

| Field | Value |
|---|---|
| Target | RiskModule, AaveAdapter, MarketRegistry pause state |
| Objective | Veto repay, fee collection, debt-free withdrawal or liquidation so accounts drift into liquidation or bad debt |
| Affected steps | `REP`, `FEE`, `WDR`, `LIQ` |
| Prerequisites | Hostile RiskModule, MarketRegistry or AaveAdapter upgrade; or a guardian setting Paused |
| Attack approach | Make every RiskModule call fail, including any exit-counter path; set the application state to Paused; with a hostile Adapter, revert repay, withdraw and `burnSeized` |
| Impact | Borrowers lose the bonus; exits frozen |
| Expected protection | `INV-027`, `INV-043`, `INV-044`, `INV-045`, `INV-046`, `INV-067`: repay and debt-free withdrawal call no RiskModule function and never read the pause state; fee collection is a direct call on the immutable LPVault and zero-credit release a direct call on immutable Collateralization; exit counters live in Collateralization; liquidation calls no RiskModule function and never reads the pause state, so Paused stops neither; a hostile Adapter can block repay, withdrawal and the seizure burn, the accepted risk of `ATTACK-122`, bounded by the 5-day delay with cancellation (Source: Q-122, Q-158, Q-223, Q-227, Q-229) |
| Result | Mitigated for the RiskModule, MarketRegistry, ParameterStore and every pause state; for a hostile Adapter, accepted risk (`ATTACK-122`) — owner: Avana governance with the cancellers; bound: the 5-day delay with cancellation |
| Checks | TEST-192, TEST-193, FINDING-067, FINDING-088 |

### ATTACK-036: Borrow-nonce replay or griefing

| Field | Value |
|---|---|
| Target | AaveAdapter, PositionProxy |
| Objective | Replay a borrow or burn a victim's nonce |
| Affected steps | `BOR` |
| Prerequisites | A copy of a past borrow call |
| Attack approach | Resubmit the call; call the Adapter naming another user's account; call another user's proxy directly |
| Impact | Duplicate debt |
| Expected protection | `INV-019`, `INV-063`: the Adapter resolves the proxy from `msg.sender` and the CDP Spoke, so a call acts only on the caller's own account; `borrowNonce[proxy]` must equal `expectedNonce` (`BadNonce`) and is incremented before `Spoke.borrow`; a reverted borrow rolls it back; the proxy accepts calls only from the Adapter (Source: Q-093, Q-106, Q-223, Q-229) |
| Result | Mitigated |
| Checks | QNT-T02, TEST-027 |

### ATTACK-037: Compromised Convex rewrites a pending borrow intent

| Field | Value |
|---|---|
| Target | Convex intent storage, web app |
| Objective | Change the receiver or amount of an intent another tab resumes |
| Affected steps | `BOR` preparation (off-chain) |
| Prerequisites | Convex compromise |
| Attack approach | Edit stored intents; the user's other tab resumes and signs |
| Impact | Borrowed assets sent to the attacker |
| Expected protection | Convex stores only intent ID and status; the browser rebuilds calldata from the user's inputs and the bundled manifest; the wallet shows receiver and amount (Source: Q-073, Q-149) |
| Result | Mitigated |
| Checks | FINDING-068 |

### ATTACK-038: Draining wallets through approvals to upgradeable contracts

| Field | Value |
|---|---|
| Target | Users' token approvals |
| Objective | Use a standing debt-asset or NFT allowance after a hostile upgrade |
| Affected steps | `REP`, `DEP` |
| Prerequisites | Wallets that left a standing allowance to the AaveAdapter (repay) or a per-token NFT approval to the LPVault; hostile Adapter upgrade executed after the 5-day normal timelock delay |
| Attack approach | The hostile Adapter calls `transferFrom` on each approving wallet, or pledges an approved NFT |
| Impact | Wallet balances up to each standing allowance; an approved NFT pledged into its owner's own account |
| Expected protection | `INV-022`: the app requests an exact-amount debt-asset approval to the AaveAdapter for each repay, consumed in the same flow, and a per-position approval (for Uniswap v3 and Slipstream, a per-tokenId NFT approval) to the AMM protocol's immutable LPVault, never `setApprovalForAll`; the reviewed Adapter pulls only from its `msg.sender`; an NFT pledged by a hostile Adapter still lands in its owner's own account and returns only to its depositor of record; Adapter upgrades wait the 5-day normal delay and any canceller can stop them (Source: Q-093, Q-123, Q-144, Q-212, Q-223, Q-228) |
| Result | Accepted risk — owner: Avana governance with the cancellers, and users who leave allowances standing; bound: exact-amount approvals leave nothing to spend, and the 5-day delay with cancellation |
| Checks | TEST-147, FINDING-069 |

### ATTACK-039: Third-party refresh of a victim's dynamic configuration

| Field | Value |
|---|---|
| Target | CDP Spoke user configuration |
| Objective | Force a collateral-factor or risk-premium refresh on a victim's account |
| Affected steps | `EMG` collateral-factor changes |
| Prerequisites | None |
| Attack approach | Call `updateUserDynamicConfig` or `updateUserRiskPremium` for the proxy |
| Impact | Victim moved to a worse configuration key at the attacker's chosen time |
| Expected protection | The Spoke restricts both to position managers or a DAO role; no Avana third-party refresh exists; only the DAO's position-updater role refreshes accounts (Source: Q-110, Q-145) |
| Result | Mitigated |
| Checks | None |

## Oracle and price states

### ATTACK-040: Flash-loan manipulation of the vault-token price

| Field | Value |
|---|---|
| Target | LPOracle |
| Objective | Raise the reported vault-token value within one transaction |
| Affected steps | `BOR`, `LIQ` (price reads) |
| Prerequisites | Flash loan |
| Attack approach | Move the pool's spot price before a borrow |
| Impact | Overvalued borrowing |
| Expected protection | `INV-055`: the price uses only Chainlink-validated prices; no `slot0`, `observe`, reserve or position read in the price path for Uniswap v3 and Slipstream markets; the price is the fair composition `value = Σ amountᵢ × priceᵢ` of one unit of the market's exact range at the oracle price vector, with the oracle ratio clamped to the range (`INV-078`), so a spot move does not change it; and pool reads appear only in Avana's gates (TWAP guard, pool-share cap), never in the price Aave reads (Source: Q-028, Q-079, Q-085, Q-128, Q-363) |
| Result | Mitigated |
| Checks | None |

### ATTACK-041: Market freeze by TWAP manipulation

| Field | Value |
|---|---|
| Target | LPOracle TWAP guard |
| Objective | Push the pool TWAP outside the consistency tolerance (`consistencyToleranceBps`) to put a market in Drifting |
| Affected steps | `BOR`, `WDR`, `DEP` gates |
| Prerequisites | Capital to move a listed pool over the TWAP window; builder control for multi-block moves |
| Attack approach | Push the mean tick with outlier blocks |
| Impact | New-account pledges, new borrowing and withdraw-with-debt blocked in that market; repay, fees, debt-free withdrawal, top-ups and liquidation continue |
| Expected protection | `INV-024`, `INV-043`, `INV-045`, `INV-046`: Drifting only stops new risk; listing requires a manipulation-cost study and minimum depth (Source: Q-113, Q-128, Q-132) |
| Result | Launch condition — per-pool manipulation-cost study and TWAP backtest accepted before listing |
| Checks | None |

### ATTACK-042: Grace-latch abuse with a gas-starved `poke()`

| Field | Value |
|---|---|
| Target | LPOracle grace latch |
| Objective | Record a fake outage so the grace window keeps accounts between `graceHealthFactor` and 1 unliquidatable, repeatedly |
| Affected steps | `LIQ` grace check; `EMG` price-state handling |
| Prerequisites | Gas to call `poke()` |
| Attack approach | Call `poke()` with a gas limit that makes both Chainlink reads fail inside `try`, so the caught error maps to Expired and the next good read restarts grace |
| Impact | Liquidation shield for as long as the attacker pays gas |
| Expected protection | `INV-031`: Expired is flagged only from successfully read source timestamps; `poke()` reverts below `pokeMinGas`; `recoveredAt` is the first fresh round's timestamp; one grace window per outage; price state is computed fresh in each call, and the latch is written only by `poke()` and Avana calls that observe Expired (Source: Q-129, Q-154) |
| Result | Mitigated |
| Checks | QNT-T12, HYP-37, FINDING-077 |

### ATTACK-043: Withdrawal lock-in through forced Drifting

| Field | Value |
|---|---|
| Target | AaveAdapter withdrawal path |
| Objective | Trap debt-free LPs' NFTs by forcing Drifting |
| Affected steps | `WDR` |
| Prerequisites | As `ATTACK-041` |
| Attack approach | Hold a market in Drifting during volatility |
| Impact | LPs cannot manage their positions |
| Expected protection | `INV-045`, `INV-067`: an account with zero debt on every debt reserve withdraws through the Adapter without any RiskModule call, price-state read or pause-state read, so debt-free withdrawal works in every price state and every pause state; the Adapter resolves the proxy from the caller, so nobody else can start or block it (Source: Q-029, Q-056, Q-118, Q-122, Q-223, Q-227, Q-234) |
| Result | Mitigated |
| Checks | None |

### ATTACK-044: Borrowing against a lagging feed

| Field | Value |
|---|---|
| Target | LPOracle, RiskModule, listing parameters |
| Objective | Mint LP, pledge and borrow the maximum before Chainlink reports a depeg, optionally steering the TWAP toward the stale feed so the market stays Live; or borrow a non-GHO debt asset whose feed lags a fall in its price |
| Affected steps | `DEP`, `BOR` |
| Prerequisites | A depeg or debt-asset move inside the feed's deviation threshold or heartbeat; flash loan |
| Attack approach | In one transaction: mint a position in the market's range, pledge through the Adapter, borrow at the stale price, sell the borrowed asset |
| Impact | Overvalued debt |
| Expected protection | `INV-023`, `INV-024`, `INV-072`: listing requires (1 − CF) above the feed deviation threshold plus heartbeat drift; the RiskModule's `preBorrowCheck` requires every collateral feed and every non-GHO debt reserve's DebtOracle of the account Live within `borrowPriceMaxAge` (`PriceTooOld`, `DebtPriceTooOld`); faster Chainlink routes required where available; a non-GHO debt reserve is listed only with its DebtOracle as the AaveOracle source; no pledge-to-borrow delay is needed because the listing margin covers feed lag (Source: Q-113, Q-182, Q-229, Q-233, Q-238, Q-248) |
| Result | Launch condition — per-market margin check `(1 − CF)` against deviation and heartbeat drift, and the faster-route requirement, accepted at listing; each non-GHO debt reserve's feed accepted at its listing |
| Checks | TEST-201 |

### ATTACK-045: Self-protection from liquidation through TWAP manipulation

| Field | Value |
|---|---|
| Target | LPVaultSwap price gates |
| Objective | Keep keepers out by holding a pool's TWAP away from the oracle |
| Affected steps | `LIQ` |
| Prerequisites | Capital to hold a deep pool off-price |
| Attack approach | Push the TWAP of one of the account's markets during the liquidation window |
| Impact | Unliquidated debt grows |
| Expected protection | `INV-030`, `INV-034`: TWAP disagreement does not block liquidation while the Chainlink inputs of the seized market and of the repaid debt reserve are fresh and agree; the account's other reserves are not gated and count at their served prices, which can only lower HF; no spot check on the unwind, and each conversion leg's minimum comes from oracle prices, never from the pool spot (Source: Q-085, Q-128, Q-131, Q-195, Q-234, Q-247, Q-250) |
| Result | Mitigated |
| Checks | None |

### ATTACK-046: Profitable liquidation at a stale cached price

| Field | Value |
|---|---|
| Target | LPVaultSwap |
| Objective | Liquidate healthy accounts at a stale price that understates collateral or overstates debt |
| Affected steps | `LIQ` |
| Prerequisites | Any address that calls `liquidate`; Chainlink outage on a collateral or debt feed |
| Attack approach | Liquidate while a collateral market is Cached, or while a debt feed is stale |
| Impact | Healthy borrowers lose the bonus |
| Expected protection | `INV-030`, `INV-072`, `INV-075`, `INV-087`: LPVaultSwap seizes no collateral from a market that is Cached, Expired, disagreeing or older than `liquidationPriceMaxAge` (`StalePrice`), and repays no non-GHO debt reserve whose DebtOracle is not Live within `liquidationPriceMaxAge` (`DebtPriceStale`); the gate covers the seized market and the repaid reserve only. The account's other reserves count at served prices: a Cached market at its last accepted price, an Expired market at 1 (0.00000001 USD), a disagreeing market at the lower route, a stale debt asset at `⌈accepted × (10⁴ + debtStressRiseBps) / 10⁴⌉`. These stress prices can only lower HF and are never used to size a seizure or a repayment, and a Cached market keeps its accepted price, so one late heartbeat cannot push healthy accounts below 1. Example: USDC debt accepted at $0.9999 with `debtStressRiseBps` 500 is served at $1.04990 once Expired; the account's fresh GHO debt and fresh collateral market stay liquidatable, while its USDC debt waits for a fresh price (Source: Q-128, Q-182, Q-234, Q-238, Q-247, Q-248) |
| Result | Mitigated |
| Checks | TEST-201, TEST-226, TEST-230 |

### ATTACK-047: Liquidation shield through degraded-market collateral

| Field | Value |
|---|---|
| Target | LPOracle, RiskModule pledge gate, debt-reserve feeds |
| Objective | Make a large account unliquidatable by adding collateral in a market whose price reverts or is Expired, or by holding a debt reserve whose feed goes stale |
| Affected steps | `DEP` top-up; `BOR`; `LIQ` |
| Prerequisites | A second market in Cached or Expired, a price feed that can be made to revert, or a debt reserve whose feed stalls |
| Attack approach | As the main market deteriorates, top up a minimum NFT into the degraded market; or borrow a small amount of a debt asset whose feed stalls more often; Aave's account valuation reverts, or the per-account staleness rule blocks liquidation of every market |
| Impact | None for fresh reserves: a degraded market or stale debt feed no longer blocks liquidation of the account's other reserves; only the degraded reserve's own seizure or repayment waits |
| Expected protection | `INV-026`, `INV-055`, `INV-069`, `INV-072`, `INV-075`, `INV-087`: the feed never reverts and never returns 0; top-ups only into Live or Drifting markets, each at least `minPledgeUsd` ($10); borrowing a debt reserve requires its feed within `borrowPriceMaxAge` at that time; liquidation gates only the seized market and the repaid reserve, and values the degraded market at 1 once Expired (or at its lower route while disagreeing) and the stale debt at its stress price, so the degraded reserve lowers HF instead of shielding the account; keepers seize the fresh market and repay the fresh debt (Source: Q-056, Q-128, Q-132, Q-230, Q-234, Q-238, Q-247) |
| Result | Mitigated |
| Checks | TEST-201, TEST-226, TEST-230, FINDING-076, FINDING-101 |

### ATTACK-048: Pre-positioned collateral in a stale-prone market

| Field | Value |
|---|---|
| Target | Per-account staleness rule |
| Objective | Hold a small NFT, pledged while the market was Live, in a market whose feed goes stale more often, or a small debt in a reserve whose feed goes stale more often, so the whole account cannot be liquidated during that feed's outages |
| Affected steps | `LIQ` |
| Prerequisites | Two listed markets, or two debt reserves, with different feed reliability |
| Attack approach | Pledge a minimum position in the fragile market early, or borrow a little of the fragile debt asset; wait for its feed to go stale during a drop in the main market |
| Impact | Only the fragile market's seizure, or the fragile debt's repayment, waits for its feed; the account's fresh reserves stay liquidatable at stress valuation |
| Expected protection | `INV-030`, `INV-072`, `INV-075`, `INV-087`: liquidation is gated by the seized market and the repaid reserve only, so the fragile reserve cannot hold back the rest of the account, and while stale it counts against the borrower (collateral at 1 from Expired, debt at its stress price); the Emergency Guardian can switch the failing route to its reviewed standby at once, and the DebtOracle fails over between its primary and alternate routes; caps are sized with the pause-loss bound over the 48-hour incident window, including a debt-asset price-rise term; every feed counts as fresh only while its age is at most its own heartbeat plus `heartbeatMargin` (2.10 `SPEC-ORC-019`; 84,600 s for Ethereum USDC/USD, 5,400 s for ETH/USD), and a feed that stops while still inside that age is caught by the primary-versus-alternate agreement check (Source: Q-128, Q-182, Q-192, Q-234, Q-238, Q-247, Q-248, Q-274, Q-364) |
| Result | Accepted risk — owner: Aave V4 risk service providers and Avana Labs (feed choice at listing, standby routes, the guardian standby switch); bound: an account whose only collateral or only debt sits in the stale reserve waits for a fresh price or the standby switch, within the 48-hour incident window the caps are sized for (`Q-192`) |
| Checks | TEST-226, TEST-230, TEST-231, FINDING-094, FINDING-101 |

### ATTACK-049: Price-source substitution through governance

| Field | Value |
|---|---|
| Target | LPOracle feeds and debt-reserve price sources (Avana), Spoke price source (Aave DAO) |
| Objective | Point a market or a debt reserve at a source that values it arbitrarily |
| Affected steps | `MKT` |
| Prerequisites | Governance compromise on either side |
| Attack approach | Change a feed definition in the ParameterStore, a debt reserve's recorded price source in the MarketRegistry, or the LPOracle implementation; or call `Spoke.updateReservePriceSource` |
| Impact | Credit-line exploit |
| Expected protection | `INV-029`, `INV-051`, `INV-068`: every Avana feed, price-source and LPOracle change is an `APPLICATION_ADMIN` operation at the 5-day normal delay, cancellable by the governance multisig, the Emergency Guardian, the Aave Protocol Guardian and the Aave governance executor; the RiskModule's drift check compares the Spoke oracle's source for every vault-token reserve and every debt reserve with the recorded one on every new-account pledge and borrow (`ConfigDrift`), so an Aave-side change closes new risk; fork reruns of the oracle checks follow every change (Source: Q-080, Q-091, Q-172, Q-228, Q-238) |
| Result | Accepted risk — owner: Aave DAO for Spoke price-source changes outside Avana's timelock; bound: the drift check blocks new pledges and borrows while the Spoke's price source differs from the recorded one |
| Checks | None |

### ATTACK-050: Borrowing against an Expired price through another market

| Field | Value |
|---|---|
| Target | RiskModule borrow gate |
| Objective | Borrow while Aave values another of the account's markets at a stale Expired price, or while another debt reserve of the account has a stale feed |
| Affected steps | `BOR`, `WDR` |
| Prerequisites | Account with collateral in an Expired market or debt in a reserve with a stale feed |
| Attack approach | Call `AaveAdapter.borrow` for a reserve whose own price is fresh |
| Impact | Overvalued borrowing |
| Expected protection | `INV-023`, `INV-024`, `INV-072`: the RiskModule's `preBorrowCheck` and `preWithdrawCheck` poke and check every collateral market of the account (Live only) and every debt reserve of the account plus the reserve being borrowed (fresh feed, not paused); the most restrictive state among them wins (Source: Q-081, Q-128, Q-229, Q-234, Q-238) |
| Result | Mitigated |
| Checks | TEST-201 |

### ATTACK-051: Common-mode feed error passes the agreement and TWAP checks

| Field | Value |
|---|---|
| Target | LPOracle |
| Objective | Exploit an error shared by both coins' routes (a shared intermediate feed) that leaves the price ratio intact and overvalues the LP |
| Affected steps | `BOR` |
| Prerequisites | A faulty shared feed |
| Attack approach | Borrow while both legs read high by the same factor |
| Impact | Unbounded overvaluation |
| Expected protection | `INV-024`, `INV-055`: backup routes of the two coins share no intermediate feed (listing rule); LP USD level outside `usdBandLow`/`usdBandHigh` blocks borrowing and withdraw-with-debt; pledges stay open and liquidation continues while both routes are fresh and agree; stable legs capped at `stableCeilingUsd` (Source: Q-176, Q-177, Q-195, Q-206) |
| Result | Launch condition — listing check that the two coins' routes share no intermediate feed |
| Checks | MATH-UO-22, MATH-UO-23 |

### ATTACK-052: GHO above peg forces GHO markets into Drifting

| Field | Value |
|---|---|
| Target | LPOracle TWAP guard |
| Objective | Stop pledges and borrows in every GHO market by keeping GHO above $1 |
| Affected steps | `DEP`, `BOR` |
| Prerequisites | Capital to hold a GHO premium beyond the TWAP tolerance |
| Attack approach | Buy GHO; the guard compares the pool with the capped GHO price and disagrees |
| Impact | GHO markets closed to new risk |
| Expected protection | `INV-056`: freshness, agreement and TWAP checks use uncapped quotes; the ceiling applies to valuation only; the GHO/USD quote in the TWAP guard and agreement checks is uncapped, so GHO markets stay Live above peg (Source: Q-177, Q-200) |
| Result | Mitigated |
| Checks | HYP-51, MATH-UO-20 |

### ATTACK-053: Liquidation at a disputed price while feeds disagree

| Field | Value |
|---|---|
| Target | LPOracle, LPVaultSwap |
| Objective | Liquidate healthy accounts while a malfunctioning primary feed shows a depeg the alternate route does not |
| Affected steps | `LIQ` |
| Prerequisites | Any address that calls `liquidate`; a feed fault |
| Attack approach | Liquidate while both routes are fresh but disagree beyond `feedAgreementToleranceBps` |
| Impact | Healthy accounts lose the bonus |
| Expected protection | `INV-030`, `INV-059`: liquidation of every account holding that market pauses while the routes are fresh but disagree; the pause starts at the first disagreement stored by `poke()` or any successful Avana call, and keepers poke every heartbeat; after `disagreementPauseMax` the market is treated as Expired for liquidation until the routes agree again or governance approves a fix, so a persistent fault never resumes liquidation at a disputed price; repay and debt-free withdrawal stay open; borrowing stays blocked (Source: Q-162, Q-183, Q-199, Q-208) |
| Result | Mitigated |
| Checks | QNT-T18, HYP-56, TEST-157, TEST-159, FINDING-089 |

### ATTACK-054: Agreement tolerance admits an extra basis point

| Field | Value |
|---|---|
| Target | LPOracle agreement check |
| Objective | Pass the agreement check with a difference above `feedAgreementToleranceBps` |
| Affected steps | `BOR`, `LIQ` |
| Prerequisites | A feed difference just above tolerance |
| Attack approach | Rely on floor division in `\|p − b\| × 1e4 / min(p, b)` |
| Impact | A disagreeing market treated as agreeing |
| Expected protection | Cross-multiplied form `\|p − b\| × 1e4 ≤ T × min(p, b)` (Source: Q-184) |
| Result | Mitigated |
| Checks | MATH-UO-24 |

### ATTACK-055: Oracle rounding and normalisation edge cases

| Field | Value |
|---|---|
| Target | LPOracle math (LPPriceMath) |
| Objective | Obtain an overvalued or zero price from rounding: a feed with more than 8 decimals normalising to 0, perfect-square `isqrt` overvaluing, odd `d0 + d1`, or a `mulDiv` overflow under a price shock |
| Affected steps | `BOR`, `LIQ` |
| Prerequisites | A listed feed or pair with those properties |
| Attack approach | Borrow when the computed price exceeds fair value, or block reads with a revert |
| Impact | Overvaluation or a reverting price |
| Expected protection | `INV-055`: price `price8 = max(1, Σ_i ⌊(a_i − 1)⁺ · v_i / 10^(d_i)⌋)` over the composition `a = composition(10^d, v)` at the valuation prices, every term rounded down, so it is at least 1 and never above the value of the holdings (`SPEC-ORC-008`); the vault-token decimals `d` are the smallest in `[6, 18]` with `price8(10^d) ≥ 10^8` at listing, whatever the token decimals, and listing reverts if none qualifies (`SPEC-ORC-005`); listing requires normalised `minAnswer ≥ 1`, standard tick spacing and raw price below 2^64 under a 100× shock; a normalised 0 is a failure (Source: Q-191) |
| Result | Mitigated |
| Checks | MATH-UO-01, MATH-UO-10, MATH-UO-15, MATH-UO-16, SYM-30 |

### ATTACK-056: Stale-price borrowing during a silent feed stall

| Field | Value |
|---|---|
| Target | LPOracle freshness, RiskModule |
| Objective | Borrow at a served price above market while a collateral or debt feed has stopped updating but is still inside its heartbeat |
| Affected steps | `BOR` |
| Prerequisites | Feed stall during a price move; capital to mint LP |
| Attack approach | Pledge freshly minted LP and borrow the maximum at the stalled price, then default |
| Impact | Bad debt up to the borrowable headroom |
| Expected protection | `INV-023`, `INV-056`, `INV-072`: the RiskModule's `preBorrowCheck` checks each collateral source timestamp and each non-fixed debt feed of the account against `borrowPriceMaxAge`; caching never refreshes a timestamp; markets and debt reserves without a route meeting the cadence are not listed (Source: Q-182, Q-229, Q-238) |
| Result | Launch condition — each listed market and each non-GHO debt reserve has a Chainlink route whose update cadence meets `borrowPriceMaxAge`; markets and reserves without one are deferred |
| Checks | SIM-02C, SIM-03C, SIM-03D |

## Liquidation griefing and economics

### ATTACK-057: Unliquidatable position through a reverting payout recipient

| Field | Value |
|---|---|
| Target | LPVaultSwap payouts |
| Objective | Make one's own liquidation revert by controlling a recipient of a push transfer |
| Affected steps | `LIQ` payouts |
| Prerequisites | Borrower is a reverting contract or is on a token issuer's blocklist |
| Attack approach | Make a payout to the borrower revert |
| Impact | Account never liquidated |
| Expected protection | `INV-035`, `INV-036`, `INV-039`, `INV-061`: routed settlement pays the borrower only the surplus `B` in the debt asset, and a liquidation pays only `feeRecipient`, the borrower's wallet and the caller; no lender receives anything, because LPVaultSwap takes no flash loan in a liquidation (`Q-404`); fees stay claimable in the LPVault. There is no in-kind settlement (`Q-401`). Every transfer of Avana's fee, the borrower surplus, a route residue or a dust leg is gas-limited, and its failure does not revert the liquidation: if the transfer reverts, returns `false` or runs out of gas, LPVaultSwap deposits the amount in the immutable PayoutEscrow, the payout escrow, credited to that recipient, who claims it later to a recipient of its choosing. A reverting contract or a blocklisted borrower therefore cannot block its own liquidation, and the gas limit stops a token from consuming the liquidation's gas through a payout transfer. The caller's own payout `keeperOut` is paid directly to `msg.sender` or the call reverts, so a caller that cannot receive the debt asset blocks only its own call, and any other address liquidates the account (2.11 `REQ-SWAP-076`) (Source: Q-060, Q-061, Q-097, Q-124, Q-133, Q-214, Q-401, Q-404) |
| Result | Mitigated |
| Checks | TEST-173, TEST-179 |

### ATTACK-058: Settlement halted by an issuer pause or blocklist

| Field | Value |
|---|---|
| Target | Pool tokens and debt assets controlled by an issuer (USDC, USDT) |
| Objective | Halt liquidation, repay, withdrawal or fee collection by pausing a token or blocklisting an Avana contract or a proxy |
| Affected steps | `LIQ` collect and conversion into the debt asset; `REP`; `WDR`; `FEE` |
| Prerequisites | Issuer action |
| Attack approach | The issuer pauses the token; or blocklists LPVaultSwap (stops conversion of that pool token and the payout of a USDC or USDT debt reserve), the AaveAdapter (USDC and USDT check the spender of `transferFrom`, so every repay of that debt asset reverts), the LPVault (fee collection and liquidity removal in that market), or one borrower's PositionProxy (that account can no longer borrow or repay that asset) |
| Impact | Positions in the affected market or debt reserve decay toward bad debt while the action lasts; a blocklisted proxy only harms its own borrower, because liquidation moves the debt asset from LPVaultSwap to the Hub and never through the proxy |
| Expected protection | `INV-034`, `INV-043`, `INV-067`, `INV-071`, `INV-081`: the AaveAdapter, the proxies, LPVaultSwap and every route measure every amount by balance delta, so a paused or blocklisted transfer reverts the call instead of booking a wrong amount; the RiskModule probes each pool token and debt asset with `paused()` (gas-limited staticcall, a revert counts as paused), and the ISSUER breaker stops new pledges into the affected markets and borrowing of the affected asset without any guardian action; the token-issuer playbook pauses the application with reason `General` when the token sits in many markets, asks Aave to freeze the affected reserves, and offboards markets whose Avana contracts are blocklisted; caps are sized for paused-liquidation loss over the 48-hour incident window; a debt asset's exposure is bounded by that reserve's `drawCap`, and its losses are covered by that asset's own Coverage Spoke; repay of every other debt reserve, debt-free withdrawal and liquidation of markets without the token stay open; no settlement path runs while the token itself is paused, and a payout of Avana's fee, the borrower surplus, a residue or a dust leg that the recipient cannot receive goes to the PayoutEscrow, the payout escrow, while the caller's `keeperOut` is paid directly or the caller's own call reverts (Source: Q-052, Q-118, Q-119, Q-192, Q-227, Q-233, Q-236, Q-241, Q-243, Q-271, Q-404) |
| Result | Accepted risk — owner: Avana Labs (monitoring and the freeze and pause runbook) and the Aave DAO (losses beyond the affected asset's First-Loss Reserve per the funding approval); bound: the affected markets' caps and the affected debt reserve's `drawCap` |
| Checks | TEST-221, TEST-228 |

### ATTACK-059: Token behaviour change after listing

| Field | Value |
|---|---|
| Target | Pool tokens and debt assets |
| Objective | Break settlement or repay accounting with a fee-on-transfer switch, rebasing, hooks or a false-returning `transfer` |
| Affected steps | `LIQ` (unwind, conversion into the debt asset, payout), `REP`, `FEE`, `WDR` |
| Prerequisites | Issuer upgrade (USDT fee switch, USDC upgrade) |
| Attack approach | Enable a transfer fee on a pool token or a debt asset, so settlement receives less than computed, a swap route delivers less of the debt asset than measured, or a repay forwards less to the proxy than the payer sent |
| Impact | Recovery floor misses; a liquidation that repays less debt than bought; hook re-entry |
| Expected protection | `INV-021`, `INV-054`, `INV-070`: listing excludes fee-on-transfer, rebasing, hook and false-returning tokens as pool tokens and as debt assets; after listing every step uses the amount actually received: liquidity removal books at most the principal removed (`SPEC-BACK-008`), each route measures the input it actually pulled and sizes its output from it, a swap leg that delivers less than its measured output reverts (`TransferMismatch`), and a proxy repays the amount it actually received; a USDT fee switch (`basisPointsRate() > 0`) trips the ISSUER breaker, which stops new pledges and borrowing in the affected markets and debt reserve; liquidation settles at the reduced amounts where USDT is a pool token, and where USDT is the debt asset Aave V4's Hub refuses every fee-reduced repayment (`InsufficientTransferred`), so liquidation and repay of that debt revert, with nothing booked, until the fee returns to 0 (2.11 `REQ-SWAP-123`); the Lock blocks re-entry; issuer-upgradeable USDC and USDT are accepted as named exceptions under monitoring (Source: Q-048, Q-061, Q-119, Q-124, Q-148, Q-233, Q-235, Q-241, Q-271) |
| Result | Accepted risk — owner: Avana Labs (monitoring of issuer upgrades with the token-issuer playbook); bound: for a pool token, the fee itself on amounts already in flight, since every later step uses the measured amount and the ISSUER breaker stops new exposure; for a debt asset, repayments wait inside Aave V4 until the fee returns to 0, as for every Aave user of the asset (playbook P-20) |
| Checks | TEST-221, TEST-222, TEST-228 |

### ATTACK-060: Borrower front-runs the keeper

| Field | Value |
|---|---|
| Target | LPVaultSwap |
| Objective | Make every liquidation attempt revert by changing state between simulation and inclusion |
| Affected steps | `LIQ` |
| Prerequisites | Borrower watches the mempool or builder flow |
| Attack approach | Collect fees, repay a little, top up, or donate liquidity before the keeper's transaction |
| Impact | Repeated failed liquidations |
| Expected protection | `INV-030`, `INV-034`: Aave sizes repayment at execution; keeper inputs are maxima; fees and donations are outside collateral; no spot check (Source: Q-060, Q-061, Q-067, Q-085) |
| Result | Mitigated |
| Checks | None |

### ATTACK-061: Liquidation gas exhaustion with many dust NFTs in one market

| Field | Value |
|---|---|
| Target | Collateralization liquidation debit |
| Objective | Pledge many tiny NFTs into one market so a seizure must debit more records than fit in a block |
| Affected steps | `DEP` record insertion; `LIQ` debit |
| Prerequisites | Capital for many positions in the market's range of at least `minPledgeUsd` each; gas for each pledge |
| Attack approach | Mint and pledge hundreds of small positions into one account-market next to a large one, borrow, and let HF fall below 1, so that each unwind per debited record pushes the debit past the block gas limit |
| Impact | The account cannot be liquidated in that market; debt grows into bad debt |
| Expected protection | `INV-015`, `INV-069`: every pledge, top-ups included, must be worth at least `minPledgeUsd` ($10 at launch) at the served LPOracle price, so each record costs the attacker at least $10 of collateral as well as the insert gas; Collateralization keeps records in largest-first order at insertion, with the insert cost paid by the pledger; the debit walks from the top and stops once the seized units are covered, so it touches only the records it debits, and the LPVault removes liquidity only for those; keepers size `debtToCover` per call so each call's walk fits in a block, and repeat calls. Example: 300 records of $10 each hold $3,000 of collateral the attacker must fund (Source: Q-108, Q-170, Q-194, Q-230) |
| Result | Accepted risk — owner: Avana Labs (keeper operations and monitoring of records per account). Residual: when Aave's dust rule (`DUST_LIQUIDATION_THRESHOLD`) forces seizure of the whole remaining reserve, the keeper cannot split the call, and the walk covers every remaining record; the small records sit at the bottom of the order, so this happens on the last call, where the debt at stake is bounded by the remaining collateral below the dust threshold; the attacker pays at least `minPledgeUsd` of collateral and the insert gas for each record the walk spends on |
| Checks | TEST-196 |

### ATTACK-062: Gas exhaustion in account health evaluation across many reserves

| Field | Value |
|---|---|
| Target | CDP Spoke health computation, RiskModule and LPVaultSwap account-level gates |
| Objective | Hold collateral in many markets and debt in many debt reserves so every liquidation recomputes health and checks prices over too many reserves |
| Affected steps | `LIQ`, `BOR` |
| Prerequisites | Several listed markets and several enabled debt reserves |
| Attack approach | Pledge into every market and borrow a small amount of every debt reserve |
| Impact | Liquidation of diversified accounts runs out of gas |
| Expected protection | `INV-055`, `INV-072`: the collateral price path is Chainlink-only and each debt price is one Aave oracle read (GHO's is a fixed source); the CDP Spoke's `spokeUserReservesLimit` bounds the number of reserves per account and counts collateral and debt reserves together, so the per-account gate loop over every collateral market and every debt reserve is bounded by the same limit (Source: Q-128, Q-193, Q-234, Q-238) |
| Result | Launch condition — worst-case liquidation gas benchmark at `spokeUserReservesLimit` reserves, with debt reserves counted, before the Aave DAO sets the limit |
| Checks | TEST-203 |

### ATTACK-063: Dust account that the recovery floor makes unliquidatable

| Field | Value |
|---|---|
| Target | LPVaultSwap recovery floor |
| Objective | Create accounts whose seized value is so small that unwind and route rounding exceed the slippage allowance, so every routed liquidation reverts |
| Affected steps | `LIQ` |
| Prerequisites | No minimum debt; a position reduced to dust by earlier partial liquidations, or a small debt against a pledge at the `minPledgeUsd` floor |
| Attack approach | Pledge an NFT worth `minPledgeUsd` ($10), borrow a few cents, let partial liquidations or a price drop shrink the seized amount per call to well under a cent, wait for HF < 1 |
| Impact | None for Avana: the liquidating caller pays any rounding gap through its shortfall top-up |
| Expected protection | `INV-034`, `INV-037`, `INV-038`, `INV-069`: `minPledgeUsd` keeps every new record at $10 or more, so dust arises only from what remains after liquidation; the recovery floor subtracts one raw token unit per unwound token (valued in the debt asset, `U`) and `ε = floorRoundingAllowance(spoke, r)` (2.11 `SPEC-LIQ-005`), because unwinding and each swap can lose up to one raw unit whatever the position size, which for a dust position exceeds any percentage allowance. The caller sizes `debtToCover`, which is its funding `Kf`, up front for any increase Aave V4's dust rule imposes; a recovery below the debt repaid `D` comes out of its own `keeperOut`, and a gap below the floor is closed by its shortfall top-up within `maxShortfall`; no Avana contract funds the gap (the SettlementBudget is removed, `Q-397`). Dust liquidations therefore settle and deficits get recorded. Example (USDC debt): seized backing worth 0.000002 USDC with a 100 bps allowance and `ε` = 1 USDC gives `minRec = max(0, ⌈0.000002 × 0.99⌉ − U − 1) = 0`, so the routed liquidation passes the floor, and the caller bears `D − R` in its own payout `keeperOut = Kf + R − D`, a loss it accepts through `minPayout`. One case remains: a whole debt worth less than one vault-token base unit times the bonus makes Aave size a 0-unit seizure, which LPVaultSwap refuses with `NothingSeized`; no value is at risk, anyone can repay it through the AaveAdapter, and any caller can clear it with a direct zero-seizure `liquidationCall` (`FINDING-098`) (Source: Q-127, Q-144, Q-163, Q-169, Q-198, Q-228, Q-230, Q-236, Q-397, Q-401, Q-404) |
| Result | Mitigated; zero-unit residual accepted (`FINDING-098`) |
| Checks | HYP-53 (holds with the Q-198 terms; zero-unit bound recorded in FINDING-098), TEST-160, TEST-161, TEST-196, FINDING-048, FINDING-098 |

### ATTACK-064: Bad debt and reimbursement cost from sub-economic positions

| Field | Value |
|---|---|
| Target | Keeper economics, First-Loss Reserve of each debt asset |
| Objective | Open many small loans so liquidations cost more gas than they recover during gas spikes, hoping no keeper acts |
| Affected steps | `LIQ`, `DEF` |
| Prerequisites | Many wallets |
| Attack approach | Split borrowing across sybil wallets, in any debt reserve; wait for a gas spike and a price drop |
| Impact | Avana's own keeper gas cost, or bad debt covered by the First-Loss Reserve of the affected asset |
| Expected protection | `INV-041`, `INV-042`, `INV-069`, `INV-071`: each sybil position needs a pledge worth at least `minPledgeUsd` ($10); Avana has no minimum debt (`INV-096`, `Q-381`): Avana's own committed keeper liquidates every HF < 1 account whatever its size and Avana pays the gas as its own keeper cost, so liquidation never waits for a keeper to make a profit, and `liquidate` stays open to every address that is not frozen (`INV-062`, `Q-404`); the 16-record cap keeps each account's liquidation within one transaction; Aave's dust rule forces full liquidation of small debts; a recorded deficit in debt reserve r is covered only from the Coverage Spoke of r's (Hub, asset), in that asset (Source: Q-071, Q-098, Q-169, Q-179, Q-185, Q-230, Q-236, Q-381, Q-404) |
| Result | Accepted risk — owner: Avana Labs (keeper gas, an operating cost); bound: gas per account at most `G(16)` = 5.15M gas, and the attacker funds at least `minPledgeUsd` of collateral and the opening gas per account |
| Checks | SIM-05A, SIM-05C, SIM-07C, TEST-199 |

### ATTACK-065: Liquidation griefing by moving the pool spot price

| Field | Value |
|---|---|
| Target | LPVaultSwap unwind and conversion |
| Objective | Make liquidations revert by pushing the unwound pool past a spot check or per-token minimum, or by moving a swap route into the debt asset |
| Affected steps | `LIQ` unwind and conversion |
| Prerequisites | Capital to move the pool or a swap route for one block, each block |
| Attack approach | Swap in the keeper's block in the unwound pool; or move the DEX pool of a swap route into the debt asset so the leg misses its `minOut` |
| Impact | Liquidations stop exactly when needed |
| Expected protection | `INV-034`, `INV-070`, `INV-083`: no spot-price veto on the unwind, which removes exactly the seized units at any spot and returns n token amounts; each conversion leg runs with an oracle-derived minimum (`SPEC-LIQ-018`) that a spot move cannot raise, and the leg minimums sum to within rounding of the aggregate recovery floor, so a leg reverts only where the whole liquidation would miss its floor anyway; a caller may cover a small shortfall itself up to `maxShortfall` (`SPEC-LIQ-019`). There is no buy leg: the caller funds the debt asset itself and the legs swap pool tokens directly into it; a leg whose primary route misses its `minOut` falls to the backup route, so the attacker must hold both swap routes off price in every block, paying the slippage it creates each time; for a concentrated market each route is stressed at the full position value in one token (`ATTACK-161`) (Source: Q-085, Q-131, Q-235, Q-250, Q-251, Q-363, Q-404) |
| Result | Mitigated |
| Checks | SIM-06C, TEST-197, FINDING-074 |

### ATTACK-066: Zero-seizure liquidations that bill Avana for funding costs

| Field | Value |
|---|---|
| Target | LPVaultSwap funding |
| Objective | Repay borrowers' debt without seizing collateral and leave a flash premium or rounding gap for Avana to pay |
| Affected steps | `LIQ` funding |
| Prerequisites | Any address |
| Attack approach | Call `LPVaultSwap.liquidate`, directly or through the flash liquidation helper, with `debtToCover` below one vault-token unit's value; Aave seizes 0 units; the floor of 0 passes; the helper's premium is left unpaid; repeat across debt reserves |
| Impact | None: the call reverts |
| Expected protection | `INV-030`, `INV-037`, `INV-038`: `LPVaultSwap.liquidate` reverts with `NothingSeized` when Aave seizes 0 vault-token units (2.11 `REQ-SWAP-017`), so LPVaultSwap never repays debt without a seizure; LPVaultSwap takes no flash loan in a liquidation (2.11 `REQ-SWAP-012`), and a helper repays its loan and premium from the `keeperOut` it receives and its caller's bounded top-up (`REQ-HELPER-007`); no Avana contract funds any part of a settlement (the SettlementBudget is removed, `Q-397`), so every premium and rounding gap is paid by the caller, from its `keeperOut` or its shortfall top-up, or the call reverts; spreading calls over several debt reserves or markets bills nothing to Avana (Source: Q-127, Q-144, Q-167, Q-190, Q-236, Q-343, Q-397, Q-404) |
| Result | Mitigated |
| Checks | QNT-29 (Quint counterexample C-QNT-4, closed by the zero-seizure revert in LPVaultSwap), QNT-T07, TEST-160, TEST-200, FINDING-044 |

### ATTACK-067: Route sandwiching that pushes a settlement gap onto Avana

| Field | Value |
|---|---|
| Target | LPVaultSwap swap routes |
| Objective | Sandwich the conversion into the debt asset so the debt repaid exceeds proceeds by the most the floor allows, and leave the gap for Avana |
| Affected steps | `LIQ` conversion and settlement |
| Prerequisites | Builder access, a DEX-based route, or its own `liquidate` call |
| Attack approach | Front-run to push the route pool; a liquidation recovers exactly the floor in the debt asset; back-run to restore |
| Impact | None for Avana: proceeds below the floor revert, and a rounding gap above it is the caller's own top-up |
| Expected protection | `INV-034`, `INV-037`, `INV-038`, `INV-070`: the multiplicative bound `s = min(slippageAllowanceBps, ⌊10⁴ × (bNet − 10⁴) / bNet⌋)` with the live net bonus gives `bNet × (10⁴ − s) ≥ 10⁸`, so the floor alone covers the debt `D` Aave took for every debt asset, up to one vault unit and the rounding terms; no flash premium enters, because LPVaultSwap takes no flash loan in a liquidation (`Q-404`), and there is no buy leg (`INV-070`); the floor's rounding terms (one raw unit per token, `U`, and `ε = floorRoundingAllowance(spoke, r)`) are borne by the caller: a recovery between the floor and `D` lowers its `keeperOut`, and a recovery below the floor is closed by its shortfall top-up, bounded by `maxShortfall`, because no Avana contract funds a settlement gap (`Q-397`); the First-Loss Reserve never covers in-transaction shortfalls, so a sandwich below the floor reverts. Example: `V = 2,047.5` USDC at `s = 100` bps gives `minRec = 2,026.024998` USDC against `D = 1,950`, so even a sandwich down to the floor leaves `R − D = 76.024998` USDC above the debt (Source: Q-062, Q-071, Q-127, Q-159, Q-167, Q-190, Q-198, Q-235, Q-236, Q-397, Q-404) |
| Result | Mitigated |
| Checks | MATH-ST-05, MATH-ST-08, MATH-ST-21, MATH-ST-22, SYM-42, TEST-198, FINDING-072, FINDING-029 |

### ATTACK-068: Oversized flash loan whose cost is billed to Avana

| Field | Value |
|---|---|
| Target | Flash liquidation helper, LPVaultSwap funding |
| Objective | Flash-borrow more of the debt asset than the liquidation needs, so Avana pays the premium on the unused part |
| Affected steps | `LIQ` funding |
| Prerequisites | Any address using the flash liquidation helper; a non-zero premium on the Aave V3 Pool |
| Attack approach | Request a helper loan `F` far above the debt Aave pulls |
| Impact | None for Avana: the caller pays the whole premium |
| Expected protection | `INV-037`, `INV-095`: LPVaultSwap takes no flash loan in a liquidation (2.11 `REQ-SWAP-012`): it pulls `Kf` from its caller and returns the unused `Kf − D` inside `keeperOut`. The helper borrows `0 < F ≤ debtToCover` from the Aave V3 Pool, refuses a premium above the caller's `maxPremium` or above `maxFlashFeeBps` of `F`, and repays `F + φ` from the `keeperOut` it receives and its caller's bounded top-up (`REQ-HELPER-003`, `REQ-HELPER-005`, `REQ-HELPER-007`); no Avana contract pays any part of the premium (`Q-397`), so oversizing costs only the caller. Example: for the debt `D = 1,950` USDC of 2.11, `debtToCover = F = 10,000` USDC at 5 bps gives `keeperOut = 10,000 + 2,040.3 − 1,950 − 19.5 = 10,070.8` USDC; the helper repays `10,000 + 5 = 10,005` USDC and pays its caller 65.8 USDC, against 69.825 USDC with a loan of 1,950 USDC (Source: Q-135, Q-190, Q-235, Q-363, Q-397, Q-404) |
| Result | Mitigated |
| Checks | MATH-ST-23, SYM-45, TEST-197 |

### ATTACK-069: Double daily settlement funding through calendar-day buckets or several debt reserves

| Field | Value |
|---|---|
| Target | Avana-funded settlement allowances |
| Objective | Draw twice a daily settlement allowance within seconds around a day boundary, or draw each debt reserve's allowance in the same window |
| Affected steps | `LIQ` settlement |
| Prerequisites | Its own `liquidate` call |
| Attack approach | Draw an allowance just before and just after midnight; draw the allowance of every `(spoke, debtReserveId)` in one window |
| Impact | None: there is no Avana settlement allowance to draw |
| Expected protection | `INV-037`, `INV-097`: the SettlementBudget and its daily windows are removed (`Q-397`); no Avana contract funds any part of a liquidation's settlement, so there is no daily allowance to double; every gap at final settlement is paid by the caller through its shortfall top-up (Source: Q-190, Q-343, Q-397) |
| Result | Mitigated |
| Checks | MATH-ST-25, TEST-200 |

### ATTACK-070: Forced in-kind fallback to skip the Avana fee and recovery floor

| Field | Value |
|---|---|
| Target | LPVaultSwap settlement mode |
| Objective | Make routes "fail" so the keeper takes tokens in kind and keeps the whole bonus |
| Affected steps | `LIQ` |
| Prerequisites | Its own `liquidate` call; ability to make a route fail inside a bundle (gas-limited inner call, route capacity filled with a flash loan) |
| Attack approach | Starve the inner swap of gas so a `catch` selects a fallback, or fill a route's capacity before the liquidation |
| Impact | Avana fee lost; recovery floor bypassed |
| Expected protection | `INV-039`: there is no in-kind settlement (`Q-401`); every liquidation settles in the debt asset over the market's swap routes, meets the recovery floor and pays the Avana fee, or reverts; a caught failure of the primary route falls only to the backup route, and a debt reserve with no usable swap route reverts `NoRouteAvailable` (Source: Q-133, Q-163, Q-227, Q-228, Q-235, Q-401) |
| Result | Mitigated |
| Checks | TEST-179, FINDING-073, FINDING-090 |

### ATTACK-071: In-kind valuation manipulation

| Field | Value |
|---|---|
| Target | Keeper payout in pool tokens |
| Objective | Take more than `D × (1 + bonus)` in tokens by moving the pool spot or exploiting rounding |
| Affected steps | `LIQ` payout |
| Prerequisites | Its own `liquidate` call |
| Attack approach | Ask to be paid in seized pool tokens valued at a moved spot or with round-down valuation |
| Impact | None: no settlement pays in pool tokens |
| Expected protection | `INV-039`: in-kind settlement is removed (`Q-401`); a caller is paid only `keeperOut` in the debt asset from routed settlement, after the recovery floor and the Avana fee, so there is no pool-token split to value (Source: Q-133, Q-190, Q-401) |
| Result | Mitigated |
| Checks | MATH-ST-27, MATH-ST-28, MATH-ST-31 |

### ATTACK-072: MEV extraction from a whole-position sale

| Field | Value |
|---|---|
| Target | Settlement |
| Objective | Extract slippage from value a whole-NFT sale would return to the borrower |
| Affected steps | `LIQ` |
| Prerequisites | Builder access |
| Attack approach | Sandwich a whole-NFT sale whose proceeds above the debt return to the borrower |
| Impact | Borrower value lost to slippage |
| Expected protection | `INV-032`: partial seizure only; in a routed liquidation LPVaultSwap pays the borrower only the borrower surplus `B` in the debt asset (the recovery above `max(V, D)`, 2.11 `SPEC-LIQ-022`), and the borrower keeps the unseized collateral, its liquidity and fees (2.11 `REQ-SWAP-027`); slippage falls on proceeds within the floor (Source: Q-060, Q-062, Q-085, Q-404) |
| Result | Mitigated |
| Checks | None |

### ATTACK-073: Theft through keeper-supplied router calldata

| Field | Value |
|---|---|
| Target | LPVaultSwap |
| Objective | Use arbitrary router calldata to redirect outputs or spend approvals |
| Affected steps | `LIQ` conversion into the debt asset |
| Prerequisites | Keeper key |
| Attack approach | Pass a route with a different recipient or a `transferFrom`; pass a swap route of the attacker's choosing |
| Impact | Theft of proceeds or of the caller's funding in the debt asset |
| Expected protection | `INV-021`, `INV-070`: fixed on-chain routes per market and token, and fixed swap routes into each debt asset, recorded in the MarketRegistry; no caller calldata; the caller picks only the route mode (primary then backup, or backup only), and the flash liquidation helper passes `params` to `liquidate` unchanged with no swap step (2.11 `REQ-HELPER-012`); exact approvals reset to 0; routes are set at listing through the timelock at the normal delay (5 days) with cancellers (Source: Q-062, Q-151, Q-228, Q-235, Q-404) |
| Result | Mitigated |
| Checks | None |

### ATTACK-074: Spoofed flash-loan or swap callback

| Field | Value |
|---|---|
| Target | LPVaultSwap callbacks, route and buy-route callbacks |
| Objective | Start a settlement with attacker-chosen parameters or pull tokens through a fake callback |
| Affected steps | `LIQ` conversion and the helper's loan; `REP` repay-with-collateral flash funding |
| Prerequisites | None |
| Attack approach | Call the Aave V3 Pool `flashLoan` with the flash source or the flash liquidation helper as receiver from the attacker (the Pool passes the attacker as initiator); call LPVaultSwap's `onFlashLoan`, the helper's `executeOperation` or a swap callback of a swap route directly |
| Impact | Unauthorized settlement or theft |
| Expected protection | `INV-040`, `INV-054`, `INV-095`: the `IFlashSource` callback, used only by repay with collateral, requires the source's lender (the Aave V3 Pool) as caller, the source itself as initiator and an active context it opened, and LPVaultSwap's `onFlashLoan` requires the flash source as caller and the deleverage context held under the AaveAdapter's Lock (2.11 `REQ-FLASH-003`, `REQ-SWAP-013`); the helper's callback requires its Pool, itself as initiator, the bound asset, amount, premium bound and `params` hash and a single-use context (`REQ-HELPER-005`); `liquidate` takes no flash loan, so no flash callback runs inside LPVaultSwap during a liquidation; swap callbacks of swap routes are accepted only from the active route's fixed pool (factory-derived for Uniswap) while LPVaultSwap holds the Lock (`InvalidCallback`, `NotLocked`) (Source: Q-045, Q-062, Q-119, Q-148, Q-235, Q-363, Q-404) |
| Result | Mitigated |
| Checks | None |

### ATTACK-075: Liquidation failure under a flash-capacity or premium limit

| Field | Value |
|---|---|
| Target | Liquidation funding |
| Objective | Make large liquidations impossible by draining the Aave V3 Pool's available liquidity of the debt asset, or pushing the premium above its cap |
| Affected steps | `LIQ` funding |
| Prerequisites | Capital to borrow the debt asset's available liquidity from the Aave V3 Pool during a crash |
| Attack approach | Borrow or flash-borrow the debt asset's Aave V3 liquidity in the keeper's block |
| Impact | Shortfall-heavy or reverting liquidations |
| Expected protection | `INV-040`, `INV-046`, `INV-095`: LPVaultSwap takes no flash loan in a liquidation, so the Pool's liquidity and premium bind only the flash liquidation helper, which checks the available liquidity before the loan and the premium against the caller's `maxPremium` and `maxFlashFeeBps` in its callback, and reverts before any state change (2.11 `REQ-HELPER-003`, `REQ-HELPER-005`); a caller holding the debt asset calls `liquidate` directly, and each committed operator holds inventory of at least the largest single `debtToCover` the chain's caps allow (`REQ-SWAP-014`); each debt reserve's `drawCap` is sized so that the largest single liquidation fits within half the Pool's idle liquidity of that asset (`REQ-FLASH-008`); the helper's Pool is never a Hub recorded on the chain (`REQ-HELPER-002`), so a stressed Hub does not also starve the loan. Example: the Base Pool holds about 0.13M idle GHO; the public helper refuses a 400,000 GHO loan before any state change, and Avana's keeper calls `liquidate` directly with 400,000 GHO of its own (Source: Q-063, Q-084, Q-135, Q-186, Q-235, Q-336, Q-363, Q-404) |
| Result | Launch condition — cap stress test of every debt reserve on each chain against the Aave V3 Pool's available liquidity and the committed operators' inventory, and the flash-borrower grants for the flash source and the public helper in the listing payload |
| Checks | TEST-197, TEST-267 |

### ATTACK-076: One-wei donation DoS on zero-balance checks

| Field | Value |
|---|---|
| Target | AaveAdapter, PositionProxy, LPVaultSwap |
| Objective | Brick repay or liquidation with an end-of-call `balanceOf(this) == 0` assertion |
| Affected steps | `REP`, `LIQ` |
| Prerequisites | 1 wei of any debt asset |
| Attack approach | Transfer 1 wei of a debt asset to a victim's proxy, to the AaveAdapter or to LPVaultSwap |
| Impact | Permanent repay failure for the victim; protocol-wide liquidation halt |
| Expected protection | `INV-021`, `INV-043`, `INV-046`: every check in the AaveAdapter, the PositionProxy and LPVaultSwap uses before/after deltas of the asset it moves; donations are ignored and never refunded as if they were the payer's (Source: Q-124, Q-223) |
| Result | Mitigated |
| Checks | HYP-52, FINDING-075 |

### ATTACK-077: Cap filling to block rescue top-ups

| Field | Value |
|---|---|
| Target | RiskModule caps, Hub `addCap` |
| Objective | Fill every cap with debt-free pledges (which keep earning fees) so borrowers cannot top up in a drop |
| Affected steps | `DEP` top-up |
| Prerequisites | Capital; sybil wallets; optionally small loans to look indebted |
| Attack approach | Fill the regular budgets; borrow a little from each wallet to qualify for the slice and fill it |
| Impact | Borrowers liquidated instead of rescuing |
| Expected protection | `INV-028`: a slice reserved per market for top-ups, usable only by accounts with debt and HF below `rescueHealthFactor` (1.10), only up to the units that restore it; Hub `addCap` sized above budgets plus slice at `stressFloorUsd` (Source: Q-150, Q-157, Q-175, Q-398) |
| Result | Mitigated |
| Checks | MATH-UO-28, HYP-55, FINDING-078 |

### ATTACK-078: Repay rules that block risk-reducing repayment

| Field | Value |
|---|---|
| Target | AaveAdapter repay |
| Objective | Exploit a repay floor or an exact-amount repay-all so a borrower near HF 1 cannot repay one of its debt reserves |
| Affected steps | `REP` |
| Prerequisites | A debt near a minimum-debt floor; interest accruing between signing and execution |
| Attack approach | A partial repay leaving debt below a floor reverts; a repay-all signed for the exact debt becomes partial after 1 wei of interest |
| Impact | Borrower liquidated and loses the bonus |
| Expected protection | `INV-043`: no repay floor and no minimum debt; `AaveAdapter.repay(borrower, spoke, debtReserveId, maxRepaySpend, repayAll, deadline)` reads the live debt of that one reserve (including premium) and repay-all is bounded by the signed `maxRepaySpend`; repay at zero debt (partial or repay-all) returns 0 with no token movement, so a repay that races a liquidation never reverts; repay never reads the pause state. Example: a USDC debt (6 decimals) of 1,000.000000 accrues 0.000137 USDC before inclusion; a repay-all with `maxRepaySpend` 1,005e6 pulls 1,000.000137 USDC (Source: Q-153, Q-169, Q-180, Q-209, Q-227, Q-234) |
| Result | Mitigated |
| Checks | MATH-AR-17, TEST-203, FINDING-021 |

### ATTACK-079: Debit check that bricks liquidation or trusts LPVaultSwap's snapshot

| Field | Value |
|---|---|
| Target | Collateralization liquidation debit |
| Objective | Make every liquidation revert through a one-unit mismatch when Hub shares ≠ assets, or fake the "before" value |
| Affected steps | `LIQ` debit |
| Prerequisites | Share drift on the vault-token asset, or a hostile LPVaultSwap |
| Attack approach | Rely on an asset-view comparison that is off by one unit; pass a forged snapshot |
| Impact | Liquidation halt, or a debit that does not match the seizure |
| Expected protection | `INV-004`, `INV-014`, `INV-066`: share-based comparison; Collateralization takes the snapshot of the proxy's supplied shares and the token's total supply itself in `beginSeizure` under the Lock and requires share drop == units burned by the AaveAdapter == supply drop (`SeizureMismatch`, `SupplyDropMismatch`); liquidation requires shares == assets and stops with an alarm otherwise; drift checks keep them equal (Source: Q-160, Q-181, Q-189, Q-224) |
| Result | Mitigated |
| Checks | MATH-ST-38, MATH-ST-39, MATH-ST-40, QNT-T11, TEST-208, FINDING-016 |

### ATTACK-080: Risk-premium threshold breach that blocks repay and liquidation

| Field | Value |
|---|---|
| Target | Hub `riskPremiumThreshold`, CDP Spoke `collateralRisk` |
| Objective | Make the Hub revert every premium update (repay, liquidation, refresh) |
| Affected steps | `REP`, `LIQ` |
| Prerequisites | Aave configuration raising `collateralRisk` above the threshold, or many tiny users at the top risk |
| Attack approach | Raise a vault reserve's `collateralRisk` to the threshold; open accounts with few drawn shares |
| Impact | Repay and liquidation revert |
| Expected protection | `INV-029`: threshold at highest collateral risk plus at least 1 bps, never lowered while debt exists; a risk increase must follow a threshold increase; the drift check blocks new borrows if violated (Source: Q-141, Q-178) |
| Result | Launch condition — fork test with many users at the top collateral risk proving repay and liquidation pass |
| Checks | MATH-AR-22, MATH-AR-24, MATH-AR-25, SYM-54 |

### ATTACK-081: Keeper reimbursement farming

| Field | Value |
|---|---|
| Target | Keeper gas budget |
| Objective | A builder that also runs liquidations inflates the priority fees Avana's keepers pay to it |
| Affected steps | `LIQ` (keeper transaction pricing) |
| Prerequisites | Keeper and builder roles |
| Attack approach | Delay inclusion of Avana's keeper transactions until they raise their tips |
| Impact | Avana's keeper gas budget overspent |
| Expected protection | Avana's keepers are Avana's own and pay gas from Avana's operating budget, with a capped tip per transaction and private order flow to several builders; no external keeper is reimbursed, so there is no claim to inflate, and liquidation never depends on a keeper's profit (`INV-096`) (Source: Q-098, Q-185, Q-381) |
| Result | Accepted risk — owner: Avana Labs (keeper operations); bound: the tip cap per transaction |
| Checks | FINDING-084 |

## Keepers and operations

### ATTACK-082: Settlement theft with a keeper key and a fast route change

| Field | Value |
|---|---|
| Target | LPVaultSwap routes and keeper inputs |
| Objective | Combine a stolen keeper key with a route installed faster than the exit window |
| Affected steps | `LIQ`; `MKT` route changes |
| Prerequisites | One keeper key or any other address (registration grants no liquidation power, `Q-404`); governance multisig compromise |
| Attack approach | Schedule an attacker swap route, then liquidate through it to capture the slippage allowance |
| Impact | Loss on every liquidation until detected |
| Expected protection | `INV-034`, `INV-051`, `INV-068`: `setRoute`, `setBuyRoute` and `setSellBackRoute` wait the normal delay (5 days) and any canceller (governance multisig, Emergency Guardian, Aave Protocol Guardian, Aave governance executor) can cancel; only a previously approved route can come back on the short delay (`restoreRoute`, 12 hours); `disableRoute` and run at the short delay; keeper reward is paid only to `msg.sender`; the recovery floor and each leg's oracle `minOut` limit each loss (Source: Q-048, Q-053, Q-062, Q-151, Q-228, Q-235) |
| Result | Mitigated |
| Checks | FINDING-083 |

### ATTACK-083: Bad debt during a keeper outage

| Field | Value |
|---|---|
| Target | Keeper set |
| Objective | Exploit a period when primary keepers are offline or their shared infrastructure fails |
| Affected steps | `LIQ` |
| Prerequisites | Keeper outage during a price drop |
| Attack approach | Borrow into a falling market expecting no liquidation |
| Impact | Bad debt |
| Expected protection | `INV-048`, `INV-062`: an independent standby keeper on separate infrastructure is registered as a committed operator; monitoring of primary stalls; if every committed operator stalls, any address can call `liquidate`, with its own debt asset or through the public flash liquidation helper, wherever the routed proceeds cover the debt (`Q-404`); the keeper service's kill switch, implementation-slot check and stuck-transaction handling keep a faulty keeper from submitting stale or wrong calls (Source: Q-082, Q-147, Q-213, Q-219, Q-404) |
| Result | Mitigated |
| Checks | SIM-04A, SIM-04B |

### ATTACK-084: Keeper wipe

| Field | Value |
|---|---|
| Target | LPVaultSwap committed-operator registry (keeper list) |
| Objective | Remove every committed operator, including the standby, so no party is bound to liquidate until re-adding clears its delay |
| Affected steps | `LIQ`; `EMG` |
| Prerequisites | Governance multisig compromise |
| Attack approach | Schedule `removeKeeper` for every keeper |
| Impact | None below the floor: removal stops at `keeperFloor`, and liquidation stays open to anyone |
| Expected protection | `INV-048`, `INV-062`, `INV-068`: `removeKeeper` is a short-delay (12 hours) timelock operation that any canceller can cancel and that reverts with `KeeperFloor(activeAfter, KEEPER_FLOOR)` below `keeperFloor` (1 active committed operator, Avana's own; `MAX_KEEPERS` 32); `freezeAddress` checks no floor, so a guardian can freeze a compromised last operator, and new borrowing then halts on the chain until an operator is registered or unfrozen (2.11 `REQ-SWAP-107`); adding an operator waits the normal delay; the registry gates no call, so `liquidate` stays open to every address that is not frozen (Source: Q-139, Q-155, Q-213, Q-228, Q-242, Q-400, Q-404) |
| Result | Mitigated |
| Checks | QNT-T23, FINDING-082 |

### ATTACK-085: Role or keeper grant that bypasses the delay or cannot be cancelled

| Field | Value |
|---|---|
| Target | AvanaTimelock role administration, LPVaultSwap committed-operator registry |
| Objective | Gain `APPLICATION_ADMIN`, a guardian role, the proposer role or a keeper seat without a cancellable delay |
| Affected steps | `EMG`, `LIQ` |
| Prerequisites | Governance multisig compromise |
| Attack approach | Call `grantRole` on an Avana contract or the timelock directly; schedule a role grant or `addKeeper` on the short delay; shorten the normal delay first with `updateDelay` |
| Impact | An attacker role holder with the bounded powers of `ATTACK-082` and `ATTACK-122`, or an attacker registered as a committed operator, which holds no liquidation power beyond any caller's (`Q-404`) |
| Expected protection | `INV-048`, `INV-051`, `INV-068`, `INV-084`: the timelock holds its own `DEFAULT_ADMIN_ROLE` and every Avana contract's `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`, and a grant of either admin role to any other account reverts `AdminRoleOnlyTimelock`, so no role changes except through an executed timelock operation; role grants and `addKeeper` are not in `SHORT_ELIGIBLE`, so they wait the normal delay (5 days); `updateDelay` reverts (`UpdateDelayDisabled`) and `setNormalDelay` is itself a normal-delay self-call bounded by `[MIN_NORMAL_DELAY, MAX_DELAY]` (4 to 5 days); a role-change operation can be cancelled only by the Aave governance executor (`DAO_CANCELLER_ROLE`), and `addKeeper` also only by it, so a guardian cannot block a replacement keeper; every other operation by any canceller (Source: Q-136, Q-155, Q-228, Q-259, Q-262, Q-263) |
| Result | Mitigated |
| Checks | TEST-194, TEST-242, TEST-244, FINDING-086 |

### ATTACK-086: Emergency pause used to halt liquidation

| Field | Value |
|---|---|
| Target | MarketRegistry pause state |
| Objective | Stop every liquidation by pausing the application from a compromised Emergency Guardian or Aave Protocol Guardian |
| Affected steps | `EMG`, `LIQ` |
| Prerequisites | Compromise of a pause-guardian Safe |
| Attack approach | Call `pause(General)`, `pause(MintPathSuspect)` or `freeze()` and hold the state, re-pausing after every unpause; trip every market and debt breaker; freeze the keepers' addresses |
| Impact | None for solvency: new pledges, top-ups, borrowing and withdraw-with-debt stop; liquidation continues |
| Expected protection | `INV-049`, `INV-062`, `INV-067`, `INV-081`, `INV-085`: neither `liquidate` nor `settlePending` reads the pause state, the pause reason or any breaker; liquidation is gated only by the price states of the seized market and the repaid reserve, Hub shares == assets, Aave HF < 1, grace and Aave-side reserve pauses; an address freeze cannot cover a protected Avana contract and binds only a direct caller of `liquidate`: a frozen operator can still liquidate through the public flash liquidation helper, every unfrozen address can call `liquidate`, and freezing every committed operator halts only new borrowing (2.11 `REQ-SWAP-105`, `REQ-SWAP-107`); the guardians hold no power over the routes, and `liquidate` needs no registered operator at all (Source: Q-213, Q-227, Q-228, Q-241, Q-242, Q-252, Q-404) |
| Result | Mitigated |
| Checks | TEST-192, TEST-193, TEST-228, TEST-229, FINDING-087 |

## Caps, deficits and share math

### ATTACK-087: Exposure-cap bypass

| Field | Value |
|---|---|
| Target | RiskModule caps (values in the ParameterStore), Hub `addCap` |
| Objective | Exceed the intended per-market exposure because Hub caps are whole-token `uint40` values, or split pledges so small that cap charges round away |
| Affected steps | `DEP` |
| Prerequisites | Capital |
| Attack approach | Supply through a path that skips the RiskModule check, rely on a coarse Hub cap, or pledge many minimal NFTs |
| Impact | Exposure above the risk budget |
| Expected protection | `INV-009`, `INV-028`, `INV-066`, `INV-069`: pledge is the only mint path — the AaveAdapter mints exactly the units Collateralization credited after `RiskModule.checkPledge` passed — and checks USD caps on-chain; per-market decimals make one whole token about $2 so the Hub cap is meaningful; the RiskModule computes the pledge charge from the LPOracle at a price of at least `stressFloorUsd`, rounded up (regular budget or top-up slice), and Collateralization passes the current counters and books the result after custody in the same call; every pledge is worth at least `minPledgeUsd` ($10), so no pledge is small enough for its rounded-up charge to be material against the caps (Source: Q-054, Q-055, Q-066, Q-209, Q-224, Q-230) |
| Result | Mitigated |
| Checks | MATH-UO-03, TEST-196 |

### ATTACK-088: Pool-share cap denominator manipulation

| Field | Value |
|---|---|
| Target | RiskModule pool-share cap |
| Objective | Pledge past `poolShareMaxBps`, or deny others' pledges, by moving in-range liquidity in the same transaction |
| Affected steps | `DEP` |
| Prerequisites | Flash loan; JIT liquidity |
| Attack approach | Add or remove in-range liquidity or move the price around a pledge |
| Impact | Cap bypass or pledge denial |
| Expected protection | `INV-028`: the denominator is time-weighted in-range liquidity from `observe()`, never same-transaction pool state. The cap binds only on a pool whose listing sets one; the chain default is 10,000 bps, no limit (Source: Q-055, Q-113, Q-119, Q-403) |
| Result | Mitigated |
| Checks | None |

### ATTACK-089: Cross-Spoke or cross-asset liquidity exhaustion and hidden deficit

| Field | Value |
|---|---|
| Target | Hub debt assets (every enabled debt asset, GHO included), funding Hubs |
| Objective | Exhaust shared liquidity of a debt asset from one Spoke, or let deficits sit unseen in a share price |
| Affected steps | `BOR`, `DEF` |
| Prerequisites | Several CDP Spokes, or several debt reserves funded from one Hub |
| Attack approach | Borrow the whole line of one asset on the riskiest tier; leave deficits uncovered |
| Impact | Capacity and losses decided by the riskiest tier |
| Expected protection | `INV-041`, `INV-042`, `INV-057`, `INV-071`: at launch a Stable LP Hub on Ethereum and on Base, each with its CDP Spokes; DAO-set `drawCap` per (Hub, asset, Spoke), and no draw completes that leaves a Spoke above it; credit lines are draw caps on the funding Hub's Lend Spoke supply (public and DAO), and a cross-Hub line is capped by the funding Hub (`INV-094`, off at launch); deficits are recorded per debt reserve in its own asset on the Hub that funded it, alert, and are covered from that asset's Coverage Spoke; only a Coverage Spoke calls `eliminateDeficit`, so coverage spends reserve capital only (Source: Q-032, Q-070, Q-071, Q-095, Q-101, Q-233, Q-236, Q-239, Q-363) |
| Result | Mitigated |
| Checks | TEST-199 |

### ATTACK-090: Coverage spent on deficits outside Avana or in another asset

| Field | Value |
|---|---|
| Target | Coverage Spokes, `Hub.eliminateDeficit` |
| Objective | Spend an Avana First-Loss Reserve on another Spoke's deficit on the same Hub, or on a deficit in a different asset |
| Affected steps | `DEF` |
| Prerequisites | Coverage role misuse |
| Attack approach | Call `eliminateDeficit(assetId, amount, otherSpoke)`; the Hub checks only that the caller Spoke is active; or ask the Coverage Spoke of another asset (GHO) to cover a USDC deficit |
| Impact | Reserve depleted for non-Avana losses or for another asset's losses |
| Expected protection | `INV-042`, `INV-071`: each Coverage Spoke is registered on one `(Hub, asset)` and its `coverDeficit(borrowSpoke, maxAmount)` covers only CDP Spokes on its DAO-set allowlist, at most `min(maxAmount, recorded deficit, funded balance)`, in its own asset (`SpokeNotAllowlisted`); no Coverage Spoke can cover a deficit in another asset (Source: Q-142, Q-190, Q-236) |
| Result | Launch condition — Aave Labs confirms the coverage caller and its allowlist enforcement for every Coverage Spoke before its asset's `drawCap` rises above 0 |
| Checks | MATH-ST-50, TEST-199 |

### ATTACK-091: Cap bypass or lockout through counter drift

| Field | Value |
|---|---|
| Target | Exposure counters in Collateralization |
| Objective | Pledge low and exit high to push counters down, or leave phantom exposure, through repeated cycles or split exits |
| Affected steps | `DEP`, `WDR`, `LIQ` |
| Prerequisites | Price movement between pledge and exit |
| Attack approach | Cycle pledge and withdraw; split liquidations into many pieces |
| Impact | Market above its cap, or new pledges blocked |
| Expected protection | `INV-027`: Collateralization's counters charge the remaining backing from the original pledge (`ceil(originalUsdCharge × remainingUnits / originalUnits)`), independent of how exits are split (Source: Q-109, Q-158, Q-174, Q-240) |
| Result | Mitigated |
| Checks | MATH-UO-25, MATH-UO-26, MATH-UO-27 |

### ATTACK-095: Share inflation or drift on the vault-token asset

| Field | Value |
|---|---|
| Target | Hub vault-token asset |
| Objective | Make Hub shares differ from assets so Aave's rounding and Avana's units disagree |
| Affected steps | `DEP`, `WDR`, `LIQ` |
| Prerequisites | Interest, fees or draws on the vault-token asset |
| Attack approach | Borrow the vault asset through any Spoke with a draw cap; accrue interest |
| Impact | Under-backed tokens over many operations |
| Expected protection | `INV-004`, `INV-029`: zero draw caps and drawn shares on the asset, no reinvestment controller, no liquidity fee; new-account pledges, borrow, withdraw-with-debt and liquidation stop if shares ≠ assets (Source: Q-068, Q-070, Q-181, Q-189, Q-206) |
| Result | Mitigated |
| Checks | MATH-AR-27 |

### ATTACK-096: Value extraction through rounding loops

| Field | Value |
|---|---|
| Target | Adapter mint and burn, seizure, oracle, repay and payout conversions |
| Objective | Gain one unit per operation and repeat |
| Affected steps | `DEP`, `WDR`, `LIQ`, `REP`, `BOR` |
| Prerequisites | Cheap gas; low-decimal markets; debt assets with 6 decimals (USDC, USDT) next to 18-decimal ones (GHO, WETH) |
| Attack approach | Loop one-unit pledges, withdrawals, borrows and repays in each debt reserve; split liquidations to round the oracle value of a 6-decimal debt in the attacker's favour |
| Impact | Slow value leak |
| Expected protection | `INV-001`, `INV-032`, `INV-066`, `INV-070`: the AaveAdapter mints exactly the credited units and burns exactly the released or seized units, so mint, burn and seizure are in exact units; oracle values and payouts round against the caller; the recovery floor values one raw unit of each token in debt units rounded up (`U`, 2.11 `SPEC-LIQ-005`), so a 6-decimal debt is never undercounted, and the recovered amount `R` is measured as a balance change, not computed; debt amounts and health factors are Aave's own at the reserve's decimals; every pledge is at least `minPledgeUsd`; a 10⁶-iteration one-unit round-trip test shows no gain (Source: Q-066, Q-119, Q-190, Q-191, Q-224, Q-230, Q-235) |
| Result | Mitigated |
| Checks | HYP-40, HYP-46, HYP-47, HYP-48, TEST-198 |

## Reentrancy

### ATTACK-092: Cross-contract reentrancy during settlement

| Field | Value |
|---|---|
| Target | AaveAdapter, Collateralization, LPVault, LPVaultSwap, proxies, swap routes |
| Objective | Re-enter withdrawal, pledge or fee collection while backing records are half-updated |
| Affected steps | `LIQ` collect and conversion; `FEE`; `WDR`; `DEP` |
| Prerequisites | A hook token or a malicious pool on a route |
| Attack approach | Re-enter `collectFees` between `decreaseLiquidity` and the capped `collect`; re-enter through a swap callback of a swap route; re-enter the AaveAdapter during a pledge between the Collateralization record and the mint |
| Impact | Fees or liquidity taken twice; vault tokens minted without a record |
| Expected protection | `INV-054`, `INV-066`: one immutable Lock with exactly two members, the AaveAdapter and LPVaultSwap (`INV-091`); every outer entry point of a member acquires it, and every value-moving entry point of Collateralization and each LPVault accepts only a member's call while the Lock is held, so nothing can be re-entered while it is held; the `IFlashSource` callback of repay with collateral, the flash liquidation helper's callback and the swap-route callbacks keep their own caller checks, and `liquidate` takes no flash loan; checks-effects-interactions (Source: Q-148, Q-223, Q-235, Q-404) |
| Result | Mitigated |
| Checks | None |

### ATTACK-093: Read-only reentrancy on the Lens or LPOracle

| Field | Value |
|---|---|
| Target | Lens, Collateralization views, LPOracle |
| Objective | Feed false backing data to an on-chain integrator mid-settlement |
| Affected steps | `LIQ` |
| Prerequisites | An integrator reading Avana views on-chain |
| Attack approach | Read views from inside a callback |
| Impact | Integrator acts on inconsistent state |
| Expected protection | `INV-054`, `INV-055`: record and backing views of Collateralization revert while the Lock is held; LPOracle reads no pool state (Source: Q-119, Q-128, Q-148) |
| Result | Mitigated |
| Checks | None |

### ATTACK-094: Reentrancy through a native ETH payout

| Field | Value |
|---|---|
| Target | Payouts, WETH debt reserve |
| Objective | Re-enter through a recipient's `receive` |
| Affected steps | `FEE`, `LIQ`, `BOR`, `REP` |
| Prerequisites | An ETH payout path |
| Attack approach | Receive ETH and re-enter, for example on a borrow or repay of a WETH debt reserve |
| Impact | State corruption |
| Expected protection | No native ETH paths in the Uniswap v3 and Slipstream integrations: their pools hold ERC-20 tokens, WETH is listed as an ERC-20 debt asset that is never unwrapped, and every borrow, repay, swap and payout is an ERC-20 transfer; an AMM protocol with native ETH uses the integration's native-ETH hook, which wraps before any value leaves the LPVault (Source: Q-032, Q-233, Q-363) |
| Result | Mitigated |
| Checks | None |

## Governance

### ATTACK-097: Abuse of timelock and pause powers

| Field | Value |
|---|---|
| Target | AvanaTimelock, pause guardians |
| Objective | Shorten delays, hide a malicious operation in queue spam, halt liquidation, or cancel every fix |
| Affected steps | `EMG`, `MKT` |
| Prerequisites | Compromised governance multisig, Emergency Guardian or Aave Protocol Guardian |
| Attack approach | Grant an admin role to an address other than the timelock; change roles or delays without the timelock; lower the normal delay; add a selector to the short-delay list; schedule a normal-delay change on the short delay; flood the queue; pause repeatedly; cancel every repair operation |
| Impact | Malicious change lands, or the application stays paused |
| Expected protection | `INV-049`, `INV-051`, `INV-067`, `INV-068`, `INV-084`, `INV-090`: the timelock is immutable and holds its own `DEFAULT_ADMIN_ROLE` with no bypass, and every upgradeable Avana contract reverts `AdminRoleOnlyTimelock` on a grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to any other account; `schedule` requires a delay of at least `requiredDelay(targets, payloads)`, which is the short delay only when every call is on the short-delay list, and `setShortDelaySelector` can enable only pairs in the constructor-fixed `SHORT_ELIGIBLE` set (`InvalidShortDelaySelector`); `updateDelay` reverts and `setNormalDelay` accepts only `[MIN_NORMAL_DELAY, MAX_DELAY]` = [4 days, 5 days] (`DelayOutOfBounds`); every queued operation is public and any canceller can cancel it, except role changes and operations whose every call restores liquidation or an address (`restoreRoute`, `useStandbyRoute`, `addKeeper`, `unfreezeAddress`), which only the Aave governance executor can cancel (`RestoringCancelRestricted`), so a guardian can neither protect itself nor keep a market unliquidatable by cancelling its repairs; a pause stops only new pledges and non-rescue top-ups (every pledge under `MintPathSuspect`), borrowing, withdraw-with-debt, removal with debt and repay with collateral, never liquidation, repay or debt-free withdrawal; a canceller's own role can be revoked (Source: Q-047, Q-136, Q-137, Q-227, Q-228, Q-252, Q-259, Q-262, Q-263) |
| Result | Mitigated |
| Checks | TEST-192, TEST-194, TEST-242, TEST-244 |

### ATTACK-098: Pause guardian used as an instant loosen key

| Field | Value |
|---|---|
| Target | MarketRegistry `unpause` and `unfreeze` |
| Objective | Lift an emergency pause or freeze instantly and exploit it in the same bundle |
| Affected steps | `EMG`, `BOR`, `LIQ` |
| Prerequisites | Compromise of a pause-guardian Safe (Emergency Guardian or Aave Protocol Guardian), optionally a keeper key |
| Attack approach | The application is paused during a depeg; the compromised guardian calls `unpause()` and the attacker borrows at a stale peg in the same bundle; or uses the unpaused state to liquidate through a route that governance had queued for disabling |
| Impact | Borrowing that the pause was meant to stop |
| Expected protection | `INV-023`, `INV-024`, `INV-034`, `INV-049`, `INV-050`: `unpause` and `unfreeze` restore only the application state; every borrow still passes the RiskModule's gates (every collateral market Live, every price within `borrowPriceMaxAge`, no Aave reserve frozen or paused, no `Offboarding` market, no drift, HF ≥ max(1, the market's `hardHealthFloor` where set, caller's minimum)), and those gates are not guardian-controlled; Aave's own reserve freezes and pauses are a separate source the Avana guardians cannot lift; no parameter, route or keeper can be loosened outside the normal delay, and a restored route (`restoreRoute`) must be one previously approved, runs at the short delay, can be cancelled only by the Aave governance executor, and is still bound by the recovery floor and the per-leg minimums; the circuit breakers keep blocking borrowing against a tripped market after an unpause; the other guardian or `APPLICATION_ADMIN` can pause again at once (Source: Q-151, Q-227, Q-228, Q-229, Q-241, Q-263) |
| Result | Accepted risk — owner: Avana Labs (Emergency Guardian signers) and the Aave Protocol Guardian; bound: borrowing reopened by an unpause is still limited by every RiskModule gate, the Aave HF and the `drawCap` of each debt reserve, and lasts until either guardian or `APPLICATION_ADMIN` pauses again |
| Checks | TEST-192, FINDING-079 |

### ATTACK-099: Waiting for an emergency pause to lapse during a live exploit

| Field | Value |
|---|---|
| Target | Application pause state |
| Objective | Let a pause or freeze set against an exploit lapse so the path reopens |
| Affected steps | `EMG` |
| Prerequisites | An ongoing exploit |
| Attack approach | Wait for a pause deadline |
| Impact | None: no deadline exists |
| Expected protection | `INV-049`, `INV-050`, `INV-067`: `Frozen` and `Paused` have no expiry and change only by an explicit call — `unfreeze` or `unpause` by `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`; the freeze guardian cannot unfreeze, and unfreezing while Paused reverts (`CannotUnfreezeWhilePaused`); because no pause state stops liquidation, repay or debt-free withdrawal, a pause can stay in place as long as the exploit needs without halting settlement (Source: Q-137, Q-227) |
| Result | Mitigated |
| Checks | TEST-192, FINDING-080 |

### ATTACK-100: Short-delay tightening that halts liquidation

| Field | Value |
|---|---|
| Target | Tightening setters on the short-delay list |
| Objective | Halt liquidations with changes that count as safer, then rely on the slower loosen path |
| Affected steps | `EMG`, `LIQ` |
| Prerequisites | Governance multisig compromise |
| Attack approach | Schedule on the short delay: the slippage allowance at its minimum, a deeper grace bound, a tighter TWAP tolerance, and `disableRoute` for every swap route |
| Impact | Liquidations fail until the loosening change clears the normal delay |
| Expected protection | `INV-047`, `INV-068`: every tightening runs at the short delay (12 hours) where any canceller can cancel it; on-chain bounds keep every accepted value of the liquidation settings live — the minimum slippage allowance stored per market at listing and the global immutable bounds on grace HF, grace duration and TWAP tolerance; disabling routes is not a slow-to-undo change: `restoreRoute` of a previously approved route is itself a short-delay operation, so a disable that slipped past the cancellers is undone 12 hours later, and while some token of a market has no usable swap route into a debt asset, the RiskModule blocks new borrowing and withdraw-with-debt for the accounts concerned (`LiquidationHalted`); a halt that long sits inside the 48-hour incident window the caps are sized for (`Q-192`) (Source: Q-139, Q-192, Q-206, Q-209, Q-228) |
| Result | Mitigated |
| Checks | MATH-ST-13, TEST-194, FINDING-081 |

### ATTACK-101: Rogue guardian blocks rescue top-ups

| Field | Value |
|---|---|
| Target | Application pause state, timelock cancellation |
| Objective | Stop indebted borrowers adding collateral so their positions are liquidated, and cancel every repair |
| Affected steps | `DEP` top-up; `EMG` |
| Prerequisites | Compromise of the Emergency Guardian (pause guardian and canceller) |
| Attack approach | Call `pause(General)`, trip the market breaker and freeze the borrower's address; when that fails, call `pause(MintPathSuspect)`; re-pause after every unpause; cancel each scheduled `unpause` and the operations that revoke its roles |
| Impact | Under `Paused(General)`, a breaker or an address freeze: none, rescue top-ups stay open. Under `Paused(MintPathSuspect)`: indebted borrowers cannot add collateral; they can still repay any debt reserve, and their positions are liquidated under the normal rules |
| Expected protection | `INV-026`, `INV-043`, `INV-050`, `INV-067`, `INV-068`, `INV-081`: a rescue top-up (an indebted account below `rescueHealthFactor` (1.10), charge at most the amount that restores it, value at least `min(minPledgeUsd, $10)`) passes `Paused(General)`, every breaker, the pool-share cap and the address freeze (`REQ-RISK-066`, `REQ-RISK-067`); only `Paused(MintPathSuspect)` refuses it, because that reason means minting itself may be unsafe; Frozen leaves top-ups of indebted accounts open; repay never reads the pause state, so a borrower can always restore HF by repaying; the Aave Protocol Guardian also holds `APPLICATION_PAUSE_GUARDIAN` and unpauses at once; an operation that only revokes roles is cancellable only by the Aave governance executor, so the rogue guardian cannot block its own removal (Source: Q-164, Q-227, Q-228, Q-241, Q-242, Q-252) |
| Result | Accepted risk — owner: Aave Protocol Guardian and Aave governance (unpause and revocation); bound: rescue top-ups blocked only under `Paused(MintPathSuspect)`, at most until the Aave Protocol Guardian unpauses or the revocation executes after the normal delay (5 days); no solvency effect, since liquidation, repay and debt-free withdrawal stay open |
| Checks | TEST-192, TEST-194, TEST-235, FINDING-091 |

### ATTACK-102: Unsafe Spoke reconfiguration outside Avana review

| Field | Value |
|---|---|
| Target | CDP Spoke and Hub configuration (Aave DAO) |
| Objective | Change CF, bonus, liquidation fee, `receiveSharesEnabled`, `borrowable`, price sources, caps, collateral risk, the enabled debt-reserve set or Spokes on the vault-token asset without Avana's review |
| Affected steps | `MKT`, `BOR`, `LIQ` |
| Prerequisites | Aave DAO action or compromised Aave role |
| Attack approach | Set a dynamic config with CF 0 while debt exists (collateral unseizable); raise collateral risk above the threshold; change a debt reserve's price source; try to enable a fee or make a vault-token reserve borrowable, which the CDP Spoke rejects in code (`UnsupportedLiquidationFee()`, `UnsupportedBorrowableCollateral()`); deploy a Spoke implementation with a different `APPROVED_DEBT_RESERVES` |
| Impact | Unliquidatable or unbacked positions |
| Expected protection | `INV-029`, `INV-073`: the RiskModule's drift check on every new-account pledge and borrow covers the vault-token reserves, the debt-reserve set (`DebtReserveSet`) and each debt reserve's price source (`DebtPriceSource`) and blocks new risk on any difference; adding a debt reserve needs a new Spoke implementation that Avana re-approves; deployment and monitoring re-check required settings; CF cuts go by AIP with an Aave reserve freeze or the MarketRegistry's `Offboarding` status; offboarding never sets CF to 0 while debt exists (Source: Q-080, Q-110, Q-143, Q-172, Q-178, Q-181, Q-281, Q-238) |
| Result | Accepted risk — owner: Aave DAO (configuration is DAO-owned) |
| Checks | MATH-AR-25, MATH-ST-12, TEST-204 |

### ATTACK-103: Aave Guardian pauses a reserve with no expiry

| Field | Value |
|---|---|
| Target | SpokeConfigurator `pauseReserve` held by the Aave Protocol Guardian |
| Objective | Block liquidation (and withdrawal) of a market or of accounts holding a debt reserve beyond the 48-hour incident window |
| Affected steps | `EMG`, `LIQ`, `WDR` |
| Prerequisites | Aave Guardian compromise or error |
| Attack approach | Call the one-way `pauseReserve` on a vault-token reserve or on a debt reserve (GHO, USDC, USDT, WETH) |
| Impact | Liquidation of the affected accounts blocked until a DAO vote unpauses; bad debt can grow |
| Expected protection | `INV-060`, `INV-067`: Avana's own pause state never stops liquidation; an Aave reserve pause is a separate source Avana cannot lift. The deployment AIP asks the Aave DAO to pause Avana vault-token and debt reserves only for exploits and to unpause within the 48-hour incident window; caps are sized for such a pause with the pause-loss bound over that window, including a debt-asset price-rise term; while a reserve is paused the RiskModule reverts borrow and withdraw-with-debt with `AaveReservePaused(reserveId)` for any paused vault-token reserve of the account and `DebtReservePaused(debtReserveId)` for any paused debt reserve of the account or the one being borrowed, so no new debt is added against collateral that cannot be liquidated (Source: Q-050, Q-118, Q-192, Q-202, Q-209, Q-227, Q-234) |
| Result | Accepted risk with AIP commitment (`Q-202`) — owner: Aave DAO; bound: caps sized with the pause-loss bound over the 48-hour incident window (`Q-192`) |
| Checks | QNT-33 (Quint counterexample C-QNT-2, accepted with AIP commitment, Q-202), QNT-T13, TEST-158, FINDING-042 |

### ATTACK-104: Exploit through a malicious market listing

| Field | Value |
|---|---|
| Target | Market and debt-reserve listing |
| Objective | Pass the timelock window with a listing whose oracle, pool, token, route or debt-reserve record refer to different markets or assets, or whose feed is thin or derived from the pool |
| Affected steps | `MKT` listing |
| Prerequisites | A listing proposal |
| Attack approach | Wire the LPOracle to another pool or an attacker feed; record a debt reserve with a wrong Hub, price source, Coverage Spoke, funding Hub or swap route |
| Impact | Credit-line exploit through governance |
| Expected protection | `INV-005`, `INV-051`, `INV-068`, `INV-073`: the Avana half of a listing is one normal-delay batch (5 days) — `deployVaultToken`, `listToken`, `listCollateralMarket`, the initial caps and `minPledgeUsd`, routes, and for a debt reserve `enableDebtReserve` and its swap routes — visible in the queue and cancellable by any canceller; a registered market can be cancelled with `cancelRegistration` (short delay); `activateMarket` (short delay, 12 hours) succeeds only when the on-chain match check against the executed Aave listing payload passes (vault token, factory-derived pool, Spoke reserve, Hub asset, feeds and routes all belong to one market; the debt-reserve set equals the Spoke's), plus the off-chain live-config check (Source: Q-043, Q-091, Q-114, Q-119, Q-128, Q-228, Q-233, Q-281) |
| Result | Launch condition — on-chain match check and live-config check pass for every market and debt reserve before activation |
| Checks | TEST-204 |

## Off-chain, signatures and dependencies

### ATTACK-105: Approval phishing through compromised transaction preparation

| Field | Value |
|---|---|
| Target | Convex, web app |
| Objective | Return `setApprovalForAll(attacker)` or a borrow with the attacker as receiver from the backend |
| Affected steps | All user flows (preparation) |
| Prerequisites | Convex compromise |
| Attack approach | Serve malicious targets or calldata |
| Impact | Theft from every user who signs |
| Expected protection | `INV-022`: the browser builds calldata from a bundled verified manifest; Convex never supplies a target or calldata (Source: Q-073, Q-149) |
| Result | Mitigated |
| Checks | None |

### ATTACK-106: Misdirected action through a spoofed reserve, Spoke or proxy

| Field | Value |
|---|---|
| Target | AaveAdapter entry points |
| Objective | Make a user act on the wrong reserve or Spoke, or repay another account's debt |
| Affected steps | `REP`, `WDR`, `BOR` |
| Prerequisites | A stale or poisoned mapping in the app |
| Attack approach | Supply a wrong Spoke, debt-reserve ID or borrower |
| Impact | User funds misapplied |
| Expected protection | `INV-016`, `INV-017`, `INV-064`: the AaveAdapter resolves the proxy from `msg.sender` and the named Spoke for pledge, borrow and withdrawal, so a user can only act on its own account; for a pledge and a borrow the Spoke must be approved (`UnknownSpoke`) and the borrowed reserve in its approved set (`UnknownDebtReserve`); repay and withdrawal read no MarketRegistry state: a withdrawal resolves the reserve from the vault token's own Hub and Spoke (`vaultToken.spoke() == spoke`, the token checked against the VaultTokenFactory), and a repay of a reserve the Spoke does not lend reverts inside the Spoke; a repay naming another borrower only lowers that account's debt with the payer's own funds and never moves collateral or debt asset out of it, and the app shows the target borrower before a repay of another account; every borrow names an explicit receiver (Source: Q-075, Q-122, Q-126, Q-212, Q-223, Q-233, Q-260) |
| Result | Mitigated |
| Checks | None |

### ATTACK-107: Indexer poisoning

| Field | Value |
|---|---|
| Target | Ponder, keeper candidate lists, app displays |
| Objective | Lead users to counterfeit positions or hide liquidatable accounts from keepers |
| Affected steps | `DEP` discovery; `LIQ` candidate selection |
| Prerequisites | Indexer compromise, reorgs, or counterfeit NFTs sent to users |
| Attack approach | Inject candidates; spoof events |
| Impact | Wrong approvals; missed liquidations |
| Expected protection | Keepers and the app re-check every indexed candidate by RPC at a fixed block; proxies are enumerated from the ProxyManager's `ProxyDeployed` and the AaveAdapter's `UserProxyCreated` events through two RPC sources and checked against `predictProxy(wallet, spoke)`; displayed HF and debts per reserve re-read from RPC (Source: Q-073, Q-119, Q-144, Q-225) |
| Result | Mitigated |
| Checks | None |

### ATTACK-108: Web bundle or manifest supply-chain swap

| Field | Value |
|---|---|
| Target | Released web bundle and deployment manifest |
| Objective | Swap the AaveAdapter, LPVault or proxy address so users approve an attacker |
| Affected steps | `DEP` approval; `REP` approval |
| Prerequisites | Compromise of the release pipeline |
| Attack approach | Publish a tampered bundle |
| Impact | NFT or debt-asset approvals to the attacker |
| Expected protection | Manifest approval by governance multisig signers; before requesting approvals the app cross-checks key addresses on-chain: the vault token's `adapter()` and `collateralization()`, Collateralization's `LP_VAULT()`, the AaveAdapter's `PROXY_MANAGER()`, and the ERC-1967 implementation slots of the AaveAdapter and the ProxyManager and the proxy code hash against the manifest (Source: Q-043, Q-073, Q-226) |
| Result | Accepted risk — owner: Avana Labs (release operations) |
| Checks | FINDING-085 |

### ATTACK-109: Signature replay or permit front-running

| Field | Value |
|---|---|
| Target | Any Avana signature path |
| Objective | Replay a borrower signature on another chain or contract, or front-run a permit to make the user's transaction revert |
| Affected steps | `DEP`, `REP` |
| Prerequisites | A captured signature |
| Attack approach | Replay; submit the permit first |
| Impact | Unintended actions or griefing |
| Expected protection | No Avana contract accepts off-chain signatures in v1; borrower actions are direct calls from the wallet to the AaveAdapter, and fee collection and zero-credit release are direct calls to the LPVault and Collateralization (Source: Q-093, Q-119, Q-123, Q-223) |
| Result | Mitigated |
| Checks | None |

### ATTACK-110: Dependency behaviour change after listing

| Field | Value |
|---|---|
| Target | External contracts ([4.3](03-external-dependencies.md)) |
| Objective | Rely on an upgrade or configuration change in USDC, USDT, WETH, GHO, Chainlink proxies (pool-token, debt-asset and sequencer-uptime feeds), the Aave V3 Pool behind `IFlashSource` and the flash liquidation helper, PSM, Aave V4 contracts, each AMM protocol's position manager and factory or the OpenZeppelin code Avana builds on to break an Avana assumption |
| Affected steps | All |
| Prerequisites | External party's action |
| Attack approach | Change a fee, decimals, aggregator or implementation under Avana |
| Impact | Depends on the dependency; listed per `EXT-NNN` |
| Expected protection | Monitoring of implementation and configuration changes with the response runbook (application freeze or pause, Aave reserve freeze, short-delay tightening); no Avana logic assumes code at an external address is fixed; per-read feed checks for collateral and debt feeds; OpenZeppelin UUPS, `TimelockController` and `AccessControl` are pinned at a reviewed version and compiled into Avana's own bytecode, so they change only with an Avana upgrade through the timelock (Source: Q-048, Q-080, Q-091, Q-119, Q-191, Q-226, Q-238) |
| Result | Accepted risk — owner: Avana Labs (monitoring and the response runbook) |
| Checks | None |

## Settlement recovery, Aave reserve pauses and persistent disagreement

### ATTACK-111: Liquidation at a disputed price after the disagreement window

| Field | Value |
|---|---|
| Target | LPOracle, LPVaultSwap |
| Objective | Wait out the feed-disagreement pause so liquidation resumes at a faulty primary price |
| Affected steps | `LIQ`; `EMG` price-state handling |
| Prerequisites | Its own `liquidate` call; a primary feed fault that lasts longer than `disagreementPauseMax` |
| Attack approach | Keep the faulty primary route reporting a depeg that the alternate route does not show; once `disagreementPauseMax` has passed since the disagreement began, liquidate accounts that the alternate route shows as healthy |
| Impact | None: liquidation stays blocked. Without the rule, healthy accounts would lose the bonus |
| Expected protection | `INV-030`, `INV-059`, `INV-087`: after `disagreementPauseMax` a market whose routes still disagree is treated as Expired for its own seizure until the routes agree again, the Emergency Guardian switches the faulty route to its reviewed standby, or governance approves a fix; meanwhile the market counts at the lower of its two route prices in the account's HF, so the account's other fresh reserves stay liquidatable; the pause start is the first disagreement stored by `poke()` or any successful Avana call, and keepers poke every heartbeat, so the start reflects when the fault appeared; borrowing stays blocked; repay and debt-free withdrawal stay open (Source: Q-162, Q-183, Q-199, Q-208, Q-247, Q-248) |
| Result | Mitigated |
| Checks | TEST-157, TEST-159, TEST-230, TEST-231 |

### ATTACK-112: New debt against a reserve Aave has paused

| Field | Value |
|---|---|
| Target | AaveAdapter, RiskModule, CDP Spoke |
| Objective | Borrow, or withdraw collateral while keeping debt, while a vault-token reserve or a debt reserve of the account is paused on Aave, so the added risk cannot be liquidated until the Aave DAO unpauses |
| Affected steps | `BOR`, `WDR`; `EMG` |
| Prerequisites | An Aave Guardian pause of a vault-token reserve the account holds, or of one of its debt reserves |
| Attack approach | While seizure or repayment through the paused reserve is impossible, call `AaveAdapter.borrow` on another debt reserve, or withdraw a record in another market while debt remains |
| Impact | None: the call reverts. Without the check, debt would grow against collateral that cannot be seized during the pause |
| Expected protection | `INV-060`, `INV-072`: the AaveAdapter calls `RiskModule.preBorrowCheck` and `preWithdrawCheck`, which check every vault-token reserve and every debt reserve of the account plus the one being borrowed, and revert with `AaveReservePaused(reserveId)` for a paused vault-token reserve and `DebtReservePaused(debtReserveId)` for a paused debt reserve; repay of unpaused debt reserves and debt-free withdrawal of unpaused markets stay available. A faulty RiskModule implementation that drops the check is bounded by Aave's own checks (the Spoke rejects borrowing a paused reserve, HF ≥ 1) and the `drawCap` of each debt reserve (Source: Q-202, Q-209, Q-229, Q-234) |
| Result | Mitigated |
| Checks | TEST-158, TEST-201 |

### ATTACK-113: Theft or over-debit through the pending-settlement balance

| Field | Value |
|---|---|
| Target | Collateralization reconcile on exit, LPVault liquidity removal, LPVaultSwap |
| Objective | Take the pool tokens held for pending-settlement units or the debt asset they convert to, or make a reconcile debit more than the unsettled seizure |
| Affected steps | `WDR` reconcile; `LIQ` settlement |
| Prerequisites | Hostile LPVaultSwap installed through the timelock at the normal delay (5 days), or a borrower whose proxy has an unsettled seizure |
| Attack approach | Ask Collateralization to release pending liquidity without the matching vault tokens being burned; burn fewer units than the pending units and claim all of the pool tokens; trigger a reconcile on an account whose supply matches its records so that healthy records are debited; trigger a hostile seizure and then call `settlePending` to collect the proceeds or to route the pool tokens through a pool the caller has moved |
| Impact | None beyond the hostile seizure of `ATTACK-026` |
| Expected protection | `INV-008`, `INV-010`, `INV-053`, `INV-058`, `INV-066`: Collateralization measures the shortfall itself as the proxy's credited units minus its Spoke supply in that market and debits exactly that, in list order from the head, so an account with no shortfall is never debited; `settlePending` burns vault tokens only through the AaveAdapter's `burnSeized` from LPVaultSwap's own balance, and Collateralization then requires `totalSupply + units ≤ totalCredited + pending.units` before it debits, so liquidity is released only for units already burned, at most the pending units and pro rata to them, and only to LPVaultSwap through `LPVault.removeLiquidity`; outstanding vault tokens stay backed throughout; LPVaultSwap swaps the released pool tokens into the market's pending-settlement asset, reverts unless the amount meets the `minPending` floor (oracle value less the slippage allowance and rounding terms), and sends all of it to the Coverage Spoke of the market's (Hub, that asset) in the same call (2.11 `REQ-SWAP-066`), so the caller of `settlePending` and the borrower receive nothing and a caller cannot sell the tokens cheaply to itself (Source: Q-160, Q-201, Q-211, Q-224, Q-236, Q-257) |
| Result | Mitigated |
| Checks | TEST-151, TEST-152, TEST-153, TEST-154, TEST-170, TEST-208 |

## Open liquidation entry point, third-party repay and payout escrow

### ATTACK-114: Griefing through tiny liquidations by any caller

| Field | Value |
|---|---|
| Target | `LPVaultSwap.liquidate`, committed operators |
| Objective | Keep an account below HF 1 for longer, or waste keeper gas, by front-running keepers with liquidations of a few units, in any debt reserve |
| Affected steps | `LIQ` |
| Prerequisites | An account below HF 1; gas; the debt asset to fund the call, held or borrowed through the flash liquidation helper |
| Attack approach | Call `liquidate` with a tiny `debtToCover` ahead of each keeper call, so each keeper transaction finds a slightly different state, or try a `debtToCover` that seizes 0 units; pass a `debtToCover` far above what Aave consumes, borrowed through the helper, so the premium on the unused part grows |
| Impact | None beyond the attacker's gas and funds: each call that completes repays debt and seizes collateral under the same rules as any other call, so it moves the account toward HF ≥ 1 |
| Expected protection | `INV-030`, `INV-034`, `INV-062`, `INV-070`: a call that seizes 0 units reverts `NothingSeized`; every completed call must meet the recovery floor and no Avana contract funds any gap (`Q-397`), so a tiny call costs the caller gas and pays at most its share of the realized surplus; LPVaultSwap returns the unused `Kf − D` of an oversized `debtToCover` inside `keeperOut`, and a helper's premium on an oversized loan is paid from its caller's own payout (2.11 `REQ-HELPER-007`); keepers size `debtToCover` per call from a fresh simulation and their `deadline` and `minPayout` make a keeper transaction that lands after a front-run revert cheaply instead of executing on changed terms; Aave's dust rule forces the last small debt to be liquidated in full (Source: Q-169, Q-213, Q-215, Q-216, Q-235, Q-404) |
| Result | Mitigated |
| Checks | TEST-160, TEST-174, TEST-176, TEST-197 |

### ATTACK-115: Sandwiching the routes of a caller's own liquidation

| Field | Value |
|---|---|
| Target | Settlement routes of `liquidate` |
| Objective | Move a route pool before the caller's own liquidation, sell the seized tokens cheaply to it and buy back after |
| Affected steps | `LIQ` conversion |
| Prerequisites | Capital to move a route pool; the ability to order transactions around its own liquidation |
| Attack approach | Push the backup DEX route off price, call `liquidate` with `BackupOnly` so the conversion runs through the moved pool, then reverse the move |
| Impact | Bounded by the recovery floor: the conversion must still return at least `minRec`, the seized backing's oracle value less the effective slippage and the rounding terms |
| Expected protection | `INV-034`, `INV-062`, `INV-083`: `liquidate` uses only the market's fixed primary and backup routes, never a caller-chosen route, whichever route mode the caller picks; the recovery floor and every leg's minimum output (`SPEC-LIQ-018`) are computed from oracle prices, not the pool spot, so a sandwich can extract at most `sLeg × Vleg + Uleg + ⌊ε / n⌋` per leg (`ε = floorRoundingAllowance(spoke, r)`), the slippage allowance already granted to every liquidator; a shortfall reverts `MinOutNotMet`, or `RecoveryBelowFloor` when the caller does not top up the floor gap; `InsufficientProceeds` cannot occur, because `Kf ≥ D` keeps `keeperOut ≥ 0`; routes never use the pool being unwound (Source: Q-085, Q-159, Q-187, Q-213, Q-250, Q-273, Q-404) |
| Result | Mitigated |
| Checks | TEST-050, TEST-174, TEST-227, TEST-232 |

### ATTACK-116: Billing a settlement gap to Avana through an unregistered caller

| Field | Value |
|---|---|
| Target | Settlement of `liquidate` for any caller |
| Objective | Have Avana pay for loss-making liquidations, including a helper's flash premium, or take oracle-valued pool tokens without being a committed operator |
| Affected steps | `LIQ` |
| Prerequisites | Any address |
| Attack approach | Call `liquidate` on an account whose routed proceeds fall short of the debt repaid, through the flash liquidation helper so a premium is owed, or while both swap routes into the debt asset fail |
| Impact | None for Avana: each loss falls on the caller, or the call reverts |
| Expected protection | `INV-037`, `INV-039`, `INV-062`, `INV-070`: no Avana contract funds a settlement gap (the SettlementBudget is removed, `Q-397`): the caller funds `D` out of `Kf`, so a recovery below `D` lowers only its `keeperOut`, a recovery below the floor that it does not top up reverts `RecoveryBelowFloor`, and a helper whose `keeperOut` cannot repay `F + φ` within its top-up bound reverts `TopUpExceeded` (2.11 `REQ-HELPER-007`); there is no in-kind settlement (`Q-401`), so both swap routes into the debt asset failing reverts `NoRouteAvailable`; no caller earns a reimbursement (Source: Q-133, Q-163, Q-167, Q-213, Q-235, Q-397, Q-401, Q-404) |
| Result | Mitigated |
| Checks | TEST-174, TEST-197, PROP-053 |

### ATTACK-117: Front-running a borrower's repay with a third-party repay

| Field | Value |
|---|---|
| Target | `AaveAdapter.repay` |
| Objective | Make a borrower's repay revert or overpay, or use a repay to move value out of the account |
| Affected steps | `REP` |
| Prerequisites | Any address holding the debt asset |
| Attack approach | Watch the mempool for a borrower's repay-all of one debt reserve and land a third-party repay of part or all of that debt first; or call `repay` naming another borrower hoping to pull that borrower's funds |
| Impact | None for the borrower: the debt is lower and the borrower's later call costs nothing extra |
| Expected protection | `INV-016`, `INV-043`: `AaveAdapter.repay(borrower, spoke, debtReserveId, maxRepaySpend, repayAll, deadline)` pulls the debt asset only from `msg.sender`, who approved the AaveAdapter, sends it to the named borrower's proxy for that Spoke, repays only that reserve of that account and refunds the unspent amount to `msg.sender`; the borrower's later repay reads the live debt, so a repay-all pulls only what remains under its signed cap and at zero debt returns 0 with no token movement; `borrow`, `withdraw` and `repayAllAndWithdraw` resolve the proxy from `msg.sender`, so a third party can lower the debt but never move collateral or debt asset out. Example: USDC debt 1,000 USDC; a third party repays 600 USDC first; the borrower's repay-all with `maxRepaySpend` 1,050 USDC pulls 400 USDC plus accrued interest; had the third party repaid all 1,000 USDC, the borrower's call would return 0 (Source: Q-180, Q-209, Q-212, Q-223, Q-234) |
| Result | Mitigated |
| Checks | TEST-175, TEST-165 |

### ATTACK-118: Payout escrow claim by the wrong person

| Field | Value |
|---|---|
| Target | PayoutEscrow |
| Objective | Claim another account's escrowed payout (borrower surplus, Avana fee, a route residue or dust leg of the caller, or a `settlePending` residue owed to `feeRecipient`), or credit it to another address |
| Affected steps | `LIQ` payouts |
| Prerequisites | An account whose payout transfer failed and was escrowed; any address, or a hostile LPVaultSwap installed through the timelock at the normal delay |
| Attack approach | Call the escrow's claim for another borrower's credit; make a hostile LPVaultSwap deposit with a false borrower or amount; deposit directly to the escrow and claim |
| Impact | None for honest deposits: only the credited account (the borrower, `feeRecipient` or the caller) can claim. A hostile LPVaultSwap could misdirect the payouts of liquidations it settles during its lifetime, which it could equally do by paying the wrong address directly |
| Expected protection | `INV-061`, `INV-068`: the escrow, whose only job is to hold payouts whose transfer the token refused (`Q-401`), credits only deposits from LPVaultSwap while it holds the Lock, which never escrows the caller's `keeperOut` (paid to `msg.sender` or the call reverts), keyed by account and token, each for the measured rise of its balance capped at the amount requested, so a token that delivers less credits only what arrived and an excess stays uncredited; only the credited account (the borrower, `feeRecipient` or the caller, `Q-389`), as `msg.sender`, can claim, and a claim pays its whole credit to the recipient it names; there is no claim on behalf and no way to move a credit; credited equals claimed plus held for every account and token; the escrow is immutable, with no admin and no sweep, so donations stay where they are and change no credit. LPVaultSwap upgrades wait the normal delay (5 days) and any canceller can cancel them (Source: Q-090, Q-214, Q-226, Q-228, Q-401, Q-404) |
| Result | Mitigated |
| Checks | TEST-173, TEST-179, PROP-052 |

### ATTACK-119: Stale pending liquidation executed late

| Field | Value |
|---|---|
| Target | Liquidation transactions of any caller, direct or through the flash liquidation helper |
| Objective | Hold back a liquidation transaction (for example one that fell back to the public mempool, or one built from a Lens preview) and let it execute later at a stale price, a worse payout or a costlier conversion |
| Affected steps | `LIQ` |
| Prerequisites | A builder or searcher that can delay inclusion |
| Attack approach | Delay inclusion until prices, route depth or the debt asset's price have moved, then include the transaction |
| Impact | None beyond a reverted transaction: the caller's terms are enforced at execution |
| Expected protection | `INV-030`, `INV-070`: `LiquidationParams` carries `debtReserveId`, `deadline` and `minPayout`, and the helper's request adds its own net `minPayout`, `maxPremium` and `maxTopUp` (2.11 `REQ-HELPER-008`); the call reverts `DeadlineExpired(deadline)` as its first check after the deadline, and `PayoutTooLow(keeperOut, minPayout)` if the caller's payout in the debt asset fell below what it accepted; the Lens returns `minPayout = 0` together with the expected payout so the caller sets its own floor; none of these inputs changes any amount, route or recipient, and the recovery floor protects Avana's take whatever the timing. The keeper service re-sends a transaction not mined within a fixed number of blocks at the same nonce with a higher fee and, once its deadline has passed, frees the nonce with a zero-value self-transfer (Source: Q-216, Q-219, Q-232, Q-235, Q-404) |
| Result | Mitigated |
| Checks | TEST-176, TEST-178, TEST-205 |

## CDP Spoke implementation and configuration

### ATTACK-120: CDP Spoke upgrade or configuration change that reopens third-party seizure

| Field | Value |
|---|---|
| Target | Standard CDP Spoke proxy and configuration (Aave DAO) |
| Objective | Replace the standard Spoke implementation, or change its configuration, so that liquidators receive shares, a liquidation fee pays vault-token shares, a reinvestment controller moves vault tokens, or the vault-token reserve becomes borrowable |
| Affected steps | `LIQ`, `BOR`, `DEP` |
| Prerequisites | An Aave governance upgrade or configuration payload on the CDP Spoke, or a compromised Aave proxy admin or steward |
| Attack approach | Point the Spoke proxy at a new implementation, or set `receiveSharesEnabled`, a non-zero `liquidationFee` or a reinvestment controller; then liquidate Avana accounts directly and take shares |
| Impact | Third-party liquidation outside LPVaultSwap that takes shares with no ledger debit, in the block of the change; a seizure that moves tokens still reverts whenever they would go to an address the token does not accept |
| Expected protection | `INV-011`, `INV-029`, `INV-093`: the RiskModule's drift check reads the implementation through `Spoke.extSload` at the EIP-1967 slot and the required settings (`receiveSharesEnabled = false`, `liquidationFee = 0`, no reinvestment controller, vault-token reserve not borrowable) on every new-activity call, and any change trips the market's breaker, which stops new activity and never liquidation; a non-zero `liquidationFee` does not stop LPVaultSwap's own liquidation either, because Collateralization debits the fee shares into the pending balance at the liquidation that moves them ([2.3](../02-contracts/03-collateralization.md) `REQ-VAULT-176`, `ATTACK-202`); monitoring alarms on the upgrade event, the slot and each setting; Avana re-approves only an implementation that passes the bytecode check; the vault token accepts only the Hub, the AaveAdapter, registered proxies and LPVaultSwap as recipients, so a third-party liquidator cannot receive seized tokens; a registered proxy may receive them, but a proxy has no liquidation or transfer function of its own and acts only on the AaveAdapter's call (Source: Q-080, Q-120, Q-224, Q-281, Q-363) |
| Result | Accepted risk — owner: Aave DAO (the Spoke proxy and configuration are DAO-owned and outside Avana's timelock); bound: new risk stops in the block after the change, and exposure is limited to positions liquidatable in the block of the change |
| Checks | TEST-182, TEST-189, TEST-204, TEST-268, PROP-078 |

### ATTACK-121: Listing on a Spoke that is not a reviewed standard Spoke with the required settings

| Field | Value |
|---|---|
| Target | MarketRegistry Spoke approval, deployment |
| Objective | Get Avana markets listed on a Spoke built from different code, or on a standard Spoke whose collateral reserves lack the required settings |
| Affected steps | `MKT` |
| Prerequisites | A mistaken or hostile deployment proposal |
| Attack approach | Propose `deployCdpSpoke` or `listCollateralMarket` for such a Spoke, or deploy a Spoke whose code differs from Aave Labs' source |
| Impact | Third parties could liquidate Avana accounts, or LPVaultSwap could not |
| Expected protection | `INV-073`, `INV-093`: `deployCdpSpoke` and `listCollateralMarket` revert unless the proxy's implementation slot holds the reviewed standard Spoke implementation, every Avana collateral reserve has `receiveSharesEnabled = false`, `liquidationFee = 0`, no reinvestment controller and a non-borrowable vault-token reserve, and the Spoke's debt reserves equal those the MarketRegistry records for it with their funding Hubs; the deployment bytecode check rebuilds the reference with Aave's own per-file settings and fails on any code difference (`REQ-HUB-100`); each operation waits the normal delay (5 days) and any canceller can cancel it (Source: Q-003, Q-228, Q-281, Q-239, Q-363) |
| Result | Mitigated |
| Checks | TEST-183, TEST-185, TEST-204, TEST-268 |

## Adapter custody, immutable proxies, governance timing and multi-asset debt

### ATTACK-122: Hostile AaveAdapter upgrade

| Field | Value |
|---|---|
| Target | AaveAdapter (UUPS proxy) |
| Objective | Use the Adapter's custody power over every PositionProxy to take borrowing capacity, vault tokens or user allowances |
| Affected steps | `DEP`, `BOR`, `REP`, `WDR`; `MKT` upgrade |
| Prerequisites | Governance multisig compromise (4 of 7) and no canceller acting during the normal delay |
| Attack approach | Schedule `upgradeToAndCall` of the AaveAdapter to a hostile implementation; after 5 days execute it; then borrow every debt reserve against every proxy to an attacker receiver, withdraw supplied vault tokens, mint vault tokens to registered proxies and supply them, burn the Hub's vault tokens, register attacker addresses as proxies, spend repay allowances users granted to the Adapter, and pledge positions whose owners approved the LPVault |
| Impact | AaveAdapter or ProxyManager implementation faulty or hostile: borrow every debt reserve against every proxy up to each `drawCap`; withdraw supplied vault tokens; mint vault tokens to any registered proxy (bounded by the Hub `addCap`); burn vault tokens held by any registered proxy or LPVaultSwap (never the Hub's, which the immutable token refuses); register any address as a proxy; spend allowances granted to the Adapter; pledge any position whose owner approved the LPVault. It cannot send a position to anyone but its depositor of record, change a Spoke setting, raise any Aave cap, or spend a Coverage Spoke. Bound: 5-day timelock, cancellers, Hub/Spoke caps; exits (repay, debt-free withdraw) are never paused, so borrowers can leave inside the delay. |
| Expected protection | `INV-007`, `INV-018`, `INV-043`, `INV-045`, `INV-065`, `INV-068`: the upgrade is an `APPLICATION_ADMIN` operation at the normal delay (5 days), public in the queue, and the governance multisig, the Emergency Guardian, the Aave Protocol Guardian and the Aave governance executor can each cancel it; repay and debt-free withdrawal never read the pause state, so a borrower needs one repay per debt reserve and one withdrawal per position to leave inside the delay; each LPVault is immutable and returns a position only to its depositor of record; the CDP Spoke's `drawCap` per debt reserve and the Hub `addCap` per vault-token asset bound what any Adapter can borrow or mint; the app asks for exact debt-asset approvals per repay, so standing allowances to the Adapter are zero (Source: Q-223, Q-224, Q-226, Q-228) |
| Result | Accepted risk — owner: Avana Labs (governance multisig and the reviewed Adapter code) and the cancellers; bound: the `drawCap` of each debt reserve on each CDP Spoke plus the Hub `addCap` of each vault-token asset, with a 5-day window in which any canceller can stop the upgrade and every borrower can exit |
| Checks | TEST-130, TEST-195, FINDING-099 |

### ATTACK-123: Changing the code of every PositionProxy at once

| Field | Value |
|---|---|
| Target | ProxyManager and every PositionProxy |
| Objective | Change the code of every proxy at once to remove `OnlyAdapter` and act on every account directly |
| Affected steps | `BOR`, `WDR`; `MKT` upgrade |
| Prerequisites | Governance multisig compromise and no canceller acting during the normal delay |
| Attack approach | Schedule an operation that sets a new proxy implementation, or create proxies whose code differs from the reviewed one; then call every proxy to borrow each debt reserve to an attacker receiver and to withdraw supplied vault tokens to an attacker-controlled registered proxy |
| Impact | None: proxy code cannot change; an attacker who controls the AaveAdapter is `ATTACK-122` |
| Expected protection | `INV-063`, `INV-064`, `INV-065`, `INV-007`, `INV-011`: a PositionProxy is a logic-free immutable account created by CREATE2 from constant init code, so no operation exists that changes any proxy's code; its wallet, Spoke and market binding is fixed at creation; a vault token moves only from a registered proxy to its market's home Hub, from that Hub back to the proxy, or from that Hub to LPVaultSwap on seizure, and is minted and burned only by the AaveAdapter, never sent to an attacker address; borrowing is bounded by each debt reserve's `drawCap`; exits stay open throughout the delay (Source: Q-225, Q-226, Q-228) |
| Result | Mitigated |
| Checks | TEST-191, TEST-210, TEST-271, PROP-076, FINDING-100 |

### ATTACK-124: Burning vault tokens held by the Hub or a victim proxy

| Field | Value |
|---|---|
| Target | Vault token `burn(from, amount)`, AaveAdapter `burnSeized` |
| Objective | Destroy vault tokens the Hub or a victim's proxy holds, so Aave's vault-token asset becomes unbacked or a victim's collateral disappears |
| Affected steps | `WDR`, `LIQ` |
| Prerequisites | Any address; or a hostile Adapter (`ATTACK-122`) |
| Attack approach | Call `vaultToken.burn(hub, x)` directly; call `AaveAdapter.burnSeized` as a non-LPVaultSwap caller or outside a seizure; withdraw a record and have more units burned than released |
| Impact | None for any caller other than the Adapter: each call reverts |
| Expected protection | `INV-009`, `INV-010`, `INV-014`, `INV-066`: `burn` is `OnlyAdapter`; the reviewed Adapter burns only from the proxy in its own withdrawal, exactly the units the proxy received in that call and Collateralization releases, and from LPVaultSwap in `burnSeized`, which only LPVaultSwap may call while it holds the Lock; Collateralization independently requires the proxy's share drop to equal the token-supply drop and the debit in `settleSeizure`, and the backing bound `totalSupply ≤ totalCredited + pending.units`, with the market's backing gap unchanged by every pledge, withdrawal, partial removal, re-credit and repay with collateral (`INV-080`); a burn that no settlement debits only widens the gap, so every circulating unit stays backed. The token refuses a burn from the Hub (`UnauthorizedTransfer(hub, address(0))`, 2.4 `REQ-VTOKEN-014`), and its bindings can never be registered as proxies (`ReservedAddress`, `REQ-VTOKEN-047`), so a Hub burn is impossible even for a hostile Adapter; a hostile Adapter's burns from registered proxies and LPVaultSwap are the accepted risk of `ATTACK-122` (Source: Q-223, Q-224, Q-257) |
| Result | Mitigated |
| Checks | TEST-189, TEST-208 |

### ATTACK-125: Rogue proxy registration in a vault token

| Field | Value |
|---|---|
| Target | Vault token `addValidProxy` |
| Objective | Register an attacker contract as a proxy so it can receive vault tokens, be minted to, or receive seized units from a direct liquidation |
| Affected steps | `DEP`, `LIQ` |
| Prerequisites | Any address |
| Attack approach | Call `vaultToken.addValidProxy(attacker)`; deploy a contract at an address the token will later accept; get the Adapter to register an address it did not deploy |
| Impact | None: registration fails, and a registered address alone gains nothing |
| Expected protection | `INV-011`, `INV-012`, `INV-064`: `addValidProxy` is `OnlyAdapter` and append-only; the reviewed Adapter registers only the caller's own proxy, created by the ProxyManager at `predictProxy(wallet, spoke, marketId)`, at its first pledge into that market and after checking `isValidProxy`; mint happens only for units Collateralization credited after custody of a position; a seizure moves tokens only to LPVaultSwap, the one recipient the token admits from the Spoke (`INV-093`); the token refuses to register any of its bindings (`hub()`, `spoke()`, `adapter()`, `lpVaultSwap()`, `collateralization()`, `integration()`, `lpOracle()` or the token itself) with `ReservedAddress` (2.4 `REQ-VTOKEN-047`), so even a hostile Adapter cannot make the Hub's balance burnable or open a Hub → Hub, LPVaultSwap → Hub or Adapter path by registration (Source: Q-120, Q-223, Q-224, Q-225) |
| Result | Mitigated |
| Checks | TEST-188 |

### ATTACK-126: Conversion-leg sandwich that leaves a settlement gap for Avana

| Field | Value |
|---|---|
| Target | LPVaultSwap conversion into the debt asset |
| Objective | Make a liquidation recover less of the debt asset than the debt repaid and leave the gap for Avana |
| Affected steps | `LIQ` conversion and settlement |
| Prerequisites | Its own `liquidate` call; a DEX swap route or builder access |
| Attack approach | Front-run each swap route that converts an unwound token into the debt asset; back-run after the liquidation settles |
| Impact | Bounded: each leg can lose at most its slippage allowance against its oracle value, which the recovery floor already covers |
| Expected protection | `INV-037`, `INV-038`, `INV-083`, `INV-097`: every leg swaps directly into the debt asset with an oracle-derived `minOut` (`SPEC-LIQ-018`), so a sandwich that pushes a leg below it reverts that leg and LPVaultSwap tries the backup route; the effective slippage satisfies `bNet × (10⁴ − s) ≥ 10⁸`, so the floor covers the debt repaid up to one vault unit; no flash premium enters, because LPVaultSwap takes no flash loan in a liquidation (`Q-404`); the remaining rounding terms are borne by the caller in its `keeperOut` or its shortfall top-up; no Avana contract funds a settlement gap (`Q-397`). Example: `D` = 10,000 USDC (10,000e6) at Pdebt = $1.0000, bonus 2% (`bNet = 10,200`), `s` = 150 bps (below `⌊10⁴ × 200 / 10,200⌋ = 196`): seized value 10,200 USD, floor `⌈10,200 × 0.985⌉ − U − ε` ≈ 10,046 USDC, which covers the 10,000 USDC repayment; a sandwich that delivers 10,040 USDC reverts the leg (Source: Q-167, Q-235, Q-236, Q-363, Q-397, Q-404) |
| Result | Mitigated |
| Checks | TEST-197, TEST-200, TEST-277, FINDING-103 |

### ATTACK-127: Oversized `debtToCover` or helper loan that turns funding into a cost for others

| Field | Value |
|---|---|
| Target | LPVaultSwap funding, flash liquidation helper |
| Objective | Fund or flash-borrow far more of the debt asset than Aave will consume, so the unused part or its premium is paid by someone else |
| Affected steps | `LIQ` funding and waterfall |
| Prerequisites | Any address |
| Attack approach | Pass `debtToCover` many times the account's liquidatable debt; LPVaultSwap pulls it as `Kf` and Aave pulls `D ≤ Kf`; through the helper, borrow all of it with `F = debtToCover` |
| Impact | The unused funding returns to the caller, and any premium on it is borne by the caller |
| Expected protection | `INV-035`, `INV-062`, `INV-037`: LPVaultSwap takes no flash loan and returns the unused `Kf − D` to the caller inside `keeperOut` in the same call (2.11 `REQ-SWAP-089`); a helper pays the premium on its whole loan from that payout and its caller's bounded top-up, or reverts `TopUpExceeded` (`REQ-HELPER-007`); no Avana contract pays any part (`Q-397`); the Lens sizes `debtToCover` to what Aave's formulas will consume, so honest callers do not oversize (Source: Q-167, Q-213, Q-232, Q-235, Q-236, Q-363, Q-397, Q-404) |
| Result | Mitigated |
| Checks | TEST-197, TEST-205, TEST-267 |

### ATTACK-128: Debt-asset price rally liquidates stable-LP accounts together

| Field | Value |
|---|---|
| Target | Accounts with stable-LP collateral and a volatile debt asset (WETH) |
| Objective | Profit from, or cause, a wave of liquidations that exceeds route and flash capacity when the debt asset's price rises |
| Affected steps | `LIQ`, `DEF` |
| Prerequisites | A listed WETH (or other non-stable) debt reserve; a sharp rise in its price |
| Attack approach | Borrow WETH against stable LPs at the protocol maximum (HF 1); when WETH rallies every such account's HF falls together without any collateral move; liquidate them in volume while swap-route depth and flash liquidity are exhausted |
| Impact | Reverting or shortfall-heavy liquidations and deficits in the WETH reserve |
| Expected protection | `INV-070`, `INV-071`, `INV-072`: a debt reserve becomes live (`enableDebtReserve`) only after its funding, caps, price source and the swap routes from every token of every listed market of the Spoke into its asset pass stress validation; caps are sized with the pause-loss bound including a debt-asset price-rise term; the `drawCap` of that reserve limits total exposure; route depth thresholds per route kind (`routeDepthThresholdUsd`) and a backup swap route bound conversion failure; a deficit is covered by that asset's own Coverage Spoke (Source: Q-192, Q-233, Q-234, Q-235, Q-236) |
| Result | Launch condition — a debt reserve is listed only after stress validation of its swap routes at its cap and cap sizing with the debt-price term (`FINDING-102`) |
| Checks | TEST-202, FINDING-102 |

### ATTACK-129: Stale debt feed shields an account from liquidation

| Field | Value |
|---|---|
| Target | LPVaultSwap price gates, debt-asset feeds |
| Objective | Keep an account unliquidatable by holding a small debt in a reserve whose feed goes stale more often |
| Affected steps | `LIQ`, `BOR` |
| Prerequisites | A listed non-GHO debt reserve whose Chainlink feed can lag `liquidationPriceMaxAge` |
| Attack approach | Borrow a small amount of that reserve next to the main debt; wait for the feed to go stale while HF falls below 1 |
| Impact | Only the stale reserve's repayment waits; the account's other debt and its collateral stay liquidatable, with the stale debt valued at its stress price |
| Expected protection | `INV-030`, `INV-072`, `INV-075`, `INV-087`: a non-GHO debt reserve is priced by its DebtOracle, which reads a primary and an alternate route plus a reviewed standby; liquidation requires a Live DebtOracle only for the reserve it repays, and values a stale debt at `⌈accepted × (10⁴ + debtStressRiseBps) / 10⁴⌉`, which raises the account's debt, so the small debt cannot shield the main one; while the feed is stale the RiskModule blocks borrowing and withdraw-with-debt for every account holding that debt (`DebtPriceTooOld`), so the position cannot be built during the stall; a feed is fresh only while its age is at most its heartbeat plus `heartbeatMargin` (2.10 `SPEC-ORC-019`), and a stopped feed is caught by the agreement check; GHO's fixed source has no age (Source: Q-128, Q-182, Q-192, Q-234, Q-238, Q-247, Q-248, Q-274) |
| Result | Accepted risk — owner: Avana Labs and the Aave V4 risk service providers (feed and standby choice at listing, guardian standby switch); bound: an account whose only debt is in the stale reserve waits for the DebtOracle's alternate route or the standby switch, and losses accrued meanwhile are covered by caps sized with the pause-loss bound over the 48-hour incident window (`Q-192`) |
| Checks | TEST-201, TEST-226, TEST-230, TEST-231, FINDING-101 |

### ATTACK-130: Exhausting one asset's First-Loss Reserve or covering it with another asset

| Field | Value |
|---|---|
| Target | Coverage Spokes |
| Objective | Use up the reserve of one debt asset with deficits in that asset, then have another asset's reserve pay them |
| Affected steps | `DEF` |
| Prerequisites | Deficits in one debt reserve larger than its funded reserve |
| Attack approach | Create deficits in the USDC reserve until its Coverage Spoke falls below its minimum; ask the Coverage Spoke of another asset (GHO) to cover the remainder |
| Impact | Cross-asset coverage: none (it is impossible). Exhaustion: losses beyond that asset's reserve fall on that asset's lenders |
| Expected protection | `INV-042`, `INV-071`: each Coverage Spoke is registered on one `(Hub, asset)` and covers only deficits in that asset, at most its funded balance; below `firstLossReserveMinimum` it emits `ReserveBelowMinimum`, an alert on which the Emergency Guardian or Aave freezes or pauses new borrowing; an asset's `drawCap` rises above 0 only after its Coverage Spoke is funded, and its caps are sized against its own reserve (Source: Q-192, Q-236) |
| Result | Accepted risk — owner: the Aave DAO (losses beyond each asset's First-Loss Reserve fall on that asset's lenders per its funding approval); bound: that asset's `drawCap` and caps sized against its reserve; cross-asset coverage is impossible |
| Checks | TEST-199 |

### ATTACK-131: Timing attacks on timelock execution

| Field | Value |
|---|---|
| Target | AvanaTimelock public execution and grace period |
| Objective | Execute a ready operation at the moment that suits the attacker, or execute an old operation long after its context changed |
| Affected steps | `MKT`, `EMG` |
| Prerequisites | Any address (public execution); a ready operation in the queue |
| Attack approach | Hold a ready parameter change and execute it inside a bundle that profits from the new value; wait months and execute a forgotten operation; execute a batch's calls one at a time |
| Impact | Bounded to what the reviewed operation itself does |
| Expected protection | `INV-068`: an operation executes only after its full delay and expires `GRACE_PERIOD` (14 days) after it becomes ready (`OperationExpired`), after which it can only be cleaned up; any canceller can cancel a ready operation that has gone stale; a batch executes atomically, so related calls (a listing, a route change with its depth threshold) never land one at a time; each operation is reviewed on the assumption that anyone may execute it at any moment inside its grace window (Source: Q-228) |
| Result | Mitigated |
| Checks | TEST-194, TEST-212 |

### ATTACK-132: Pause-state misuse

| Field | Value |
|---|---|
| Target | MarketRegistry pause state |
| Objective | Hold the application Paused indefinitely, or re-freeze after every unfreeze, to deny service |
| Affected steps | `EMG`, `DEP`, `BOR` |
| Prerequisites | Compromise of a guardian Safe |
| Attack approach | Call `pause(reason)`, `freeze()` or `freezeAddress` after each `unpause()`, `unfreeze()` or unfreeze operation |
| Impact | New pledges, non-rescue top-ups (`Paused(General)`), every top-up (`Paused(MintPathSuspect)`), borrowing and withdraw-with-debt (Paused) blocked for as long as the misuse lasts; no effect on liquidation, repay, fee collection or debt-free withdrawal |
| Expected protection | `INV-049`, `INV-050`, `INV-067`, `INV-068`, `INV-081`, `INV-085`: the pause state, the pause reason and the address freeze block only new activity; liquidation, pending settlement, repay, fee collection, debt-free withdrawal and removal, and zero-credit release never read them, and rescue top-ups pass every state except `Paused(MintPathSuspect)`; the freeze guardian cannot unfreeze, so a compromised freeze-only holder cannot undo a pause; a guardian may freeze at most 20 addresses in any 24 one-hour buckets and never a protected Avana address; revoking a guardian's roles is a role-change operation that only the Aave governance executor can cancel (Source: Q-227, Q-228, Q-242, Q-252) |
| Result | Accepted risk — owner: Avana Labs (Emergency Guardian signers) and Aave governance (revocation); bound: loss of new activity only, for at most the normal delay (5 days) of the revocation; solvency is unaffected |
| Checks | TEST-192, TEST-193, TEST-229 |

### ATTACK-133: Guardian cancels its own removal

| Field | Value |
|---|---|
| Target | AvanaTimelock cancellation |
| Objective | Keep a compromised guardian or canceller in place by cancelling every operation that revokes its roles |
| Affected steps | `EMG` |
| Prerequisites | Compromise of the Emergency Guardian or of any other `CANCELLER_ROLE` holder |
| Attack approach | Watch the queue and call `cancel` on each `revokeRole` operation |
| Impact | None: the cancel reverts |
| Expected protection | `INV-068`: an operation whose every call is `grantRole` or `revokeRole` on an Avana contract or the timelock is a role-change operation, and `cancel` of it reverts `RoleChangeCancelRestricted` unless the caller holds `DAO_CANCELLER_ROLE` (the Aave governance executor); governance schedules a revocation as a pure role-change operation (Source: Q-136, Q-228) |
| Result | Mitigated |
| Checks | TEST-194 |

### ATTACK-134: Pre-deploying code at a victim's proxy address

| Field | Value |
|---|---|
| Target | ProxyManager CREATE2 deployment |
| Objective | Occupy `predictProxy(victim, spoke, marketId)` with attacker code, or initialize the victim's proxy with another wallet, before the victim's first pledge |
| Affected steps | `DEP` first pledge |
| Prerequisites | Any address |
| Attack approach | Deploy code at the predicted address; call `ProxyManager.deployProxy(victim, spoke, marketId)`; front-run the creating transaction |
| Impact | None: the address can only hold the ProxyManager's own immutable proxy bound to the victim |
| Expected protection | `INV-064`: a CREATE2 address depends on the deployer, the salt `keccak256(abi.encode(wallet, spoke, marketId))` and the constant init code, so only the ProxyManager can deploy at it; `deployProxy` is `OnlyAdapter` and the Adapter creates a proxy only for `msg.sender` at its first pledge into that market; the binding is set in the constructor, so no initialization exists; a second deployment for the same triple reverts `ProxyExists` (Source: Q-225, Q-363) |
| Result | Mitigated |
| Checks | TEST-190 |

### ATTACK-135: Stale or manipulated liquidation preview

| Field | Value |
|---|---|
| Target | Lens `previewLiquidation` |
| Objective | Make a caller submit preview parameters that pay it less or spend more of the debt asset than expected |
| Affected steps | `LIQ` |
| Prerequisites | Ability to move state between the preview and inclusion |
| Attack approach | Move a route pool or the debt price after the caller read the preview; rely on the preview's `minPayout = 0` |
| Impact | Bounded to the caller's own payout within the bounds it signed |
| Expected protection | `INV-030`, `INV-070`: the Lens is immutable and advisory; LPVaultSwap recomputes every gate and amount at execution, Aave sizes the debt actually repaid, each leg's oracle `minOut` limits the conversion, and the recovery floor protects Avana; the preview returns the expected payout separately so the caller sets its own `minPayout`, and `deadline` limits how long a preview stays usable (Source: Q-216, Q-232) |
| Result | Mitigated |
| Checks | TEST-205 |

### ATTACK-136: Debt-reserve offboarding with open debt

| Field | Value |
|---|---|
| Target | MarketRegistry debt-reserve records, market `Offboarding` status |
| Objective | Remove a debt reserve or offboard a market so accounts holding that debt or collateral can no longer be liquidated or repaid |
| Affected steps | `MKT`, `LIQ`, `REP` |
| Prerequisites | Governance multisig compromise or error |
| Attack approach | Schedule `removeDebtReserve` for a reserve with debt outstanding; schedule `setMarketOffboarding` and expect it to stop settlement |
| Impact | None: removal reverts while debt exists, and offboarding stops only new risk |
| Expected protection | `INV-046`, `INV-073`: `removeDebtReserve` reverts `DebtReserveInUse` unless nothing is drawn in that reserve; `Offboarding` blocks pledges and borrowing against the market while repay, fee collection, withdrawals and liquidation continue; removing a reserve from the Spoke's `APPROVED_DEBT_RESERVES` needs a new Spoke implementation, which the drift check (`DebtReserveSet`) reports and which closes new pledges and borrows until both sets match again (Source: Q-227, Q-233, Q-281) |
| Result | Mitigated |
| Checks | TEST-204, TEST-213 |

### ATTACK-137: LPVaultSwap supplies seized vault tokens as its own collateral

| Field | Value |
|---|---|
| Target | Vault-token recipient rule, LPVaultSwap |
| Objective | Use the recipient-only rule (the sender is not checked and the Hub is an allowed recipient) to have LPVaultSwap supply seized vault tokens on the CDP Spoke on its own behalf and borrow against them |
| Affected steps | `LIQ` |
| Prerequisites | A hostile LPVaultSwap implementation installed through the timelock at the normal delay |
| Attack approach | After a liquidation, instead of having the Adapter burn the seized units, call `Spoke.supply` on behalf of LPVaultSwap; enable the reserve as collateral; borrow the debt reserve |
| Impact | Borrowing against seized units until the hostile implementation is replaced; the seized NFTs' liquidity stays backed through reconcile on exit |
| Expected protection | `INV-013`, `INV-018`, `INV-058`, `INV-068`: the reviewed LPVaultSwap has no Spoke supply call (selector inventory) and burns every seized unit through `burnSeized` in the same call; an upgrade waits the normal delay with every canceller able to cancel; LPVaultSwap obtains vault tokens only as the one seizure recipient the token admits, so only from accounts Aave deems liquidatable and only in Aave's sizing; units it never settles are reconciled on the borrower's exit into the pending-settlement balance; its borrowing is bounded by the debt reserve's `drawCap` and Aave's HF (Source: Q-201, Q-281, Q-224, Q-228) |
| Result | Accepted risk — owner: Avana Labs (reviewed LPVaultSwap code and upgrades); bound: units seized from liquidatable accounts during the hostile implementation's lifetime, borrowing within each `drawCap`, after a 5-day delay that any canceller can stop (`FINDING-092`) |
| Checks | TEST-189, FINDING-092 |

## Circuit breakers, address freeze, standby routes, rescue and new liquidation paths

### ATTACK-138: Breaker griefing by self-liquidation

| Field | Value |
|---|---|
| Target | Market breakers (seizure and route-failure signals) |
| Objective | Latch a market's breaker so every other user of the market loses new pledges and borrowing |
| Affected steps | `LIQ`; `DEP`; `BOR` |
| Prerequisites | Own accounts in market m below HF 1; its own `liquidate` call; capital to push the primary route's pool |
| Attack approach | Liquidate its own accounts until the seized units in one hour exceed 20% of the market; or push the primary sell route off price before each of its own liquidations so the backup settles and the primary counts as failed, 3 times in one hour; or withdraw and re-pledge in volume |
| Impact | None on-chain: these signals raise monitoring alerts and trip nothing; repay, debt-free withdrawal and removal, fee collection, rescue top-ups, repay with collateral, liquidation and new borrowing continue |
| Expected protection | `INV-081`, `INV-046`, `INV-067`: the seizure-surge and route-failure breakers are not on-chain trip conditions (`Q-399`). A seizure above 20% of a market in 1 hour and 3 swap-route failures in 1 hour are monitoring alerts only, because reverted calls cannot persist counts and an on-chain counter can be gamed by self-liquidation; new borrowing in a market is frozen for route failure only by a guardian action (`tripMarketBreaker`) once monitoring confirms the approved routes cannot settle valid liquidations at the required size. The on-chain gates that remain (oracle and stablecoin band breach, the pool-share concentration gate `poolShareMaxBpsOf(poolKey)` where a pool's listing sets a cap (`Q-403`), and the deficit freeze at `breakerDeficitMax`) are not moved by self-liquidation of a solvent position, and a temporary price or depth gate clears after 30 minutes of healthy observations, a provisional launch setting (Source: Q-241, Q-399) |
| Result | Mitigated: self-liquidation trips no on-chain breaker; a false alert costs the attacker its own liquidated collateral or repeated pool pushes and changes nothing for other users |
| Checks | TEST-228, TEST-215, PROP-066 |

### ATTACK-139: Compromised guardian uses address freeze, breakers and the standby switch

| Field | Value |
|---|---|
| Target | MarketRegistry `freezeAddress`, `tripMarketBreaker`, `tripDebtBreaker`, `resetMarketBreaker`, `useStandbyRoute`, `pause(reason)` |
| Objective | Use a compromised Emergency Guardian or Aave Protocol Guardian to lock users in, force liquidations, freeze Avana itself or pick a price |
| Affected steps | `EMG`, `LIQ`, `DEP`, `BOR`, `WDR`, `REP` |
| Prerequisites | Compromise of a guardian Safe (3-of-5) |
| Attack approach | Freeze many borrower wallets, the keepers, LPVaultSwap or a proxy; trip every breaker and pause with `MintPathSuspect` so borrowers cannot rescue; reset a tripped market breaker during a crash; switch a token's primary route to its standby to move the price; cancel the unfreeze operations |
| Impact | Bounded to new activity: frozen wallets cannot open pledges, borrow, withdraw with debt or call `liquidate` directly; tripped markets stop new pledges and borrowing; repay, debt-free withdrawal and removal, fee collection, zero-credit release, pending settlement, payout escrow claims, rescue top-ups (except under `MintPathSuspect`) and liquidation continue |
| Expected protection | `INV-081`, `INV-085`, `INV-067`, `INV-068`, `INV-090`: the freeze reaches only the listed new-activity paths and never repay, debt-free exits, fee collection, pending settlement, `burnSeized`, escrow claims, rescue top-ups, contract-to-contract calls or liquidation of the frozen wallet's positions; `freezeAddress` reverts `ProtectedAddress` for the timelock, the Aave governance executor, every Avana contract, vault token, oracle, Hub, Spoke, Coverage Spoke, every debt asset, the flash source, every recorded swap route and every registered proxy, checks no keeper floor, so freezing the last committed operator halts only new borrowing on the chain while `liquidate` stays open to every unfrozen address and to the frozen one through the public helper (2.11 `REQ-SWAP-105`, `REQ-SWAP-107`), and allows at most `MAX_ADDRESS_FREEZES_PER_DAY` (20) freezes per caller in the 24 one-hour buckets ending with the current one; `unfreezeAddress` is a normal-delay operation that only the Aave governance executor can cancel, so the freezing guardian cannot hold a freeze in place; breakers and the pause never reach liquidation, and resetting a latched breaker reopens borrowing only through every RiskModule gate; `useStandbyRoute` can select only the reviewed standby recorded at listing, which passes the same checks as the route it replaces and never forces Live, and the Aave governance executor undoes the switch at once with `cancelStandbySwitch`; the Aave Protocol Guardian unpauses and resets at once; revoking the guardian's roles is a role-change operation only the Aave governance executor can cancel (Source: Q-227, Q-228, Q-241, Q-242, Q-245, Q-248, Q-252, Q-263, Q-400, Q-404) |
| Result | Accepted risk — owner: Avana Labs (Emergency Guardian signers), the Aave Protocol Guardian and Aave governance; bound: up to 20 wallets per guardian per day lose new activity until their unfreeze executes after the normal delay (5 days); tripped breakers and pauses last until the other guardian resets or unpauses; no exit, liquidation or price outside the reviewed routes is reachable |
| Checks | TEST-229, TEST-228, TEST-231, TEST-235, PROP-066, PROP-071 |

### ATTACK-140: Standby switch to a stale or diverged route

| Field | Value |
|---|---|
| Target | MarketRegistry `useStandbyRoute`, LPOracle, DebtOracle |
| Objective | Switch a token's route to a standby whose answer is stale or off market, to force a price for borrowing or liquidation, or to restart the disagreement timer and keep a market unliquidatable |
| Affected steps | `EMG`, `LIQ`, `BOR` |
| Prerequisites | A guardian key (immediate switch) or the governance multisig (short-delay switch) |
| Attack approach | Call `useStandbyRoute(token, Primary)` while the standby feed is stale or reports a depeg the other route does not; switch repeatedly to reset `disagreeSince` |
| Impact | None for solvency: a stale or diverged standby makes the market Cached, Expired or disagreeing, never Live at the wrong price |
| Expected protection | `INV-055`, `INV-059`, `INV-087`: the standby is recorded in the listing operation and changed only by `setPriceSource` at the normal delay, and it passes the listing checks of the slot it replaces (decimals, `minAnswer`/`maxAnswer` guards, heartbeat recorded with its `heartbeatMargin`, no shared intermediate feed with the other active route); after a switch the LPOracle and DebtOracle apply freshness, validity and the agreement check to the new route on the next `poke`, so a stale standby yields Cached and then Expired, and a diverged one yields a disagreement served at the lower route for collateral and the higher route for debt; the disagreeing market's own seizure waits both before and after `disagreementPauseMax`, so resetting the timer changes nothing for liquidation; the Aave governance executor cancels a guardian's switch at once, a scheduled switch can be cancelled only by it, and switching back is `restorePriceRoute` at the normal delay (Source: Q-208, Q-247, Q-248, Q-263) |
| Result | Mitigated |
| Checks | TEST-231, TEST-219, TEST-230 |

### ATTACK-141: Automatic in-kind griefing

| Field | Value |
|---|---|
| Target | Liquidation settlement mode |
| Objective | Switch a market to in-kind settlement without governance, to take seized pool tokens instead of the debt asset or to stop routed settlement |
| Affected steps | `LIQ` |
| Prerequisites | Its own `liquidate` call; capital to hold a route below the recovery floor |
| Attack approach | Push the market's sell routes off price and report repeated recovery shortfalls, hoping to switch the market to in-kind settlement |
| Impact | None: no settlement mode can be switched, and routed liquidations that miss the floor revert until the routes recover or the caller tops up the gap |
| Expected protection | `INV-039`, `INV-081`: in-kind settlement, its automatic trigger and shortfall reporting are removed (`Q-401`); every liquidation settles in the debt asset over the market's fixed swap routes or reverts, so there is no mode to switch and no keeper report that changes settlement; holding every route below the floor in every block costs the attacker the slippage it creates against arbitrageurs, while the caller's shortfall top-up stays available and `liquidate` stays open to every address (Source: Q-163, Q-228, Q-251, Q-263, Q-401, Q-404) |
| Result | Mitigated |
| Checks | TEST-234, TEST-053 |

### ATTACK-142: Shortfall top-up self-sandwich

| Field | Value |
|---|---|
| Target | LPVaultSwap shortfall top-up and per-leg minimums |
| Objective | Use the relaxed per-leg slippage of a shortfall top-up to sandwich its own conversion and keep more than it pays |
| Affected steps | `LIQ` conversion and floor test |
| Prerequisites | Any address; the debt asset for the shortfall; builder access |
| Attack approach | Pass a large `maxShortfall`, so each leg's slippage widens to `sLeg = min(9,999, s + min(maxShortfallBps, ⌊maxShortfall × 10⁴ / V⌋))`; front-run its own conversion legs, back-run them, and cover the resulting shortfall from the sandwich profit |
| Impact | None for Avana, lenders or the reserve: the attacker pays as shortfall what it extracts from its own conversion |
| Expected protection | `INV-034`, `INV-035`, `INV-083`, `INV-086`: the floor is tested on `R + shortfall ≥ minRec` with `minRec` from oracle prices, and LPVaultSwap pulls the shortfall from `msg.sender` in the same call, so every unit of the debt asset the sandwich takes from the conversion the caller pays back; the relaxation is capped at `maxShortfallBps` (1,000) above `s` and at `maxShortfall`, and a shortfall above `maxShortfall` reverts `RecoveryBelowFloor`; no Avana contract pays a shortfall (`Q-397`); Avana's fee is computed from the oracle value `V`, not from `R`, so it is unchanged while the surplus covers it. Example (USDC debt): `V` = 12,422.6 USDC, `s` = 100 bps, `minRec` = 12,297 USDC, honest routes return 12,174 USDC → shortfall 123 USDC, per-leg cap 100 + min(1,000, ⌊200 × 10⁴ / 12,422.6⌋ = 160) = 260 bps with `maxShortfall` = 200 USDC; a self-sandwich that lowers `R` to 12,100 USDC raises the pulled shortfall to 197 USDC, exactly the 74 USDC it extracted more (Source: Q-250, Q-251, Q-256) |
| Result | Mitigated |
| Checks | TEST-233, TEST-227, TEST-240, PROP-069 |

### ATTACK-143: Re-credit donation and cap use

| Field | Value |
|---|---|
| Target | AaveAdapter `recredit`, Collateralization exposure counters |
| Objective | Book cap space against another borrower's NFT, bypass the exposure caps by donating liquidity to one's own pledged NFT, or release the wrong charge on a later exit |
| Affected steps | `DEP` re-credit; `WDR` |
| Prerequisites | Any address can call `increaseLiquidity` on the AMM protocol's position manager for any position |
| Attack approach | Call `increaseLiquidity` on a victim's pledged NFT and then `recredit` for it, filling `marketUsdCap` or `tokenUsdCap` so other users cannot pledge; or donate to its own NFT and re-credit while the market is near its caps or Paused; or re-credit and withdraw in pieces to release more cap than was booked |
| Impact | None: a donation stays uncredited until its depositor re-credits it through every top-up check |
| Expected protection | `INV-002`, `INV-027`, `INV-028`, `INV-088`: only the record's depositor can re-credit (`NotDepositor`), and the added units are the position's liquidity read through the AMM integration minus `credited`, reconciled first; a re-credit runs every top-up check (price state, Offboarding, exposure caps and slice, Hub `addCap`, pool share, `minPledgeUsd`, breakers) and books its charge, and `credited + added ≤ MAX_CREDITED_LIQUIDITY`; under `Paused(General)`, a breaker or an address freeze it is admitted only as a rescue top-up, and under `Paused(MintPathSuspect)` never; the record is rebased so `charge(U0') = C0'` and `charge(0) = 0` (`SPEC-BACK-013`), so exits across any split release exactly what was booked; the mint equals the credit and the backing gap is unchanged (Source: Q-157, Q-252, Q-254, Q-257) |
| Result | Mitigated |
| Checks | TEST-238, TEST-016, TEST-097, PROP-065 |

### ATTACK-144: Repay-with-collateral sandwich

| Field | Value |
|---|---|
| Target | AaveAdapter `repayWithCollateral`, LPVaultSwap `deleverage` |
| Objective | Extract value from a borrower's repay with collateral by sandwiching its conversion legs, or turn the path into an unhealthy withdrawal |
| Affected steps | `REP` repay with collateral |
| Prerequisites | Builder access or private order flow; capital to move the swap routes |
| Attack approach | Front-run the sell legs of the pool tokens released from the record into the debt asset; back-run after the deleverage; or call `repayWithCollateral` itself with oversized `units` to withdraw collateral without improving HF |
| Impact | Bounded: the borrower can lose at most the market's slippage allowance on the converted value plus rounding; lenders and the reserve lose nothing |
| Expected protection | `INV-083`, `INV-088`, `INV-089`: the deleverage requires liquidation-grade prices for the market and the debt reserve and values the units at oracle prices; every leg runs with an oracle-derived minimum (`SPEC-LIQ-018`, `s` = `slippageAllowanceBps`); the borrower sets `minDebtRepaid` (`DeleverageTooSmall`) and the proceeds must repay the flash loan (`DeleverageShortfall`); no bonus and no Avana fee; debt is repaid before collateral leaves, and while debt remains Aave's HF after must be at least `max(hfBefore, minHealthFactor)` (`HealthFactorNotImproved`); the path is refused under `Paused(MintPathSuspect)` and runs under `Paused(General)` because it lowers debt and never lowers the health factor (2.6 `REQ-ADAPTER-046`). Example (USDC debt): units worth 5,000 USDC at oracle prices, `s` = 100 bps and a 10 bps flash premium → at most about 4,945 USDC of debt is repaid (`4,950 / 1.001`), and a sandwich can take at most the 50 USDC allowance plus rounding (Source: Q-247, Q-250, Q-255, Q-347, Q-356) |
| Result | Accepted risk — owner: the borrower who chooses repay with collateral over a plain repay; bound: `slippageAllowanceBps` of the converted value plus the per-leg rounding terms |
| Checks | TEST-239, TEST-227, PROP-072 |

### ATTACK-145: Forced liquidation through a feed outage under stress valuation

| Field | Value |
|---|---|
| Target | LPOracle and DebtOracle served prices, LPVaultSwap |
| Objective | Liquidate an account's fresh collateral while another of its markets is valued at 1 during a feed outage, collecting the bonus from an account that is healthy at real prices |
| Affected steps | `LIQ` |
| Prerequisites | An account holding collateral in markets A and B; a Chainlink outage on B lasting past `cachedWindow`; its own `liquidate` call |
| Attack approach | Wait until B is Expired and served at 1, so the account's HF falls below 1; liquidate the account's A collateral |
| Impact | Bounded: accounts whose HF without B's value is below 1 lose the liquidation bonus on the A collateral seized to restore Aave's target HF; B is never seized at the stress price |
| Expected protection | `INV-075`, `INV-087`, `INV-030`: stress valuation starts only at Expired, after `cachedWindow` (3,600 s) of failed reads; while Cached B keeps its last accepted price, so one late heartbeat cannot push healthy accounts below 1; B's own seizure waits for a fresh price; the Emergency Guardian can switch B's failing route to its reviewed standby within the incident window; after recovery the grace window protects accounts above `graceHealthFactor` (0.95) for `graceDuration` (1,800 s); the borrower can repay or add a rescue top-up at any time, and borrowers who want B's failure isolated use a separate wallet (one account per wallet per CDP Spoke). Example: an account at HF 1.25 whose weighted collateral is 40 % B drops to HF 0.75 once B is Expired; keepers seize A until Aave's target HF, and B stays untouched (Source: Q-183, Q-192, Q-247, Q-248, Q-276) |
| Result | Accepted risk — owner: Avana Labs and the Aave V4 risk service providers (feed and standby choice, monitoring of Cached and Expired markets); bound: the bonus on collateral seized from accounts that are below HF 1 without the Expired market's value, only after `cachedWindow` and only until the standby switch or the feed returns |
| Checks | TEST-230, TEST-226, TEST-219, PROP-074 |

### ATTACK-146: Slice re-leverage loop

| Field | Value |
|---|---|
| Target | RiskModule rescue top-ups, `postHealthCheck` |
| Objective | Use rescue top-ups, which pass the pool-share cap, the breakers, the address freeze and `Paused(General)`, and slice top-ups, whose slice part sits outside the token and depositor caps, as a route to borrow more than the caps allow |
| Affected steps | `DEP` rescue top-up; `BOR`; `WDR` |
| Prerequisites | An indebted account below `rescueHealthFactor` (1.10) |
| Attack approach | Top up from the slice to restore HF 1.10, borrow back down to HF 1, repeat; or withdraw a regular record with debt after a rescue top-up |
| Impact | None: rescue units never support new debt |
| Expected protection | `INV-082`, `INV-025`: Collateralization books rescue units per record (whole for an exempt rescue, the slice part otherwise) and caps them at the record's credited units after every debit; `postHealthCheck` subtracts their collateral value from HF and requires the rescue-excluded `hfEx ≥ max(1, hardHealthFloor, minHealthFactor)` after every borrow, withdraw-with-debt and with-debt removal (`SPEC-CF-005`), where `hardHealthFloor` is the market's optional hard floor, off (0) by default (`Q-398`). Example: debt $10,000 at HF 1.08, so regular weighted collateral is $10,800; a top-up of $641 from the slice at collateral factor 0.312 adds `E` = $200 of rescue value and restores HF 1.10; borrowing back is checked on `hfEx`, which starts at 1.08 and must stay at least 1, so the account can borrow at most $800 (to a debt of $10,800) against its regular collateral, and a borrow toward the $11,000 that HF with rescue units would allow reverts `HealthFactorTooLow` (Source: Q-157, Q-252, Q-253, Q-398) |
| Result | Mitigated |
| Checks | TEST-236, TEST-235, PROP-067 |

### ATTACK-147: Dust-account spam

| Field | Value |
|---|---|
| Target | Liquidation economics, Avana's keeper gas |
| Objective | Open many minimum-size accounts so their liquidations cost more than they recover, draining the keeper budget or leaving unliquidated deficits |
| Affected steps | `DEP`, `BOR`, `LIQ`, `DEF` |
| Prerequisites | Many wallets (one account per wallet per CDP Spoke); LP positions of at least `minPledgeUsd` each |
| Attack approach | Pledge a $10 position from each of 1,000 wallets, borrow to the protocol maximum, and wait for a price move to push them below HF 1 |
| Impact | Bounded: each account's deficit is below its own debt, and the attacker's collateral and gas exceed what it can borrow |
| Expected protection | `INV-069`, `INV-037`, `INV-038`, `INV-074`: every pledge is at least `minPledgeUsd` ($10) and every borrow leaves Aave HF ≥ 1, so a minimum account's debt is at most $10 × CF, below $10; no Avana contract funds a settlement gap (`Q-397`): the caller bears any rounding gap, about `ε` = 1 USDC plus one vault unit for a USDC debt, in its own `keeperOut`; Avana's own keepers liquidate every account, repaying whatever Aave allows per call (`Q-395`), and pay the gas as Avana's cost, with no minimum debt (`INV-096`, `Q-381`); an unliquidated dust deficit is covered by that asset's Coverage Spoke. Example: 1,000 accounts lock $10,000 of LP collateral for at most $7,000 of debt at a 70% CF, and each costs its opener a proxy deployment, a pledge and a borrow in gas (Source: Q-169, Q-215, Q-230, Q-249, Q-251, Q-267, Q-276, Q-277, Q-381, Q-395, Q-397, Q-404) |
| Result | Accepted risk — owner: Avana Labs (keeper gas and the rounding gaps its keepers bear) and the Aave DAO (deficits beyond the First-Loss Reserve); bound: deficits below each dust account's own debt |
| Checks | TEST-246, TEST-081, TEST-161, TEST-073 |

### ATTACK-148: USDT fee switch

| Field | Value |
|---|---|
| Target | USDT as a pool token or a debt asset |
| Objective | Make every liquidation of a USDT market and every USDT repay revert, or book more than arrived, by switching on USDT's transfer fee |
| Affected steps | `LIQ` collect and conversion into the debt asset; `REP`; `WDR`; `FEE` |
| Prerequisites | Issuer action: Tether sets `basisPointsRate > 0` |
| Attack approach | The fee applies to every USDT transfer, so removal, routes and repays deliver less than the amount sent |
| Impact | Bounded: settlement of USDT as a pool token proceeds at the reduced amounts; liquidation, repay and repay with collateral of USDT debt revert inside Aave V4 until the fee returns to 0; new exposure stops |
| Expected protection | `INV-034`, `INV-043`, `INV-070`, `INV-081`: every amount Avana receives is measured by balance delta and every later step uses the measured amount, so where USDT is a pool token its seizure, swaps and payouts settle at what actually arrived, and no Avana contract books more than it holds; where USDT is the debt asset, Aave V4's Hub refuses every fee-reduced repayment (`InsufficientTransferred`), so a liquidation or repay of USDT debt reverts with nothing booked until the fee returns to 0, as for every Aave user of USDT, and Avana adds no path around that check (2.11 `REQ-SWAP-123`); the oracle-based recovery floor still compares against full value; the RiskModule's `UsdtFeeRate` probe reads `basisPointsRate()` and the ISSUER breaker stops new pledges into USDT markets and borrowing of a USDT debt reserve while the rate is above 0; USDT's own contract caps the rate below 20 bps and at most 50 USDT per transfer (Source: Q-241, Q-243, Q-271) |
| Result | Accepted risk — owner: Avana Labs (monitoring and the token-issuer playbook); bound: the fee on amounts already in flight, at most 19 bps and 50 USDT per transfer |
| Checks | TEST-221, TEST-228 |

### ATTACK-149: Issuer blocklist of LPVaultSwap

| Field | Value |
|---|---|
| Target | LPVaultSwap as a USDC or USDT holder |
| Objective | Halt liquidation of every market holding the token, and the conversion into that debt asset |
| Affected steps | `LIQ`, `DEF` |
| Prerequisites | Issuer action: USDC or USDT blocklists LPVaultSwap |
| Attack approach | Every transfer of the token to or from LPVaultSwap reverts, so liquidity removal to LPVaultSwap, conversion and the debt-asset payout fail |
| Impact | Liquidation of affected markets stops until the markets are migrated; positions there decay toward bad debt while the blocklist lasts |
| Expected protection | `INV-071`, `INV-081`, `INV-043`, `INV-045`: monitoring alerts on any blocklist event naming an Avana contract; the token-issuer playbook offboards the affected markets at the short delay, asks Aave to freeze their reserves and migrates them to a new Spoke and new vault tokens through Aave governance; repay of other debt reserves, debt-free withdrawal (the LPVault returns the NFT without moving the token) and liquidation of markets without the token stay open; caps are sized for paused-liquidation loss over the 48-hour incident window; a deficit is covered by that asset's own Coverage Spoke (Source: Q-192, Q-236, Q-241, Q-243, Q-271) |
| Result | Accepted risk — owner: Avana Labs (monitoring, playbook and migration) and the Aave DAO (losses beyond the affected asset's First-Loss Reserve); bound: the affected markets' caps and the affected debt reserve's `drawCap` |
| Checks | TEST-221 |

### ATTACK-150: Chainlink phase rollover hides an outage

| Field | Value |
|---|---|
| Target | LPOracle and DebtOracle recovery evidence |
| Objective | Liquidate accounts immediately after a feed outage, without the grace window, because the outage ended on a new aggregator phase |
| Affected steps | `LIQ` grace; `EMG` price-state handling |
| Prerequisites | Its own `liquidate` call; an outage that ends with a Chainlink aggregator upgrade |
| Attack approach | When the first round of the new phase arrives, `roundId − 1` names no round, so the gap lookup gives no evidence; liquidate accounts between `graceHealthFactor` and 1 at once |
| Impact | None: the grace window opens |
| Expected protection | `INV-031`, `INV-056`: when a leg's current round is the first of a phase (`uint64(roundId) == 1`), the oracle reads the last round of the previous phase through the proxy's `phaseAggregators(phaseId − 1)`; if that read is unusable, the gap starts at the `updatedAt` the oracle itself stored for the leg, a source timestamp, never a caught error; the rule can only lengthen the measured gap, which opens grace rather than skipping it; the LPOracle and the DebtOracle follow the same rule (Source: Q-129, Q-154, Q-272) |
| Result | Mitigated |
| Checks | TEST-220, TEST-219 |

### ATTACK-151: Fee diversion by self-routing

| Field | Value |
|---|---|
| Target | LPVaultSwap Avana fee, oversized funding |
| Objective | Lower Avana's fee by converting badly on purpose, keeping the difference through a sandwich, or by oversizing `debtToCover` or a helper loan |
| Affected steps | `LIQ` waterfall and funding |
| Prerequisites | Any address; builder access |
| Attack approach | Sandwich its own conversion so `R` falls toward `minRec` and the surplus shrinks; or borrow far more of the debt asset than Aave consumes through the flash liquidation helper so the premium on the excess eats the surplus |
| Impact | None: the fee does not move while the surplus covers it, and the premium on the excess falls on the caller alone |
| Expected protection | `INV-036`, `INV-086`: Avana's fee is `A = min(⌊G × avanaFeeShareBps / 10⁴⌋, S)` with the oracle gain `G = max(0, V − D)` and the realized surplus `S = max(0, R' − D)` (2.11 `SPEC-LIQ-008`, `SPEC-LIQ-009`), so it is set by the oracle value `V` of the seized units and never exceeds the realized gain over the debt `D`; no flash premium enters either term, because LPVaultSwap takes no flash loan in a liquidation (`Q-404`); routing choices cannot lower it while `S` covers it, and it never makes a liquidation revert; there is no buy leg or sell-back (`INV-070`); the unused funding `Kf − D` returns to the caller inside `keeperOut`, and a helper's premium on its whole loan is paid from its caller's payout (2.11 `REQ-HELPER-007`), never by Avana's fee or the borrower. Example (USDC debt, 2.11): `V` = 2,047.5, `D` = 1,950 and `avanaFeeShareBps` = 2,000 give `G` = 97.5 and `A` = 19.5 USDC; a self-sandwich that lowers `R` from 2,040.3 to 2,027 USDC, just above `minRec` = 2,026.024998 USDC, leaves `S` = 77 USDC and `A` stays 19.5 USDC, where 20 % of the realized surplus would have fallen from 18.06 to 15.4 USDC (Source: Q-097, Q-231, Q-235, Q-256, Q-333, Q-404) |
| Result | Mitigated |
| Checks | TEST-240, PROP-069 |

### ATTACK-152: Admin-role grant takeover

| Field | Value |
|---|---|
| Target | `grantRole` on every upgradeable Avana contract and the AvanaTimelock |
| Objective | Hand `APPLICATION_ADMIN` or `DEFAULT_ADMIN_ROLE` to an attacker address through one role-change operation, then upgrade the AaveAdapter or LPVaultSwap at once with no delay and no canceller |
| Affected steps | `EMG`, `MKT` |
| Prerequisites | Governance multisig compromise; the Aave governance executor, the only canceller of role changes, misses the operation |
| Attack approach | Schedule `grantRole(APPLICATION_ADMIN, attacker)` on the AaveAdapter as a pure role-change operation; after the normal delay, execute it and call `upgradeToAndCall` directly |
| Impact | None: the grant reverts |
| Expected protection | `INV-084`, `INV-051`, `INV-065`: every upgradeable Avana contract overrides `_grantRole` to revert `AdminRoleOnlyTimelock(role, account)` when the role is `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` and the account is not the timelock, and the AvanaTimelock reverts the same error for a grant of its own `DEFAULT_ADMIN_ROLE` to anyone but itself, so upgrade and admin power never leave the timelock; moving to a new timelock is an upgrade of each contract to an implementation that names it, at the normal delay and cancellable by every canceller (Source: Q-228, Q-259) |
| Result | Mitigated |
| Checks | TEST-242, TEST-214, PROP-070 |

## AMM-neutral core, Hubs and chains

Scenarios against the shared core that serves several AMM protocols, debt assets, Hubs and chains: `ATTACK-153` … `ATTACK-168` follow the red-team review (`AMMN-RT-01` … `AMMN-RT-16`) and `ATTACK-169` … `ATTACK-194` follow the flow walkthroughs (`AMMN-FLOW-01` … `AMMN-FLOW-26`), in that order, and `ATTACK-195` … `ATTACK-197` follow the attacks found in the final re-check (`FINDING-293` … `FINDING-295`); `ATTACK-198` and `ATTACK-199` follow the loss order of `Q-410`. A *market* is one (chain, AMM protocol, pool, exact position shape); for concentrated liquidity the shape is the exact `[tickLower, tickUpper]` range.

### ATTACK-153: Narrow-range position credited at the market range's value

| Field | Value |
|---|---|
| Target | AMM integration custody check, Collateralization, LPOracle |
| Objective | Pledge a concentrated position whose range is narrower than the market's range, so each unit of liquidity is credited at the market range's value per unit |
| Affected steps | `DEP` custody, record and mint steps |
| Prerequisites | A concentrated-liquidity market (Uniswap v3 or Aerodrome Slipstream) with a fixed range; capital for one position in the same pool |
| Attack approach | Market range `[0.90, 1.10]` on a stable pool, worth 0.097854 USD per unit of liquidity at price 1. Mint a position one tick either side of spot with $10,000 of tokens: liquidity `L = 100,007,500`. Pledge it, so the record is credited `L` units at $0.097854 each = $9,786,145 (×979), and borrow up to the caps |
| Impact | None: the pledge reverts |
| Expected protection | `INV-005`, `INV-078`: a market fixes `(pool, tickLower, tickUpper)` as immutables of its vault token and LPOracle; the integration's `validate` step at custody reads the position's pool and ticks from the market's own position manager and requires `tickLower == market.tickLower` and `tickUpper == market.tickUpper` exactly, both multiples of the pool's `tickSpacing` (signed alignment), with the pool derived through the market's factory equal to the vault token's pool; any other shape reverts before a record exists, so every credited unit has the value per unit the LPOracle prices (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-279, TEST-264, TEST-265, PROP-083, FINDING-201 |

### ATTACK-154: Oracle ratio outside the range priced without clamping

| Field | Value |
|---|---|
| Target | LPOracle pricing library for concentrated liquidity |
| Objective | Get collateral valued above its real holdings while a token of the pair depegs past the market's range edge |
| Affected steps | `DEP`, `BOR`, every LPOracle read |
| Prerequisites | A concentrated-liquidity market; a depeg that moves the oracle ratio outside the range |
| Attack approach | Market range `[0.99, 1.01]`; token1 falls to $0.952, so the oracle ratio is 1.05. A position of `L = 1,000,000` holds 10,000 token1 worth $9,524. Unclamped math gives `y = 29,708` and `x = −19,137`, floored to 0: $28,293 (×2.97). Buy the depegged token, mint in-range positions, pledge and borrow |
| Impact | None: the served value is the clamped value |
| Expected protection | `INV-078`, `INV-055`: the LPOracle computes the oracle square-root ratio from the feed prices and token decimals, rounds it down, clamps it to `[sqrtRatio(tickLower), sqrtRatio(tickUpper)]` before computing amounts, floors each token amount and then subtracts 1 raw unit, and values the amounts at the oracle price vector (`value = Σ amountᵢ × priceᵢ`). At the oracle ratio 1.05 the clamp gives `x = 0`, `y = 10,000`: $9,520 after rounding, never more than the holdings. The value is the minimum over reachable holdings, so it is monotone in each price (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-279, TEST-266, PROP-083, FINDING-202 |

### ATTACK-155: Third-party seizure through Spoke configuration on a standard Spoke

| Field | Value |
|---|---|
| Target | Standard Aave V4 CDP Spoke configuration, vault token |
| Objective | Seize vault-token collateral without a token transfer, so the vault token's recipient rule never runs and the seized shares back new debt that cannot be liquidated |
| Affected steps | `LIQ`, `BOR`, `DEF` |
| Prerequisites | A configuration change on the Spoke: `receiveSharesEnabled = true`, a non-zero `liquidationFee`, a reinvestment controller, or a borrowable vault-token reserve (steward mistake, proposal or compromised role) |
| Attack approach | After the change and before Avana's drift check trips `CONFIG_DRIFT`, call `Spoke.liquidationCall(vaultReserve, debtReserve, victimProxy, 100,000, true)`; receive Spoke shares worth 105,000 at LB 1.05; borrow against them directly on the Spoke (100,800 at CF 0.96) |
| Impact | Bounded to the window from the Aave change until the drift check trips `CONFIG_DRIFT` (normally one block, because the check runs on every Avana entry point and on a per-block keeper poke), to the positions liquidatable in it, and to what the Spoke draw caps let the attacker borrow against the seized shares; without the settings the seizure reverts |
| Expected protection | `INV-093`, `INV-011`, `INV-029`, `INV-014`: the listing AIP sets `receiveSharesEnabled = false` on every Avana collateral reserve, `liquidationFee = 0`, no reinvestment controller and a non-borrowable vault-token reserve, and `listCollateralMarket` checks each before the market activates; with shares disabled every seizure moves vault tokens, and the token's transfer rule admits only Adapter mint to a registered proxy of the market, proxy to its home Hub (supply), home Hub to that proxy (withdraw), home Hub to LPVaultSwap (seizure) and Adapter burn, so any other liquidator's `liquidationCall` that seizes at least one share reverts on the transfer (a dust call that seizes zero shares moves nothing, `ATTACK-028`); the drift check reads the four settings on every Avana entry point and on a per-block keeper poke (`pokeConfig`), and a change trips the market's `CONFIG_DRIFT` breaker, which stops new pledges and borrows and never liquidation; Collateralization's seizure check reverts when the share drop differs from the tokens received (Source: Q-120, Q-224, Q-363, Q-382) |
| Result | Accepted risk — owner: Aave DAO (Spoke configuration roles); bound: seizures outside LPVaultSwap from the Aave change until `CONFIG_DRIFT` trips, and borrowing against the seized shares within the Spoke draw caps of the debt reserves |
| Checks | TEST-268, TEST-109, PROP-078, FINDING-203 |

### ATTACK-156: Attacker-chosen proxy implementation

| Field | Value |
|---|---|
| Target | PositionProxy, ProxyManager |
| Objective | Register attacker code as a proxy, keep an unpatched proxy version live, or hold two accounts for one (wallet, Spoke, market) by replacing a proxy |
| Affected steps | `DEP` first pledge, `BOR`, `LIQ` |
| Prerequisites | Any wallet; a phishing "upgrade your account" page |
| Attack approach | Ask the ProxyManager to replace the wallet's proxy with an implementation the attacker names; use the new registered proxy to borrow on the Spoke directly, skip the RiskModule gates, or receive seized vault tokens |
| Impact | None: no implementation choice exists; proxy code is fixed at creation |
| Expected protection | `INV-063`, `INV-064`, `INV-065`, `INV-016`: a PositionProxy is a logic-free immutable account created by CREATE2 with wallet, Spoke and market bound at creation; it has no upgrade path and no function that replaces its code, so no caller can choose or change it; it executes only calls from the chain's AaveAdapter, which holds all logic and upgrades through the timelock; there is one proxy per (wallet, Spoke, market), and the vault token registers only the proxy the Adapter created at `predictProxy(wallet, spoke, marketId)` (Source: Q-225, Q-363) |
| Result | Mitigated |
| Checks | TEST-271, TEST-190, PROP-076, FINDING-204 |

### ATTACK-157: Hub-wide caps multiplied by the number of Spokes

| Field | Value |
|---|---|
| Target | Collateralization cap counters, RiskModule |
| Objective | Push a Hub's exposure to one token, depositor or pool above its cap by spreading pledges over several Spokes and markets |
| Affected steps | `DEP` cap checks, top-up, re-credit |
| Prerequisites | Several CDP Spokes or markets on one Hub sharing a token, for example USDC/USDT, USDT/DAI and USDT/GHO |
| Attack approach | With `tokenUsdCap[USDT]` = $10M, pledge $10M of USDT exposure in each of three markets, or list one pool twice with two ranges to double the pool-share cap |
| Impact | None: the fourth $10M is refused |
| Expected protection | `INV-092`, `INV-027`, `INV-028`: the token and depositor counters live in the one per-chain ledger, keyed by Hub, and every pledge, top-up, re-credit and debit in every market of the Hub updates the same counter; the pool-share counter is keyed by pool and sums every market (every range or shape) of that pool on the chain, so k ranges of one pool share one `poolShareMaxBps` cap; token exposure is counted per funding Hub over every Spoke that draws from it; adding Spokes or markets never adds cap room (Source: Q-174, Q-363, Q-383) |
| Result | Mitigated |
| Checks | TEST-272, PROP-077, FINDING-205 |

### ATTACK-158: Uniswap v4 hook keeps or blocks the removed liquidity

| Field | Value |
|---|---|
| Target | AMM integration unwind for Uniswap v4 |
| Objective | Pledge a position in a pool whose hook takes part or all of each removal, or reverts it, so liquidation recovers nothing |
| Affected steps | `MKT` listing, `LIQ` unwind, `WDR` |
| Prerequisites | A Uniswap v4 pool with `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` or a `beforeRemoveLiquidity` hook, or an upgradeable hook |
| Attack approach | Pledge, borrow at the full oracle value, and let the hook keep 1% (realizable 9,876 against 9,975) to 100% (0 against 9,975) of every removal, or switch the hook to revert |
| Impact | None for listed markets: such a pool cannot be listed |
| Expected protection | `INV-078`, `INV-005`: a Uniswap v4 market lists only a pool whose hook address is zero or on the hook allowlist, which admits no remove-liquidity hook flags, no return deltas and no upgradeable hook, with a pinned code hash; the integration's `validate` step checks the pool key's hook bits on-chain at every pledge; the unwind of `x` units returns n token amounts with per-token minimums, so a hook that keeps tokens makes the removal revert rather than settle short (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-283, FINDING-206 |

### ATTACK-159: Read-only reentrancy or same-transaction pool manipulation in reserve-based pricing

| Field | Value |
|---|---|
| Target | LPOracle pricing for Uniswap v2, Curve and Balancer markets |
| Objective | Read the pool's invariant or supply mid-update, or inflate them inside one transaction, and borrow against the inflated value |
| Affected steps | `BOR`, `WDR`, `DEP` |
| Prerequisites | A reserve-based market (v2, Curve StableSwap-NG, Balancer weighted or stable) |
| Attack approach | Inside a Curve `remove_liquidity` that sends native ETH before balances settle, call `AaveAdapter.borrow` from `receive`; or call it inside a Balancer join or exit callback; or donate to a rate token or ERC-4626 vault to raise D; or rely on v2's pending `feeTo` mint missing from `totalSupply` |
| Impact | None: the read reverts or excludes the manipulated term |
| Expected protection | `INV-078`, `INV-055`: these AMM protocols are listed only after their readiness guards pass; v2 values reserves from `getReserves`, never `balanceOf`, and supply as effective supply including pending `feeTo` liquidity; Curve and Balancer value at the minimum token price and check the pool's or Vault's reentrancy lock before every read; every AMM protocol has a per-block quote-change cap that refuses a quote moved more than the cap within one block; rate and 4626 tokens are listed only with a capped rate feed (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-283, FINDING-207 |

### ATTACK-160: TWAP buffer griefing on a 2-second chain

| Field | Value |
|---|---|
| Target | LPOracle TWAP consistency check on Base |
| Objective | Keep a market Drifting cheaply, which blocks new-account pledges and borrowing and lowers the served price to `min(fresh, A)` |
| Affected steps | `DEP`, `BOR`, `WDR` |
| Prerequisites | A Slipstream market on Base; about $2 of Base gas |
| Attack approach | With `twapWindow = 1,800 s` and a buffer sized for 12-second blocks (`n = 151`, covering 302 s on 2-second blocks), make one dust swap per block for 151 blocks so `observe([W, 0])` reverts `OLD` |
| Impact | None: the buffer covers the window |
| Expected protection | `INV-055`, `INV-075`: the observation cardinality is `n ≥ ⌈W / blockTime⌉ + 1` with the block time of the market's chain (Base: `⌈1,800 / 2⌉ + 1 = 901`), checked at listing and by the drift check; the TWAP is a consistency check only and never sets the price; each AMM integration decodes its own `slot0` (Slipstream's has 6 fields), so a decoding mismatch cannot force Drifting (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-265, TEST-275, FINDING-208 |

### ATTACK-161: One-sided unwind at a range edge against two-leg route stress

| Field | Value |
|---|---|
| Target | LPVaultSwap conversion, listing route stress |
| Objective | Make every liquidation of a concentrated market miss its per-leg `minOut` by pushing spot past the range edge, so the whole position unwinds into one token |
| Affected steps | `LIQ` unwind and conversion |
| Prerequisites | A concentrated-liquidity market; capital to cross the in-range liquidity |
| Attack approach | Before a liquidation, push spot past the edge. The unwind returns one token worth V; on a constant-product route of depth 10V one V leg loses 9.09%, against 4.76% for each of two V/2 legs, so `INV-083`'s per-leg minimum at `s = 5%` fails |
| Impact | Bounded: a liquidation that misses its floor reverts or uses the caller's shortfall top-up |
| Expected protection | `INV-083`, `INV-034`, `INV-039`: each token's swap routes are stressed at listing and in the route-depth monitor with the full position value V in a single token (the composition at each range edge), and the market's caps are sized so that leg clears its oracle `minOut`; a leg that still misses reverts and the caller may top up the shortfall within `maxShortfall`; there is no in-kind fallback (Source: Q-250, Q-363, Q-401) |
| Result | Mitigated |
| Checks | TEST-281, FINDING-209 |

### ATTACK-162: Cross-Hub proxy squatting

| Field | Value |
|---|---|
| Target | ProxyManager, AaveAdapter |
| Objective | Occupy a wallet's proxy address for another Hub's Spoke, so the wallet can never use that market or its account is driven by the wrong code |
| Affected steps | `DEP` first pledge |
| Prerequisites | A faulty or hostile AaveAdapter upgrade |
| Attack approach | Call `deployProxy(wallet, spokeOfHubB, marketId)` from a component serving Hub A before the wallet's first pledge, with that component baked in as the proxy's controller |
| Impact | None: one Adapter serves every Hub on a chain |
| Expected protection | `INV-064`, `INV-063`: each chain has one ProxyManager and one AaveAdapter, scoped by Hub inside; `deployProxy` accepts only that Adapter; the CREATE2 salt binds `(wallet, spoke, marketId)` and the Spoke binds its Hub; the proxy's code is fixed and executes only the chain's Adapter, so no second controller exists to squat with (Source: Q-225, Q-363) |
| Result | Mitigated |
| Checks | TEST-271, PROP-076, FINDING-210 |

### ATTACK-163: Cross-Hub credit line drawn past the funding Hub's limit

| Field | Value |
|---|---|
| Target | MarketRegistry, cross-Hub credit-line registry, Coverage Spokes |
| Objective | Draw a funding Hub's asset from Spokes homed on other Hubs beyond what the funding Hub approved, and leave the resulting deficit uncovered |
| Affected steps | `BOR`, `DEF`, `MKT` `enableDebtReserve` |
| Prerequisites | A debt reserve whose funding Hub differs from the Spoke's home Hub |
| Attack approach | Have each Hub's registry approve its own Spokes up to the line, so the sum over Hubs exceeds the funding Hub's line; let a Volatile Spoke default on Stable Hub USDC, where the Stable Hub's Coverage Spoke does not recognise the foreign Spoke |
| Impact | None: the cap that binds is the funding Hub's |
| Expected protection | `INV-094`, `INV-057`, `INV-071`: the funding Hub owns the cross-Hub cap; one registry sums every line per (funding Hub, asset) over every drawing Spoke on every Hub, and `enableDebtReserve` and every draw check the sum against that cap, which is at most the funding Hub's first-loss coverage; a pause of the funding Hub stops the line; each debt reserve records its funding Hub and its Coverage Spoke is the one of (funding Hub, asset); cross-Hub lines are off at launch (cap 0) (Source: Q-233, Q-363) |
| Result | Mitigated |
| Checks | TEST-273, PROP-079, FINDING-211 |

### ATTACK-164: Vault-token Hub asset attached to a second Spoke

| Field | Value |
|---|---|
| Target | Hub vault-token asset, LPVaultSwap seizure |
| Objective | Draw vault tokens out of the Hub through a second Spoke, so proxy withdrawals and seizures revert and the drawn tokens look like pending balance |
| Affected steps | `WDR`, `LIQ`, `MKT` |
| Prerequisites | A shared Hub; a Hub admin action attaching vault-token asset `m` to another Spoke with a non-zero `drawCap` |
| Attack approach | Attach the asset; draw vault tokens to a registered proxy or to LPVaultSwap |
| Impact | None: the transfer is refused, and the configuration stops new activity |
| Expected protection | `INV-003`, `INV-011`, `INV-093`: the vault token's transfer rule admits only Adapter mint to a registered proxy of the market, proxy to its home Hub (supply), home Hub to that proxy (withdraw), home Hub to LPVaultSwap (seizure) and Adapter burn, so a draw through another Spoke reverts on the transfer; `listCollateralMarket` and the drift check require the Hub's Spoke list for the vault-token asset to be exactly the market's CDP Spoke, and a mismatch trips the breaker for new activity; the Adapter and LPVaultSwap take the Spoke only from the market's record (Source: Q-224, Q-363) |
| Result | Mitigated |
| Checks | TEST-268, PROP-078, FINDING-212 |

### ATTACK-165: One market's liquidations starving another's settlement funding

| Field | Value |
|---|---|
| Target | Settlement funding shared across markets |
| Objective | Use a shared Avana settlement allowance on one market so liquidations in other markets revert |
| Affected steps | `LIQ` settlement |
| Prerequisites | Keeper key; a busy liquidation day in a low-quality market |
| Attack approach | Liquidate many accounts in one market, each leaving a rounding gap, hoping to use up a shared allowance |
| Impact | None: no allowance is shared between markets |
| Expected protection | `INV-097`, `INV-037`, `INV-075`: the SettlementBudget is removed (`Q-397`); each liquidation's caller funds its own settlement, including any rounding gap through its shortfall top-up, so liquidations in one market draw on nothing that another market's liquidations need (Source: Q-363, Q-387, Q-397) |
| Result | Mitigated |
| Checks | TEST-277, PROP-084, FINDING-213 |

### ATTACK-166: Tokenized-stock market-hours and corporate-action gaps

| Field | Value |
|---|---|
| Target | LPOracle and listing for a Volatile LP Hub market holding a tokenized stock |
| Objective | Borrow against a feed that pauses while the reference market is closed, or exploit a split or dividend that the feed and the pool see differently |
| Affected steps | `BOR`, `LIQ`, `MKT` |
| Prerequisites | A listed tokenized-stock market; a weekend or a corporate action |
| Attack approach | Over a weekend, buy the token on the DEX after news, pledge an LP position valued at Friday's close, and borrow; or pledge before a split implemented as a rebase |
| Impact | Bounded by the market's caps and collateral factor |
| Expected protection | `INV-024`, `INV-075`, `INV-087`: a feed is fresh only within its own heartbeat plus a margin, and borrow and withdraw also need an independent second source to agree within the deviation band, so a closed-market feed against a moving pool blocks new risk; the TWAP consistency check blocks borrowing when the pool diverges by more than its tolerance; a token whose issuer restricts holders is listed only after LPVaultSwap, the swap routes and the LPVault are allowlisted, and the market is offboarded before a scheduled corporate action (Source: Q-363) |
| Result | Accepted risk — owner: Avana governance (Volatile LP Hub listing); bound: the market's caps and collateral factor sized for a 40% weekend gap |
| Checks | TEST-276, FINDING-214 |

### ATTACK-167: Position manager, factory and pool from different AMM protocols in one market

| Field | Value |
|---|---|
| Target | `listCollateralMarket`, AMM integration custody check |
| Objective | Bind a market to a thin attacker-seeded pool by pairing a Slipstream position manager with a Uniswap v3 factory (or the reverse) in copied configuration |
| Affected steps | `MKT` listing, `DEP` |
| Prerequisites | A listing proposal that copies an earlier market's configuration; both AMM protocols on one chain (Base) |
| Attack approach | `getPool(t0, t1, 100)` resolves to a fee-100 pool on v3 and a `tickSpacing`-100 pool on Slipstream; list with the mismatched pair and pledge from the attacker's pool |
| Impact | None: the listing reverts |
| Expected protection | `INV-005`, `INV-017`: each LPVault serves one AMM protocol on one chain and holds its position manager and factory as immutables; `listCollateralMarket` checks that the position manager's factory, the pool's factory and the market factory agree, that the factory lookup (by fee on v3, by `tickSpacing` on Slipstream, for the Slipstream factory generation named) returns the market's pool, and that the pool's code hash matches the AMM protocol; the custody check reads `positions()` with the integration's own decoder (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-264, TEST-265, FINDING-215 |

### ATTACK-168: Moving an account to another proxy to dodge a liquidation

| Field | Value |
|---|---|
| Target | PositionProxy, LPVaultSwap |
| Objective | Front-run a keeper's liquidation by moving the account to a new proxy so `liquidate(oldProxy, …)` reverts |
| Affected steps | `LIQ` |
| Prerequisites | An account with HF < 1 |
| Attack approach | Submit a move of the account to another proxy ahead of the keeper's transaction |
| Impact | None: no operation moves an account between proxies |
| Expected protection | `INV-064`, `INV-065`, `INV-046`: the proxy is bound to (wallet, Spoke, market) at creation and no operation moves its position or debt to another proxy, so the account a keeper targets cannot move (Source: Q-225, Q-363) |
| Result | Mitigated |
| Checks | TEST-271, PROP-076, FINDING-216 |

### ATTACK-169: Lock that cannot admit vaults and ledgers added later

| Field | Value |
|---|---|
| Target | Lock, LPVault, Collateralization |
| Objective | Halt every flow of a Spoke or market added after deployment, or re-enter a vault or ledger through an entry point that no Lock member guards |
| Affected steps | `DEP`, `WDR`, `FEE`, `LIQ` |
| Prerequisites | A Spoke or market deployed after the Lock; a token or route callback |
| Attack approach | Call the new market's vault or ledger entry point directly, or from a callback while another flow holds the Lock |
| Impact | None: the call reverts, and new Spokes work without a Lock change |
| Expected protection | `INV-091`, `INV-054`: the Lock has exactly two members, the AaveAdapter and LPVaultSwap, fixed at deployment; every value-moving entry point of Collateralization accepts only a Lock member while the Lock is held, and every position-moving entry point of an LPVault accepts only Collateralization while the Lock is held, so it runs only inside a call tree a Lock member opened; vaults and ledgers never need membership; `returnStray` is timelock-only and runs only while the Lock is free and new Spokes and markets never need a Lock redeploy; a second outer entry point in one call tree reverts (Source: Q-148, Q-363) |
| Result | Mitigated |
| Checks | TEST-270, PROP-075, FINDING-217 |

### ATTACK-170: Liquidation on a chain where GHO has no flash mint or route depth

| Field | Value |
|---|---|
| Target | LPVaultSwap funding and payout on Base |
| Objective | Leave Slipstream accounts unliquidatable, or push a hidden bridged-GHO discount into the waterfall, by relying on a settlement flow that would need a GHO flash mint and GHO routes |
| Affected steps | `LIQ` funding, conversion and payout; `REP` repay with collateral |
| Prerequisites | A market on Base, where GHO has no flash mint and no peg module |
| Attack approach | Let accounts fall below HF 1 and wait for liquidations that would need GHO on Base |
| Impact | None: no step needs GHO unless the debt is GHO |
| Expected protection | `INV-070`, `INV-040`, `INV-035`: the caller funds the debt asset itself, from its own balance or through the flash liquidation helper, which borrows it from the chain's Aave V3 Pool with `flashLoan` (single asset, mode 0); LPVaultSwap takes no flash loan; the seized position unwinds into n tokens that swap over the market's swap routes into the debt asset; Avana's 20% surplus fee, the borrower's surplus and the caller's `keeperOut` are paid in the debt asset, so GHO is used only when the debt is GHO; if the Pool's liquidity is short, the caller funds the debt from its own inventory (Source: Q-363, Q-404) |
| Result | Mitigated |
| Checks | TEST-267, TEST-280, PROP-080, FINDING-218 |

### ATTACK-171: Liquidation on stale prices after an L2 sequencer outage

| Field | Value |
|---|---|
| Target | LPOracle, DebtOracle, RiskModule on Base |
| Objective | Liquidate accounts on the first prices after a sequencer restart, before borrowers could act, or borrow through transactions forced in from L1 during the outage at stale answers |
| Affected steps | `LIQ`, `BOR`, `WDR`, `DEP` |
| Prerequisites | A Base sequencer outage |
| Attack approach | Queue liquidations and borrows to execute at the restart |
| Impact | None for borrows; liquidations wait for the grace period |
| Expected protection | `INV-098`, `INV-024`: each L2 chain has a sequencer-uptime feed (Base `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`); while it reports down, new pledges, borrows and withdrawals that leave debt revert, and after restart a grace period keeps them closed and admits liquidation only of accounts below `graceHealthFactor`; feed freshness uses each feed's own heartbeat plus a margin, so Base's 86,400 s feeds are listable (Source: Q-088, Q-363) |
| Result | Mitigated |
| Checks | TEST-275, TEST-276, FINDING-219 |

### ATTACK-172: Proxy bug that cannot be patched, or a proxy replacement that strands borrowers

| Field | Value |
|---|---|
| Target | PositionProxy, AaveAdapter |
| Objective | Trap borrowers whose proxy has a bug in its repay or withdrawal path, or whose move to a replacement proxy is refused under a pause, a breaker or a full `drawCap` |
| Affected steps | `REP`, `WDR`, `LIQ` |
| Prerequisites | A defect in proxy code, or a proxy-replacement path through new-debt gates |
| Attack approach | Exploit the defect while borrowers cannot move, then let them be liquidated |
| Impact | None: proxy code holds no logic to be defective, and no flow replaces a proxy |
| Expected protection | `INV-016`, `INV-063`, `INV-065`, `INV-043`, `INV-045`: the proxy is a logic-free immutable account that forwards only the AaveAdapter's calls; all logic is in the Adapter, which upgrades through the timelock, so a fix reaches every account at once; exits never depend on proxy code and no flow replaces a proxy, so no exit passes through a new-debt gate (Source: Q-225, Q-363) |
| Result | Mitigated |
| Checks | TEST-271, PROP-076, FINDING-220 |

### ATTACK-173: Cross-Hub debt reserve whose losses land on another Hub

| Field | Value |
|---|---|
| Target | Debt-reserve funding, Coverage Spokes, pending settlement |
| Objective | Borrow a funding Hub's asset under a different Hub's risk rules and leave the deficit on the funding Hub's suppliers, or send pending-settlement proceeds to the wrong Coverage Spoke |
| Affected steps | `BOR`, `LIQ`, `DEF`, `MKT` `enableDebtReserve` |
| Prerequisites | A cross-Hub debt reserve |
| Attack approach | Enable a Volatile Spoke's USDC reserve funded by the Stable Hub, borrow to the cap, and let the volatile collateral fall |
| Impact | None at launch: cross-Hub lines are off; when on, bounded by the funding Hub's cap |
| Expected protection | `INV-094`, `INV-071`, `INV-042`: each debt reserve records its funding Hub; the funding Hub owns the cross-Hub cap, one registry sums lines per (funding Hub, asset), and the cap is at most that Hub's first-loss coverage; a deficit is covered only by the Coverage Spoke of (funding Hub, asset); pending settlement sends recovered value to the Coverage Spoke of the market's (Hub, debt asset) (Source: Q-233, Q-236, Q-363) |
| Result | Mitigated |
| Checks | TEST-273, TEST-280, PROP-079, FINDING-221 |

### ATTACK-174: Credit lines across Hubs enforced only off-chain

| Field | Value |
|---|---|
| Target | `drawCap` configuration across Hubs |
| Objective | Raise one Spoke's `drawCap` through a separate AIP so the sum across Hubs exceeds the asset's credit line |
| Affected steps | `BOR`, `MKT` |
| Prerequisites | A mistaken or hostile cap change |
| Attack approach | Raise a foreign Spoke's `drawCap` on the funding Hub's asset |
| Impact | None: the borrow is refused |
| Expected protection | `INV-094`, `INV-057`: the registry's sum per (funding Hub, asset) is read on-chain at every draw; a draw that would leave the sum of drawn amounts above the funding Hub's cap reverts, and no draw completes that leaves a Spoke above its `drawCap` (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-273, TEST-274, PROP-079, PROP-081, FINDING-222 |

### ATTACK-175: One stale market liquidating healthy collateral in the same account

| Field | Value |
|---|---|
| Target | Account structure on a CDP Spoke that lists several markets |
| Objective | Use one market's stale oracle or breaker to liquidate a borrower's healthy collateral in another market |
| Affected steps | `LIQ`, `BOR` |
| Prerequisites | A wallet using two markets on one Spoke |
| Attack approach | Wait for market A's feed to expire, then liquidate the wallet's account and seize its market B collateral |
| Impact | None: market B's collateral sits in a different account |
| Expected protection | `INV-064`, `INV-075`: each wallet gets one PositionProxy per (CDP Spoke, market), so every market has its own Aave account and health factor and nothing is cross-collateralized; a failure in market A can liquidate only market A's account (Source: Q-276, Q-363) |
| Result | Mitigated |
| Checks | TEST-271, PROP-076, FINDING-223 |

### ATTACK-176: Full-range math applied to a bounded-range market

| Field | Value |
|---|---|
| Target | LPOracle, cap counters, pool-share check |
| Objective | Profit from value per unit, shocks, collateral factor or pool-share checks derived for full range on a market with a bounded range |
| Affected steps | `DEP`, `BOR`, `LIQ` |
| Prerequisites | A bounded-range market |
| Attack approach | Pledge positions in a bounded market while a depeg pushes it out of range |
| Impact | None: every formula uses the market's exact range |
| Expected protection | `INV-078`, `INV-005`: the composition at the oracle price vector is computed for the market's exact `[tickLower, tickUpper]` with the oracle ratio clamped to the range; the pool-share check counts the market's own range; caps and the collateral factor are set at `listCollateralMarket` from the range's single-token composition at each edge (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-279, TEST-266, PROP-083, FINDING-224 |

### ATTACK-177: Pool spot move turns liquidation into a revert

| Field | Value |
|---|---|
| Target | LPVaultSwap unwind and conversion |
| Objective | Keep an account unliquidatable by moving the pool's spot before each removal, so the recovered mix is worth less than the floor at oracle prices |
| Affected steps | `LIQ`, `REP` repay with collateral |
| Prerequisites | Capital to move the pool each block; a drained or thin pool |
| Attack approach | Swap in the keeper's block so the unwind returns a mix that fails `RecoveryBelowFloor` |
| Impact | Bounded: the attacker pays the slippage it creates every block, and the caller has two fallbacks |
| Expected protection | `INV-083`, `INV-034`, `INV-039`, `INV-062`: each leg's `minOut` comes from oracle prices and the composition at the oracle price, which a spot move cannot change; the caller may top up a shortfall; `liquidate` stays open to every address; the route-depth monitor lowers the market's caps when depth falls (Source: Q-085, Q-250, Q-363, Q-401, Q-404) |
| Result | Mitigated |
| Checks | TEST-266, TEST-281, FINDING-225 |

### ATTACK-178: Uniswap v3 calls applied to a Slipstream pool

| Field | Value |
|---|---|
| Target | Slipstream integration custody, unwind, fee collection and TWAP read |
| Objective | Make the vault check the wrong value or revert by relying on differences between Slipstream and Uniswap v3 |
| Affected steps | `DEP`, `WDR`, `LIQ`, `FEE` |
| Prerequisites | A Slipstream market |
| Attack approach | Pledge a gauge-staked position, or one minted through another NPM generation; rely on the v3 `slot0` decoding reading the wrong word; use a dynamic fee module to change the fee mid-flow |
| Impact | None: the Slipstream integration implements its own calls |
| Expected protection | `INV-005`, `INV-017`, `INV-055`: the Slipstream integration looks pools up by `tickSpacing`, reads `tickSpacing` from `positions()`, decodes the 6-field `slot0`, reads the live fee for the TWAP tolerance, names its NPM and factory generation as immutables, and accepts only unstaked positions, refusing a gauge-staked NFT (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-265, FINDING-226 |

### ATTACK-179: One vault token per pool blocks relisting, tiers and ranges

| Field | Value |
|---|---|
| Target | VaultTokenFactory, market identity |
| Objective | Prevent a pool from being listed with a second range or tier, or relisted after offboarding, so a fix cannot be deployed |
| Affected steps | `MKT` listing and offboarding |
| Prerequisites | A pool already listed once |
| Attack approach | Occupy the pool's vault-token address so a second listing collides |
| Impact | None: market identity includes the Spoke and the exact shape |
| Expected protection | `INV-005`, `INV-012`: a market is one (chain, AMM protocol, pool, exact shape) on one CDP Spoke, and `listCollateralMarket` creates its vault token and LPOracle per market, and the VaultTokenFactory keys tokens by `(spoke, marketKey)`, never one token per pool, so a pool can carry several ranges and a market can be relisted after its wind-down (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-264, TEST-279, FINDING-227 |

### ATTACK-180: Aave-side halt or pause of a Spoke or reserve

| Field | Value |
|---|---|
| Target | Aave Hub and CDP Spoke halt and pause flags |
| Objective | Block repay, debt-free withdrawal and liquidation of a market through an Aave-side halt, which Avana's own pause rules do not cover |
| Affected steps | `REP`, `WDR`, `LIQ` |
| Prerequisites | Aave governance halts the CDP Spoke or pauses a vault-token or debt reserve |
| Attack approach | Use the halt as containment while debt is open, then let prices move |
| Impact | Bounded: Avana's exits and liquidation stay open under every Avana stop; an Aave halt is outside Avana's control |
| Expected protection | `INV-081`, `INV-060`, `INV-093`: Avana's pause, breakers and freeze never reach exits or liquidation; the listing agreement and the playbook name reserve freeze and `drawCap` 0 as the Aave-side containment of a CDP Spoke, never a halt or reserve pause while debt is open; the drift check alarms on a halted Spoke and keepers resume liquidation the block the halt lifts (Source: Q-140, Q-363) |
| Result | Accepted risk, with the Aave-halt playbook — owner: Aave DAO (Hub and Spoke halt flags); bound: positions open while the halt lasts, within each market's caps |
| Checks | TEST-268, FINDING-228 |

### ATTACK-181: Third-party seizure on a standard Spoke without the liquidation-manager variant

| Field | Value |
|---|---|
| Target | Standard Aave V4 Spoke `liquidationCall`, vault token |
| Objective | Liquidate an Avana account as a third party, receive the seized collateral or trigger a deficit report outside LPVaultSwap |
| Affected steps | `LIQ`, `DEF` |
| Prerequisites | Any address; an account with HF < 1 |
| Attack approach | Call `liquidationCall` with `receiveShares = false`, with amount 0, or through a position-manager approval on the proxy |
| Impact | None: the call reverts on the token transfer |
| Expected protection | `INV-011`, `INV-093`, `INV-041`: CDP Spokes are standard, unmodified Aave V4 Spokes; the vault token admits only Adapter mint to a registered proxy of the market, proxy to its home Hub (supply), home Hub to that proxy (withdraw), home Hub to LPVaultSwap (seizure) and Adapter burn, and rejects a zero-amount transfer to any other recipient; shares, a liquidation fee, a reinvestment controller and a second Spoke on the vault-token asset are excluded by the required settings and the drift check; the proxy activates no position manager (Source: Q-120, Q-224, Q-363) |
| Result | Mitigated |
| Checks | TEST-268, TEST-109, PROP-078, FINDING-229 |

### ATTACK-182: ETH debt and non-stable collateral routed through an intermediate stablecoin

| Field | Value |
|---|---|
| Target | LPVaultSwap conversion and swap routes |
| Objective | Make liquidation of ETH debt against ETH/LST collateral fail at size because every step would convert through GHO and only stablecoin routes would exist |
| Affected steps | `LIQ`, `REP` |
| Prerequisites | A Correlated or Volatile market with ETH debt |
| Attack approach | Borrow at the limit and let liquidations hit thin intermediate-asset depth |
| Impact | None: no intermediate asset is on the path; the seized tokens swap directly into the debt asset |
| Expected protection | `INV-083`, `INV-070`, `INV-034`: the caller funds the debt asset itself, LPVaultSwap swaps each unwound token over the market's swap routes directly into the debt asset with a per-leg oracle `minOut`, and pays out in the debt asset; each token class has its own route requirements, stressed at full one-sidedness, and the market's debt cap is sized by that depth (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-267, TEST-281, FINDING-230 |

### ATTACK-183: Lenders exit ahead of an uncovered deficit

| Field | Value |
|---|---|
| Target | Lend Spoke supply on the funding Hub |
| Objective | Withdraw at full value ahead of other lenders while a deficit beyond the loss layers is outstanding, leaving the unbacked claims to the last lenders, who include public lenders and any new supplier |
| Affected steps | `DEF`, Lend Spoke withdraw |
| Prerequisites | A deficit larger than the Avana Umbrella and the DAO deficit offset of that (Hub, asset) together |
| Attack approach | Watch for deficit reports and withdraw first |
| Impact | Bounded by the funding Hub's first-loss coverage and the credit lines |
| Expected protection | `INV-042`, `INV-074`, `INV-094`: each (Hub, debt asset) has its own Coverage Spoke and every credit line is capped at the coverage behind it (`DEF-019`); deficits and coverage per drawing Spoke and Hub are readable on-chain and in the Lens (`uncoveredDeficit`, the deficit-adjusted share price, `getHubAssetExposure`), so no lender has an information advantage; the moment `uncoveredDeficit > 0`, P-18 sets the drawing Spokes' `drawCap`s to 0 and the Aave Protocol Guardian freezes the Lend Spoke reserve of that (Hub, asset), which stops new supply while withdrawals stay open, and the app's Lend page builds no supply into it (`REQ-ARCH-211`); an uncovered remainder follows Aave V4's Hub loss rule once realized (Source: Q-236, Q-353, Q-363, Q-407) |
| Result | Accepted risk — owner: Aave DAO and every Lend Spoke lender, public lenders included; bound: deficits beyond the Coverage Spoke's funds, which the credit-line caps size against; between report and realization a lender who withdraws first leaves at the unadjusted price, as Aave V4's share accounting allows, and its share of the loss falls on the suppliers who remain (`DEF-014`, `Q-408`) |
| Checks | TEST-273, TEST-297, FINDING-231 |

### ATTACK-184: Debt-free LP filling every cap

| Field | Value |
|---|---|
| Target | Cap counters |
| Objective | Fill `marketUsdCap`, `tokenUsdCap` or the pool share with debt-free pledges, or pledges carrying a token borrow, so borrowers cannot open accounts |
| Affected steps | `DEP` |
| Prerequisites | Capital; several wallets to pass `depositorUsdCap` |
| Attack approach | Pledge debt-free up to the caps and keep earning fees |
| Impact | Bounded: denial of new pledges in that market until the attacker leaves or governance raises the cap; no loss of funds |
| Expected protection | `INV-028`, `INV-092`: caps are counted per Hub in one ledger and charged at pledge; there is no idle-collateral mechanism (`Q-396`), so a debt-free position keeps its charge in the market's cap for as long as it stays pledged. This is the accepted risk AMMN-FLOW-16: caps are set at listing (`marketUsdCap`, `tokenUsdCap`, `depositorUsdCap`, `poolShareMaxBps`), monitoring reports each market's cap use by debt-free positions, `depositorUsdCap` limits each wallet, the attacker carries the full price risk of its positions while pledged, and governance can raise a market's cap through the timelock (Source: Q-157, Q-363, Q-384, Q-396) |
| Result | Accepted risk (AMMN-FLOW-16, `Q-396`) — owner: Avana governance (cap sizing at listing and monitoring); bound: a liveness loss for new pledges in one market, no loss of funds |
| Checks | TEST-272, FINDING-232 |

### ATTACK-185: Components without an assigned instance scope

| Field | Value |
|---|---|
| Target | Deployment per chain, Hub, AMM protocol and market |
| Objective | Exploit a component that is singular where it should be scoped, for example a borrow receiver refusal list that names one Hub |
| Affected steps | `BOR`, `LIQ`, `DEF` |
| Prerequisites | A deployment with several Hubs on one chain |
| Attack approach | Borrow with another Avana Hub or Spoke as the receiver |
| Impact | None: every component has one stated scope |
| Expected protection | `INV-092`, `INV-097`, `INV-020`: each chain has one ProxyManager, VaultTokenFactory, Timelock, AaveAdapter, LPVaultSwap, Collateralization, MarketRegistry, ParameterStore, RiskModule, PayoutEscrow (the payout escrow), Lock, DebtOracle, `IFlashSource` implementation (repay with collateral) and public flash liquidation helper; every cap, pause, breaker, route permission and emergency control in them is keyed by Hub, and by Spoke and market where it applies; there is one LPVault per AMM protocol per chain and a VaultToken and LPOracle per market; the borrow receiver refusal covers every Avana Hub and Spoke on the chain (Source: Q-363, Q-397, Q-404) |
| Result | Mitigated |
| Checks | TEST-270, TEST-272, FINDING-233 |

### ATTACK-186: Proxy squatting through a per-chain ProxyManager

| Field | Value |
|---|---|
| Target | ProxyManager `deployProxy` |
| Objective | Deploy a wallet's proxy for another Hub's Spoke first, so the legitimate pledge reverts |
| Affected steps | `DEP` first pledge |
| Prerequisites | A faulty or compromised component allowed to call `deployProxy` |
| Attack approach | Call `deployProxy(wallet, spoke, marketId)` ahead of the wallet |
| Impact | None |
| Expected protection | `INV-064`: only the chain's single AaveAdapter can call `deployProxy`, it creates a proxy only for `msg.sender` at its first pledge into the market, and the address is the CREATE2 address over `(wallet, spoke, market)`, so a squatter can only create the wallet's own proxy (Source: Q-225, Q-363) |
| Result | Mitigated |
| Checks | TEST-271, PROP-076, FINDING-234 |

### ATTACK-187: Emergency controls that reach only part of a chain

| Field | Value |
|---|---|
| Target | Pause, freeze and Guardian per Hub and per chain |
| Objective | Exploit a bug in shared code (Adapter, VaultTokenFactory, pricing library) on Hubs that were not paused, or act from an address frozen only on one Hub |
| Affected steps | `EMG`, `DEP`, `BOR` |
| Prerequisites | A bug in code shared by several Hubs on a chain |
| Attack approach | After the Guardian pauses one Hub, repeat the exploit on another |
| Impact | Bounded by the time the Guardian needs to pause each Hub |
| Expected protection | `INV-049`, `INV-081`, `INV-085`: each chain has its own Timelock, Safe and Guardian set; the pause is keyed by Hub and the Guardian pauses every Hub on the chain; the address freeze list is per chain and read by the RiskModule for every Hub; pauses never reach exits or liquidation (Source: Q-242, Q-363) |
| Result | Accepted risk — owner: the Guardian set of each chain; bound: the transactions mined before every Hub on the chain is paused |
| Checks | TEST-273, FINDING-235 |

### ATTACK-188: AaveOracle source switch that halts liquidation

| Field | Value |
|---|---|
| Target | AaveOracle entry of a CDP Spoke |
| Objective | Point the Spoke's AaveOracle at another source so every liquidation of the market reverts on Avana's freshness gate |
| Affected steps | `LIQ`, `MKT` |
| Prerequisites | An Aave governance change of the oracle source |
| Attack approach | Switch the source while accounts are near HF 1 |
| Impact | Bounded: new activity stops at once; liquidation follows the agreed oracle-switch procedure |
| Expected protection | `INV-029`, `INV-093`, `INV-055`: `deployCdpSpoke` creates the AaveOracle entry with the market's LPOracle; the drift check compares the AaveOracle source with the market's LPOracle and a change trips the breaker, which stops new activity and never liquidation; the oracle switch is a joint operation in the listing agreement (Source: Q-363) |
| Result | Accepted risk — owner: Aave DAO (AaveOracle configuration); bound: positions open while the foreign source is in place |
| Checks | TEST-268, FINDING-236 |

### ATTACK-189: Listing rules that only fit the first market

| Field | Value |
|---|---|
| Target | `listCollateralMarket`, `deployCdpSpoke` |
| Objective | List a market whose AMM protocol, decimals or token class the listing checks were not written for, so a check is skipped |
| Affected steps | `MKT` |
| Prerequisites | A listing proposal for Slipstream, WBTC/WETH (8 + 18 decimals) or a token without a Core Hub collateral factor |
| Attack approach | Propose the market with a configuration the generic checks do not cover |
| Impact | None: each AMM integration states its own listing checks |
| Expected protection | `INV-005`, `INV-078`: `listCollateralMarket` runs the AMM integration's own factory, shape and pricing checks; the LPOracle values any decimal sum by the composition at the oracle price vector; a market of an AMM protocol without a full integration lists only after its readiness guards pass (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-264, TEST-265, TEST-283, FINDING-237 |

### ATTACK-190: Wind-down that never ends

| Field | Value |
|---|---|
| Target | Market offboarding |
| Objective | Keep a market's feeds, routes and keepers in service indefinitely with one dormant borrower |
| Affected steps | `MKT` offboarding, `WDR` |
| Prerequisites | An offboarded market with an open account |
| Attack approach | Keep one small debt open |
| Impact | Bounded: one market's running cost |
| Expected protection | `INV-045`, `INV-046`: offboarding stops new activity and leaves exits and liquidation open; liquidation stays available for the remaining accounts as their health factor falls, and each LPVault is immutable and returns a position only to its depositor (Source: Q-363) |
| Result | Accepted risk — owner: Avana governance (market offboarding); bound: the running cost of one market's feeds, routes and keepers |
| Checks | TEST-269, FINDING-238 |

### ATTACK-191: Payout order without the borrower's surplus

| Field | Value |
|---|---|
| Target | LPVaultSwap waterfall |
| Objective | Take the borrower's surplus as caller payout |
| Affected steps | `LIQ` payout |
| Prerequisites | A liquidation whose recovery exceeds the debt repaid and fees |
| Attack approach | Liquidate an account whose seized collateral is worth more than the debt plus the bonus |
| Impact | None: the borrower's surplus is a stated step of the payout |
| Expected protection | `INV-035`, `INV-036`: Aave pulls `D` out of the caller's funding `Kf`, and the realized surplus `S = max(0, R' − D)` pays Avana's fee `A`, then the borrower surplus `B = max(0, S − G)`, then the keeper reward `kr = min(S, G) − A` inside `keeperOut`, in that order (`Q-337`); the caller's share is capped at the oracle gain `G = max(0, V − D)`, so a recovery above the oracle value goes to the borrower. Example: `R = 2,100` USDC against `V = 2,047.5` and `D = 1,950` gives `S = 150`, `A = 19.5`, `kr = 78` and `B = 52.5` USDC (Source: Q-337, Q-363, Q-404) |
| Result | Mitigated |
| Checks | TEST-280, FINDING-239 |

### ATTACK-192: Two-token and tokenId keys colliding in shared code

| Field | Value |
|---|---|
| Target | Collateralization records, pending settlement, indexing |
| Objective | Collide two positions that share a `tokenId` on different position managers or chains, or lose a third token's amount in a two-token record |
| Affected steps | `DEP`, `LIQ`, `WDR` |
| Prerequisites | Two AMM protocols on one chain, or an AMM protocol with more than two tokens |
| Attack approach | Pledge positions with equal ids in two AMM protocols |
| Impact | None |
| Expected protection | `INV-005`, `INV-001`: positions are identified by `positionKey` (bytes32) plus `integrationId`, never `tokenId`; every amount is an n-token array; pending settlement holds n token amounts per market (Source: Q-363) |
| Result | Mitigated |
| Checks | TEST-264, TEST-265, FINDING-240 |

### ATTACK-193: Keeper floor not met on every chain

| Field | Value |
|---|---|
| Target | LPVaultSwap keeper set |
| Objective | Halt borrowing or slow liquidation on a chain where few keepers hold the debt assets |
| Affected steps | `LIQ`, `BOR` |
| Prerequisites | A chain with a thin keeper set |
| Attack approach | Wait for a crash when keepers lack inventory |
| Impact | None for liquidation, which stays open to every address |
| Expected protection | `INV-048`, `INV-062`: the keeper floor `keeperFloor` (1, Avana's own keeper) applies to each chain's LPVaultSwap and is checked at activation; new borrowing halts only when 0 active committed operators remain on the chain (`LiquidationHalted`), and more operators, up to `MAX_KEEPERS` (32), can be added later; the registry gates no call (`Q-404`); a caller without inventory borrows the debt asset through the public flash liquidation helper from the chain's Aave V3 Pool, and each committed operator holds inventory of at least the largest single `debtToCover` the chain's caps allow for when the Pool is short (2.11 `REQ-SWAP-014`) (Source: Q-336, Q-363, Q-400, Q-404) |
| Result | Mitigated |
| Checks | TEST-267, FINDING-241 |

### ATTACK-194: Borrower unable to deleverage under Paused

| Field | Value |
|---|---|
| Target | LPVaultSwap `repayWithCollateral` |
| Objective | Liquidate a borrower at a bonus during a crash while the borrower, who has no outside funds, is refused repay with collateral |
| Affected steps | `REP` repay with collateral, `LIQ` |
| Prerequisites | `Paused(General)` during a price fall |
| Attack approach | Wait for HF to cross 1 and liquidate |
| Impact | Bounded: the account stays repayable by any payer and is liquidated only under Aave's rules |
| Expected protection | `INV-043`, `INV-089`, `INV-081`: repay by any payer, including a third party funding the borrower, is open under every pause state; repay with collateral leaves debt lower and HF not lower when it runs; liquidation runs at Aave's close factor and bonus (Source: Q-363) |
| Result | Accepted risk — owner: Avana governance (pause policy); bound: the liquidation bonus on the debt closed while `Paused(General)` lasts |
| Checks | TEST-280, FINDING-242 |

### ATTACK-195: Flash source that borrows from a Hub of the chain

| Field | Value |
|---|---|
| Target | `IFlashSource` implementation, flash liquidation helper |
| Objective | Fund a liquidation or a repay with collateral with liquidity drawn from the Aave V4 Hub that the liquidation repays or that absorbs its deficit, so the liquidation moves a Hub's own liquidity around instead of bringing outside capital |
| Affected steps | `LIQ` helper loan; `REP` repay-with-collateral flash loan; timelock replacement of the flash source |
| Prerequisites | A replacement flash source whose own address is not a Hub, for example a flash Spoke on an Aave V4 Hub of the chain; a timelock operation to install it |
| Attack approach | Install, through a normal-delay timelock operation, a source whose `LENDER()` is a Spoke address. An address comparison against the liquidated reserve's Hub passes, because the Spoke is not the Hub, yet every loan comes out of the Hub the CDP Spoke's debt reserve draws from. A Hub under stress then lends the debt asset that repays its own debt and carries the premium |
| Impact | None: the source is refused when it is set and on every call |
| Expected protection | `INV-095`, `INV-040`: the flash-source implementation reports the pool or Hub it borrows from (`LENDER()`), and LPVaultSwap reverts when that address equals any Hub recorded on the chain, in `MarketRegistry.setFlashSource` (`InvalidRoute`, when `isRecordedHub(LENDER())`) and again on every `deleverage` call (`FlashSourceIsHub`), so a Spoke that draws on a registered Hub is refused, and so is a source that later changes where it borrows; the flash liquidation helper refuses a Pool that is a recorded Hub at deployment and on every call (2.11 `REQ-HELPER-002`), and LPVaultSwap takes no flash loan in a liquidation. The check covers every registered Hub, not only the liquidated reserve's home or funding Hub, so the home-Hub and funding-Hub identities cannot diverge. The launch source is the Aave V3 Pool, which is not a Hub. When the source is refused, borrowers repay from their own funds, and liquidation, which never uses the source, is unaffected (`INV-046`). Example: a flash Spoke at `0xS…` reports `LENDER() = StableLPHub`; `setFlashSource(0xS…)` reverts `InvalidRoute` (Source: Q-386, Q-404) |
| Result | Mitigated |
| Checks | TEST-285, TEST-267, PROP-096, FINDING-293 |

### ATTACK-196: Blocklisted fee recipient halts liquidations

| Field | Value |
|---|---|
| Target | LPVaultSwap payouts (`feeRecipient`, borrower surplus, the caller's residues and dust legs, `settlePending` residue) |
| Objective | Make every routed liquidation and every pending settlement in a debt asset revert by getting a payout recipient blocklisted |
| Affected steps | `LIQ` payout waterfall; `settlePending` |
| Prerequisites | Issuer action: Circle or Tether blocklists Avana's treasury Safe (`feeRecipient`), or a keeper address, in the debt asset |
| Attack approach | With `feeRecipient` blocklisted in USDC, any routed liquidation with surplus `S > 0` transfers Avana's fee `A` to it; an unguarded transfer would revert the whole liquidation, on every USDC market of the chain, until a normal-delay `setFeeRecipient` takes effect (5 days) |
| Impact | None: the liquidation completes and an escrowable amount waits in escrow; a blocklisted caller cannot receive `keeperOut`, so only its own call reverts and any other address liquidates the account |
| Expected protection | `INV-036`, `INV-039`, `INV-061`: every transfer of Avana's fee, the borrower surplus, a residue or a dust leg is gas-limited and wrapped so its failure never reverts the liquidation; a transfer that reverts, returns `false` or runs out of gas moves the amount to the immutable PayoutEscrow, the payout escrow, credited to that recipient, which claims it later to an address of its choosing, the same path a refused borrower-surplus transfer uses (`ATTACK-057`); computed-zero transfers are skipped. The caller's payout `keeperOut` is not escrowable: it is paid directly to `msg.sender` or the call reverts (2.11 `REQ-SWAP-076`). Example: `A = 19.5` USDC to a blocklisted `feeRecipient` is deposited in the PayoutEscrow under `feeRecipient`; the caller receives `keeperOut = 2,020.8` USDC, a net 70.8 USDC on its funding of 1,950 USDC, and the debt is repaid in the same call (Source: Q-389, Q-404) |
| Result | Mitigated |
| Checks | TEST-286, TEST-173, FINDING-294 |

### ATTACK-197: Transfer fee on a debt asset breaks the flash path

| Field | Value |
|---|---|
| Target | LPVaultSwap caller funding and payouts, `IFlashSource` implementation, flash liquidation helper, a fee-capable debt asset (USDT) |
| Objective | Make every liquidation and every repay-with-collateral of a debt reserve revert, or book more than arrived, by switching on the debt asset's transfer fee |
| Affected steps | `LIQ` caller funding and payouts; `REP` repay with collateral (flash loan and its repayment) |
| Prerequisites | A debt reserve in a fee-capable token; issuer action: Tether sets `basisPointsRate > 0` |
| Attack approach | A 5,000 USDT transfer arrives as `5,000 × (1 − f)`; a contract that books the amount sent, or a flash source that forwards exactly 5,000 or checks `balance ≥ amount + premium` after LPVaultSwap returns `F + φ` net of the fee, reverts, so every liquidation or repay with collateral of that reserve fails |
| Impact | Bounded: new borrows of that reserve stop; every repayment of the asset (liquidation, repay, repay with collateral, pending settlement into it) reverts inside Aave V4 with `InsufficientTransferred` until the fee returns to 0, for Avana as for every Aave user of the asset; no Avana contract books more than arrived |
| Expected protection | `INV-095`, `INV-021`, `INV-081`: `enableDebtReserve` requires a transfer fee of 0 at listing; a non-zero transfer fee on a debt asset trips that reserve's debt breaker (`ISSUER`, read by the issuer probe `basisPointsRate()`), which stops new borrows; Aave V4's Hub requires its balance to cover every amount it books (`add`, `restore`, `reclaim`), so a fee-reduced repayment reverts inside Aave and nothing settles at a wrong amount (2.11 `REQ-SWAP-123`); Avana adds no path around that check, because a side path would bypass Aave's own accounting; keepers and monitoring alert, and liquidations resume in the next block after the fee returns to 0 (playbook P-20). The caller funding, the flash path of repay with collateral and every payout still measure received amounts by balance delta (2.11 `REQ-SWAP-108`, `REQ-SWAP-122`), as defence in depth against a token that delivers less than it was asked for. Example at `f` = 10 bps: `debtToCover = 1,950` USDT delivers `Kf = 1,948.05` USDT, which LPVaultSwap passes to Aave; the Hub receives 1,946.10195 USDT for the 1,948.05 it books and reverts `InsufficientTransferred(1,948,050)`; a helper-funded call reverts as a whole, so no loan or premium is owed (`REQ-HELPER-007`) (Source: Q-390, Q-401, Q-404) |
| Result | Mitigated: no wrong amount is ever booked; the wait for the issuer to remove the fee is an accepted external risk shared with every Aave V4 user of the asset, while the breaker stops new debt |
| Checks | TEST-287, TEST-221, TEST-048, PROP-097, FINDING-295 |
