# LiquidationModule design record

This record covers two decisions: how an Avana position is liquidated, and how large Avana's cut of a liquidation is. It states the thesis and the reasons behind it, works each alternative through the same $10,000 example, keeps both sides of a two-agent debate, and gives the conclusion.

## The thesis

An Avana borrower's collateral is a set of concentrated-liquidity NFTs. Aave never sees those NFTs. It sees a vault token: one unit per unit of floor credit, where floor credit is a lower bound on what the position is worth at any price. When the health factor falls below 1, the module does four things in one transaction:

1. **Aave liquidates as usual.** The module calls the Spoke's standard `liquidationCall`. Aave decides how much debt to repay (toward the target health factor) and what bonus to pay (its dynamic bonus).
2. **The seized vault tokens are burned.** The vault token's path rule lets seized units go only to this module, so a direct `liquidationCall` from any other address reverts.
3. **Only liquidity worth the seized units is unwound.** The value is measured at the market's LPOracle prices. The order is set by excess per unit of credit, lowest first: band-wide positions (no excess) go first and narrow positions go last. The borrower keeps the rest of every NFT and all of its fees.
4. **The payout is in kind.** Both pool tokens go to the liquidator. Avana's share of the bonus, 20%, goes to the fee recipient in the same two tokens, split in the same proportion. Avana swaps nothing.

The module works the same way for both markets of a pool. In the Full range market every position spans the band, so the credit removed equals the units seized. In the Custom range market narrower positions are worth more than their credit, so the unwind removes less credit than units, and only as much liquidity as the seized value needs.

**Why least excess first.** The value removed is the same whatever the order: it always equals the seized units at oracle prices. Two things do change with the order.

- **Credit and supply stay matched.** A band-wide position loses exactly as much credit as Aave loses supply, so the account's credit and its Aave supply move together. Unwinding a narrow position first would strand credit with no supply behind it.
- **Less exposure to a moved pool price.** The tokens a narrow position holds are the most sensitive to the pool price straying from the oracle, so unwinding it last keeps the liquidation's exposure to a manipulated pool price as small as the account allows.

**Why the value is measured at the oracle price.** The tokens are paid out at the pool price, but the liquidity removed is sized at the oracle price. A concentrated position's holdings are worth the least at an external price when the pool sits at that same price. So whenever the pool price differs from the oracle, the tokens the liquidator receives are worth *at least* the seized units at the oracle price, and the liquidator is never short. Rounding works the same way: the credit to unwind is rounded down. Under the ARFC, a rounding gap comes out of the liquidator's payout, never out of the borrower or the reserve. One exception: when Aave empties an account, every remaining unit of its credit is unwound, so no dust stays pledged.

## Decision 1: partial in kind vs whole NFT vs swap to the debt token

### The $10,000 example

Alice has two NFTs in a USDC/USDT Custom range market:

- **A** spans the band: $6,000, credit worth $6,000.
- **B** is a narrow ±0.1% position: $4,000, credit worth $3,600.

Her vault tokens are worth $9,600, the LTV is 80%, and she owes $7,700. A small move takes her health factor to 0.997. Aave's bonus there is 2%. Aave repays $1,000 of debt toward the target and seizes $1,020 of vault tokens.

### (a) Partial in kind (chosen)

$1,020 of liquidity is unwound, all of it from A. B is not touched. The liquidator receives about 510 USDC and 510 USDT. Avana's 20% of the $20 bonus is $4, paid as 2 USDC and 2 USDT, so the liquidator nets $1,016 of tokens for $1,000 repaid.

Afterwards Alice holds A at $4,980 plus all of B ($4,000), with $8,580 of credit against $6,700 of debt. Her health factor rises to about 1.024: Aave's sizing aims for the target of 1.10, and this mock round is smaller than a full one. She lost $1,020: exactly the seized value, and nothing more.

### (b) Seize a whole NFT

Aave seizes $1,020 of vault tokens, but an NFT cannot be split by transfer, so the liquidator would take a whole one.

- If it takes A ($6,000), Alice loses $4,980 more than Aave seized. The protocol must then either refund her the difference, which means valuing and paying out the NFT on-chain, or let the liquidator keep it. Keeping it turns a 2% bonus into a 490% one.
- If it takes B, the same happens at $4,000.

Either way the "rest" has to be settled in some asset, and that brings back the very valuation and payout machinery that in-kind unwinding removes. The liquidator also receives an AMM position, not two tokens. That is harder to price and to hedge, and impossible to sell in the same transaction without unwinding it anyway.

### (c) Unwind, then swap to the debt token inside the protocol

This was the previous design (LPVaultSwap, settlement routes, payout escrow and pending settlement: about 3,000 lines). The module would unwind $1,020 and sell the USDC and USDT for GHO through a route Avana maintains, then pay the liquidator about $1,016 of GHO.

- The swap's price impact and MEV become the protocol's problem. On a long-tail pool a 1% sandwich on $1,020 costs $10, half the bonus, and the code needs slippage limits, route allowlists, a pending state for failed swaps and an escrow for the leftovers.
- Every one of those parts can block a liquidation. A paused route, a router upgrade or a depegged hop means the account cannot be liquidated at all.
- Liquidators already sell tokens every day on routes they choose and maintain. Avana would be rebuilding that, with less information and in front of an audit.

### Debate

**Proposer (in kind).** In-kind partial liquidation is the only form in which the liquidator gets exactly what Aave seized and the borrower loses exactly that. It needs no price from Avana beyond the oracle Aave already uses. It adds no route, escrow or pending state that could block a liquidation. The module is about 300 lines against the old 3,000.

**Opponent.** "Nothing swapped on-chain" is false in practice. A flash-borrowing liquidator still swaps in the same transaction, so the routing cost and risk move to the liquidator, and the liquidator now sells two tokens instead of one. The opponent's numbers on a $10,000 volatile ETH/long-tail position at a 2% bonus:

| Item | Amount |
|---|---|
| Gross margin | $156.80 |
| Gas for the liquidation and a 2–3 NFT unwind (about 1M gas at 30 gwei) | $90 |
| Selling the long-tail half | about $55 |
| Net to the liquidator | about $4 |

The opponent's other points:

- One more NFT, or a gas spike, makes the liquidation unprofitable.
- Pushing a ±1% pool by 1% before the unwind takes about 0.5% of the unwound value.
- Liquidators who set minimums to protect against that will see their liquidations revert in exactly the volatile blocks.
- In a crash, $250k of a long-tail token dumped into $200k of depth makes each later liquidation worse.
- Small positions are the worst case: a $1,500 debt pays $30 of bonus, $24 net of Avana's cut, against more than $40 of gas, so it becomes a deficit.

The opponent concedes that partial liquidation is better for borrowers than seizing a whole NFT, and that it beats the in-protocol swap on audit surface.

**Proposer's reply.**

- **Gas and long-tail tokens.** These are real costs, but none of them is created by the in-kind form; it only makes them visible. A protocol swap pays the same gas and the same price impact, and adds its own.
- **Unprofitable liquidations.** The ARFC makes Avana's bot a committed operator that liquidates every account below 1 whether or not it is profitable, with gas paid by Avana. Profit-seeking liquidators are a second line, not the only one.
- **Draw caps and token depth.** Draw caps are sized to each pool token's market depth, which limits the crash dump the opponent describes.
- **Narrow positions and pool manipulation.** Least-excess-first unwinds the narrowest positions last, so they are the least often exposed to a moved pool. Because the liquidity is sized at the oracle price, a moved pool never shortens the liquidator's payout; it only shifts which tokens the liquidator receives.
- **Small debts.** The open point is real. Avana's own bot covers them, and the RiskModule has no minimum-debt rule today. A minimum position size is a listing parameter the DAO can add without changing this module.

**Open point carried forward.** A minimum debt or full-close threshold for small accounts belongs in the RiskModule's listing rules if live data shows such accounts left unliquidated.

## Decision 2: the fee size

### The $10,000 example

The ARFC example: 4,998 vault tokens ($9,996) are seized at a 2% bonus for $9,800 of repaid GHO. The bonus inside is $196.

| Fee rule | Avana gets | Liquidator nets | Liquidator's minimum bonus for C = $150 of costs |
|---|---|---|---|
| 0% | $0 | $196 | 1.50% |
| **20% of the bonus (chosen)** | **$39.20** | **$156.80** | **1.88%** |
| 50% of the bonus | $98 | $98 | 3.00% |
| 10 bps of the repaid debt | $9.80 | $186.20 | 1.60%, but charged even at a zero bonus |
| A share of interest | depends on time, not on liquidations | $196 | 1.50% |

The fee is computed from Aave's own bonus at the health factor before the call: `seized · (bonus − 1) / bonus · 20%`. In the ARFC example that is 19.6 vault-token units ($39.20). It is paid as the same fraction of both unwound tokens.

### Why 20% of the bonus

- **Paid only when there is a bonus.** A fee taken from the bonus never makes a liquidation cost the liquidator more than the debt it repays.
- **Scales with the liquidation, not with the loan.** Unlike a flat bps of repaid debt, it is charged only in proportion to the liquidation that actually happens.
- **Leaves interest alone.** A share of interest would change the Aave DAO's revenue, which the ARFC promises not to touch.
- **Still clears early liquidations.** At 20% the liquidator keeps 80% of every bonus, so a 2% bonus still covers the costs of the committed operator's typical liquidation. At 50%, early liquidations at a 2% bonus would wait for a deeper bonus.
- **Paid in kind.** Collecting the fee in the pool's tokens needs no swap and no oracle beyond the one Aave used.

### Debate

**Opponent.**

- **It delays liquidations.** With C as the liquidator's cost, a liquidation clears only when 0.8 · b · V > C. The fee therefore raises the bonus a liquidator waits for from C/V to C/(0.8V). For a $10,000 position with $180 of costs, that is 2.25% instead of 1.8%.
- **It deepens losses.** Since the bonus is a Dutch auction, the fee moves liquidations to a lower health factor and deeper losses. Every position whose costs fall between $156.80 and $196 is liquidated without the fee and left alone with it.
- **Borrowers pay for it.** Risk stewards may raise the bonus by about 25% to compensate, and that cost lands on borrowers.
- **Collecting in kind is costly.** Two extra transfers cost about $5 to collect $39.20, and the recipient builds up long-tail tokens to sell later.
- **Counter-proposal:** no fee below a 3% bonus, and 20% only of the bonus above 3%.

**Proposer's reply.**

- **Profit-seeking liquidators are not the first line.** The committed operator liquidates regardless of margin, so the cost band the opponent names is covered by an operator that does not price the fee.
- **The fee is capped in the code.** The RiskModule caps the share at `MAX_FEE_SHARE_BPS`, and the timelocked governance can lower it, or set the recipient to zero, which switches the fee off in this module. No code change is needed.
- **The counter-proposal changes the economics.** A threshold-based fee would make Avana's revenue zero in exactly the orderly liquidations the ARFC treats as the normal case. That is a change to the ARFC's economics, not to this module, and can be adopted later through the same setter if the data supports it.
- **The two extra transfers are dust-checked.** Zero amounts are skipped, so a liquidation with a tiny fee pays no transfer.

**Conclusion.** The 20% share stands as the ARFC sets it. The setter and the zero-recipient switch are the safety valves.

## Conclusion

Partial in kind is the only form in which the borrower loses exactly what Aave seized and the liquidator gets at least that much. It is also the only one in which Avana owns no swap path that could block a liquidation. Least-excess-first keeps credit and supply in step and keeps narrow positions out of the riskiest unwinds. Avana's fee is 20% of Aave's own bonus, paid in kind, and governance can turn it down or off.

## Invariants the tests check

`test/invariant/LiquidationModule.invariant.t.sol`, `test/fuzz/LiquidationModule.fuzz.t.sol`:

- **Health never falls.** No liquidation leaves an account less healthy, unless Aave closed it out into a deficit.
- **No value leaks.** All liquidity that leaves a position reaches the liquidator or the fee recipient, and the module keeps no token.
- **Credit loss stays within the seized units.** The credit an account loses is at most the units seized, plus two units of rounding per position. An emptied account keeps no credit.
- **The fee stays within its share.** The fee is at most the 20% share of the bonus, split in the same proportion of both tokens.
- **Every vault token stays backed.** Each vault token's supply stays within its market's credit, plus rounding.
