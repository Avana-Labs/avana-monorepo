# AaveAdapter: design record

**Status: proposed in refactor step 5 (2026-11-19).** This record argues two decisions: how a user's Aave account is held (thin proxies as position managers) and how a pledge picks its market (automatic routing). Each part gives the thesis, the reasoning, every alternative with a worked $10,000 example, a debate between two agents with both sides kept, and the conclusion. The credit math is argued in the [LP-vault credit record](../../custody/lp-vault/DESIGN.md), the two markets per pool in the [RiskModule record](../risk-module/DESIGN.md).

**How to read the numbers.** Every example is a $10,000 position on Base ETH/USDC 0.05% (tick spacing 10, $1,803.33 on the listing day), the same pool and day as the RiskModule record. Both markets carry a 75% LTV. The Custom range band is the Volatile default, 0.345× to 2.898× of the listing price. A cell shows borrowing power: credit value × LTV.

| $10,000 position (Uniswap preset) | Market it routes to | Borrowing power |
|---|---|---|
| Full range | Full range | $7,500 |
| Wide (−50% / +100%) | Custom range | $6,700 |
| Stable (±0.3%) | Custom range | $5,555 |
| One-sided, 50% below the price | Custom range | $5,550 |
| 0.30× – 1.0× (lower edge outside the band) | rejected | $0 |

## Thesis

1. **One thin account per wallet and market.** The adapter deploys an `AccountProxy` with CREATE2 the first time a wallet pledges into a market. The proxy is the Aave user. Its constructor approves the adapter as its Aave position manager, and it has no functions after that: no `execute`, no owner calls, no tokens. The adapter calls the Spoke's `supply`, `withdraw`, `borrow`, `repay` and `setUsingAsCollateral` on the proxy's behalf, the way Aave V4 intends position managers to work.
2. **Automatic routing.** A pledge names only the NFT. A full-range position goes to the pool's Full range market. Any other position goes to the Custom range market if it lies fully inside that band. Anything else reverts `NoMarketFits`, and the app suggests Full range. Users never see or pick a market.

## Reasoning

| Constraint | Consequence |
|---|---|
| Aave V4 has position managers: a user approves a contract, and the Spoke lets it supply, withdraw, borrow and repay for that user | The adapter needs no call-forwarding proxy. An approval in the proxy's constructor is all the proxy has to do. |
| Aave checks the health factor on every `withdraw` and `borrow` | The adapter needs no health logic of its own. It withdraws the supply above the account's remaining credit, and Aave refuses the call if the account would be unhealthy, which reverts the NFT release in the same call. |
| The vault token moves only between the Hub and a registered address | The adapter registers itself as the token's only valid proxy, mints to itself and supplies in the same call. Vault tokens never sit in a user's account, so no account can move them. |
| A user must not lose a $10,000 NFT because a narrower one next to it was liquidated, and a liquidator must know exactly which NFTs back which debt | One account per market isolates each market's collateral and debt (debated below). |
| Plan limits: the AaveAdapter and RiskModule together at most 1,500 code lines | The adapter is 286 code lines (interface 69, contract 198, storage 4, proxy 15). With the RiskModule's 726 the policy part is 1,012. |
| Every market a user can pick is a decision the user can get wrong | The rule is fixed and the NFT's ticks decide it; the app explains it with Uniswap's own words. |

Two details follow from the table:
- **Supply never exceeds credit.** After any credit decrease the adapter reads the account's remaining credit from the LPVault and its supply from the Spoke, and withdraws only the difference. Share rounding in the Hub can leave the supply a few units below credit; it never leaves it above. If a liquidation has already taken the supply below the remaining credit, nothing is withdrawn: every supplied token is still backed by the NFTs that stay.
- **Batching without new code.** `multicall` (OpenZeppelin) runs several calls in one transaction with the caller kept as `msg.sender`, so pledging five NFTs or "pledge and borrow" is one signature.

## Decision 1: thin proxies as position managers

### Alternatives

**A. One `AccountProxy` per (wallet, market), the adapter as its position manager (chosen).**
Alice pledges a $10,000 Full range NFT. The adapter deploys her Full range account (a CREATE2 contract of 15 code lines; about 100,000 gas, under $0.01 on Base), the account approves the adapter, the LPVault takes the NFT and records credit, and the adapter mints the credit to itself and supplies it for the account. Alice borrows $5,000 USDC: `checkBorrow` passes, the Spoke draws to the adapter, the adapter sends it to Alice. Health factor 7,500 / 5,000 = 1.50. She withdraws the NFT later with debt still open: the LPVault releases it, the adapter withdraws the whole supply, and Aave reverts the call because the account would hold $5,000 debt against $0. The NFT never leaves.

**B. Keep ProxyManager and PositionProxy with `execute()` (the previous design).**
The same $10,000 pledge works, but every step is a call the adapter encodes and the proxy forwards: mint to the proxy, `approve`, `supply`, `setUsingAsCollateral`, each through `execute(target, data)`. The previous adapter was 1,442 code lines (a router and four delegatecall logic contracts) plus 159 lines of proxy and manager, against 286 now. A forwarding proxy is a general tool: one wrong target or calldata in any step could make Alice's proxy call the vault token or the Spoke in a way nobody reviewed. It also needed a deadline, a borrow nonce, a pause state and step checks that Aave's position-manager model makes unnecessary. Rejected: five times the code for no capability the position manager lacks.

**C. The adapter as one pooled Aave user, with per-user records inside Avana.**
Alice's $10,000 and Bob's $10,000 Full range NFTs back one Aave account with $15,000 of borrowing power. Alice borrows $5,000 and Bob $7,000: Aave sees health factor 15,000 / 12,000 = 1.25 and liquidates no one. But Bob alone is at 7,500 / 7,000 = 1.07, and a 10% ETH drop would put him under while the pooled account still looks healthy, so Avana would need its own health factor, its own liquidation and its own interest accounting per user. That is Aave rebuilt inside Avana. Rejected.

**D. The wallet itself as the Aave user, approving the adapter.**
Alice signs `setUserPositionManager(adapter)` on the Spoke once, then pledges. It saves the proxy deployment (about 100,000 gas once per market) and one address per market in the app. But one Aave user per Spoke means her Full and Custom range positions share one health factor (the cross-margin case under E), the approval is an extra transaction or signature before the first pledge, and she can revoke it at any time, after which the adapter cannot withdraw her supply or repay through the usual path. Rejected for the isolation reason under E, and because the account would no longer be something Avana controls end to end.

**E. One proxy per (wallet, Spoke) instead of per (wallet, market).**
Both markets of a pool are reserves of one Spoke, so one proxy per Spoke would put Alice's Full range and Custom range NFTs in one account with one health factor. Worked through in the debate below: cross-margin raises Alice's headroom by pooling, and it also lets a liquidation of her narrow NFT's market reach her full-range collateral, the bonus paid on whichever reserve the liquidator picks. Rejected by the plan's locked choice of one account per market; the debate records the trade.

### Debate

Two agents argued this decision. The proposer wrote the thesis above; the opponent was asked to argue against it as hard as it honestly could. Both sides are kept. Assumptions for the debate: liquidation threshold 80%, liquidation bonus 5%, credit valued at its floor.

**Opponent, point 1: isolation per market liquidates a user who is solvent overall (for E).** Alice holds a $10,000 Full range NFT (credit $10,000) and a $10,000 Stable ±0.3% NFT (credit $7,407) on one Spoke. In her Custom range account she borrows 2.9 WETH ($5,230): HF = 7,407 × 0.8 / 5,230 = 1.13. In her Full range account she borrows $2,000 USDC: HF = 4.0, with $5,500 of headroom unused. ETH rises 15%, her WETH debt becomes $6,015, and the Custom HF falls to 0.985. A 50% close costs her $150 of bonus; a full close $300. Under E the same moment reads collateral 17,407 × 0.8 = 13,926 against debt 8,015, HF 1.74, and nothing is liquidated. Both markets have the same LTV on the same Spoke, so isolation buys protection users never asked for.

**Proposer's reply.** The numbers are right, and the trade is real. Three things narrow it. First, the headroom is reachable in one transaction: `multicall([borrow(Full, USDC, 3,000, Alice), repay(Custom, ...)])` moves $3,000 of Full range headroom onto the Custom debt (repaying WETH needs a swap in between, which the app routes), and Aave checks each account as it goes. Second, isolation is what keeps a liquidation simple and bounded: a liquidator of the Custom account takes Custom vault tokens, and the LiquidationModule unwinds only NFTs of that market, the narrow ones that caused the shortfall. Under E, with Alice at HF just below 1 across both, the liquidator picks which reserve to seize, and the unwind may cut into her full-range NFT that was never at risk. Third, one account per market is the plan's locked choice (one NFT market, one Aave account, one place to look when explaining a liquidation), and the risk providers price each reserve on its own.

**Opponent, point 2: gas and reads.** Each account costs about 100,000–120,000 gas: under $0.01 on Base, about $4 per market on an L1 at 20 gwei. A user in ten pools has twenty accounts to read, keepers and alert bots twice as many as under E.
**Proposer's reply.** Accounts deploy lazily on the first pledge into a market, so a user has only the accounts they use. The indexer records `AccountCreated`, and `predictAccount` gives every address without a call. The L1 cost is noted; the first deployments are on L2s.

**Opponent, point 3: a proxy with no functions cannot be rescued.** It can never revoke or re-point its position manager. If the adapter has a bug, or a Spoke upgrade adds a new consent step, the accounts cannot move; and if the adapter were upgradeable, all trust would sit in its upgrade key.
**Proposer's reply.** The adapter is not upgradeable and has no admin: the record accepts it as the permanent operator of every account, which is the point of having no `execute`. Migration to a new adapter means each user repays and withdraws through this one and pledges through the next; their NFTs stay theirs throughout. A delayed `approveSuccessor` in the proxy would add an owner path, a registry and a delay to every account to cover a migration that withdraw-and-repledge already covers.

**Opponent concedes:** B (execute and ProxyManager) should stay rejected; C (pooled user) and D (wallet as the Aave user) are worse than either proxy design; gas does not matter on Base.
**Opponent holds:** E over per-market accounts while both bands share one LTV; if isolation stays, a one-transaction way to use sibling headroom and a warning when one account is low while its sibling has room; an explicit statement that the adapter is the permanent operator.

### Conclusion

One `AccountProxy` per (wallet, market), with the adapter as its permanent position manager. The opponent's cross-margin case is recorded as the cost of isolation: in that example it is $150–$300 for a user who did not rebalance. The contract already answers it with `multicall`, which rebalances across a wallet's accounts in one transaction; the webapp (step 11) adds a warning when one account's health is low while a sibling account has headroom. The adapter is immutable and has no admin, and this record states that it is the permanent operator of every account; moving to a new adapter is withdraw and re-pledge. If the risk providers later price both bands as one collateral, option E is the change to make, at the cost of the simple per-market liquidation.

## Decision 2: automatic routing

### Alternatives

**A. Full range to Full range, inside the band to Custom range, else reject (chosen).**
Each row of the table at the top is what Alice gets: $7,500, $6,700, $5,555, $5,550, or a clear error for the 0.30×–1.0× NFT, with the app offering to mint Full range instead.

**B. The user picks the market.**
Alice could send her Stable ±0.3% NFT to the Full range market. It is inside that band too, so the LPVault accepts it, but its floor credit there is a sliver of a full-range unit: borrowing power about $0 instead of $5,555. Every wrong pick is a support case and every right pick is the one automatic routing makes anyway, because whenever an NFT fits both, the narrower band always credits more. Rejected.

**C. Send a position outside the Custom band to the Full range market.**
Alice's 0.30×–1.0× NFT would be accepted with borrowing power about $0 (floor credit of a narrow range against a band from tick −887,270 to 887,270). The pledge "succeeds", the NFT is locked, and she can borrow nothing; she has to withdraw again and pay gas twice. A revert with a reason is the better answer. Rejected.

**D. Route to whichever market gives the most credit.**
For every NFT this picks the same market as rule A: a full-range NFT fits only Full range, and an NFT inside the Custom band always earns more there. It costs two credit previews per pledge for no different outcome. Rejected as equivalent but more expensive; rule A is the closed form of it.

### Debate

**Opponent: hard rejection is right, the message is wrong.** A $10,000 0.30×–1.0× NFT (a "buy ETH as it falls" ladder from about $541 to $1,803) misses the band's lower edge, 0.345× ($622), by $81 and is rejected. Telling the user to "use Full range" is misleading: in the Full range market the same NFT earns about $0. B, C and D give this user nothing either, so the opponent concedes the rejection. What it objects to is that the message sends users to a market that pays nothing, and that routing decides which health factor a debt lands in without showing it.
**Proposer's reply.** Agreed on both. The suggestion "Full range" means minting a full-range position, not sending this NFT there; the error carries the pool and both ticks so the app can say exactly which edge is missed ("lower tick 0.300× is below the band at 0.345×") and quote the borrowing power after re-minting at the edge (about $6,000). Before the user confirms, the app shows the market, the account and the health factor after the pledge. Routing stays automatic; there is no market picker.

**Opponent concedes:** rejecting positions outside the band; no user-picked market. **Opponent holds:** the rejection message must not point at a market that pays under 5% of the position, and the destination must be shown before confirmation.

### Conclusion

Automatic routing with a hard rejection, unchanged in the contract. The debate changed the app's wording, not the rule: `NoMarketFits` carries the ticks so the app names the missed edge and the credit after re-minting, the "Full range" suggestion means minting a new full-range position, and the webapp (step 11) shows the market, account and health factor before the user confirms.

## Open items for later steps

- **Roles and wiring (step 9).** The AccessManager grants the adapter the LPVault's `pledge`, `addLiquidity`, `removeLiquidity`, `release` and `collectFees`, and each vault token's `mint`, `burn` and `addValidProxy`. Each CDP Spoke's configurator activates the adapter as a position manager.
- **Repay with collateral (step 8).** `FlashloanRepay` can repay through `repay` for any wallet; withdrawing for the user needs the user's own call, so step 8 adds an operator rule or keeps the withdraw in the user's hands.
- **Webapp (step 11).** The pledge preview shows market, account and health factor after the pledge; a rejection names the missed band edge; a warning fires when one account is low while a sibling has headroom.
- **Liquidation (step 6).** The LiquidationModule liquidates the account directly on the Spoke and unwinds the NFTs in the LPVault; the account and the adapter take no part.
