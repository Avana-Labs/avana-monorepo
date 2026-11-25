# FirstLossReserve design record

This record sets out what Avana Labs decided the reserve covers, in what order, and how it holds its money. It states the thesis and the reasons, works each alternative through a $10,000 example, keeps the strongest objections Avana Labs considered with its answer to each, and gives the conclusion.

## Thesis

Bad debt on an Avana CDP Spoke is paid by Avana's capital first, then by the Aave DAO's, and only then left with Aave's suppliers. One contract serves both layers:

- **Avana's First-Loss Reserve.** Deployed with `firstLossLayer == 0`. Avana Labs funds it, and the Aave DAO controls it through its AccessManager.
- **The DAO Deficit Offset.** Deployed with the Avana reserve of the same `(Hub, asset)` as its constructor setting. The DAO treasury funds it.

### How it works

1. **What it covers.** It covers only a deficit the Hub has recorded for a CDP Spoke that the reserve allows, in the reserve's own asset. It never covers another asset, another Hub or another chain. It pays `min(cap, deficit, balance)`, so it never pays past the recorded deficit.
2. **In what order.** The offset reverts while the Avana layer is active on the Hub and holds any funds. If the DAO deactivates the Avana layer, that layer can no longer call `eliminateDeficit`, so the offset pays at once rather than leave a deficit waiting. A loss beyond both layers stays recorded on the Hub and is disclosed. Nothing writes it down across suppliers.
3. **How it holds the money.** It holds its money as Hub added shares, because that is the only thing Aave V4 lets an address burn to cancel a deficit (`Hub.eliminateDeficit` burns the caller's own added shares). The Hub lists the reserve's address with a draw cap of 0. It is not an Aave Spoke: it has no users, no reserves, no oracle and no liquidations. It holds no tokens between transactions.
4. **How money leaves.** It leaves only by coverage, or by a withdrawal through the withdraw role, whose AccessManager execution delay is 14 days (`WITHDRAWAL_DELAY`). A withdrawal reverts while an allowed Spoke has a recorded deficit: coverage comes first.
5. **What it does not do.** It does not absorb rounding gaps from liquidations. Those come out of the liquidator's payout (see the LiquidationModule record).

### Why a single contract

The old code had two contracts. The DAO offset inherited the First-Loss Reserve and overrode one hook. The only difference between the two layers is the order check, so here that check is a constructor setting.

Construction rejects a mismatched layer:

- a layer of another Hub, asset or asset ID;
- an offset placed behind another offset.

Either one could otherwise reorder who pays.

## The $10,000 example

A GHO line on one Hub:

| Layer | Funded |
|---|---|
| Avana's reserve | $4,000 |
| DAO offset | $5,000 |
| Lenders | $200,000 |

A crash empties an account that still owes $10,000 more than its collateral returned. The Hub records a $10,000 deficit on the CDP Spoke.

### Chosen design

- **Avana pays first.** The coverage caller calls Avana's `coverDeficit`, which pays $4,000 and leaves Avana's reserve at 0.
- **The offset pays the next $5,000.** The offset pays only the part of the deficit beyond what Avana's reserve holds: $10,000 − $4,000, capped at its $5,000. Called before Avana it pays the same $5,000 and leaves Avana's $4,000 share; while Avana's reserve covers the whole deficit it reverts `FirstLossLayerNotExhausted`. The order is kept by amount, not by Avana's balance reaching exactly 0, because `fund` is open: a one-wei deposit into an emptied Avana reserve would otherwise block the offset.
- **$1,000 stays recorded.** Lenders' shares still read $200,000. Once borrowers repay, the first $199,000 withdrawn is paid in full, and the last $1,000 of claims waits until a layer is topped up and the coverage caller covers the rest.
- **Withdrawals wait for coverage.** Until then, a withdrawal from either layer reverts with `DeficitOutstanding`.

### Alternatives

| Alternative | What happens to the $10,000 loss | Why it is rejected |
|---|---|---|
| Raw tokens held outside the Hub | Same order. Each cover must `add` the tokens to the Hub and then burn the shares in one call | `add` mints rounded down and `eliminateDeficit` burns rounded up, so a cover can fall one share short. The tokens also earn nothing, and the reserve must still be listed on the Hub to call either function |
| One pooled reserve across assets and Hubs | A $10,000 GHO loss could be paid from USDC capital | Aave V4 cannot burn one asset's shares for another asset's deficit. A pool would need swaps at the worst time, and it lets one asset's crisis drain another's cover. The ARFC promises per-pair coverage |
| Pro-rata between the layers (4:5) | Avana pays $4,000 × 4/9 = $1,778 and the DAO $2,222 of the first $4,000 | The DAO's money is spent while Avana's is still there. That is the opposite of "first loss", the promise that justifies the DAO lending to Avana's borrowers |
| The reserve absorbs liquidation rounding | Every small liquidation records a deficit of a few wei for the reserve to cover | Turns liquidator dust into recurring reserve spending and recurring withdrawal locks. The liquidator, who chose the size, carries it instead |
| No reserve; rely on Aave's Umbrella | Umbrella's stakers pay the $10,000 | Umbrella covers Aave's core reserves under its own sizing. Avana's risk would be socialised onto stakers who never priced LP collateral, which is exactly what the ARFC rules out |

## Objections considered

**The design.** The pair-scoped, ordered, share-holding design does three things:

- it matches the only coverage primitive Aave V4 has;
- it keeps Avana's capital in front;
- it holds the money where it earns the supply rate and can always be burned, whatever the Hub's utilization.

**The case against.**

- **Capital is fragmented.** Twelve `(Hub, asset)` buckets at $100,000 each lock $1.2M, against about $300,000 for one pool sized to the realistic worst case. A $150,000 loss in one bucket goes partly unpaid while $1.1M sits idle elsewhere. GHO and USDC are both dollar claims.
- **Wrong-way risk.** Holding the reserve in the Hub it insures means a Hub-wide loss or write-down shrinks the reserve exactly when it is needed. At full utilization the 14-day exit cannot be paid out either.
- **Griefing.** A $0.03 dust deficit that nobody covers freezes the whole reserve's withdrawals indefinitely, so the lock needs a threshold.
- **Governance risk.** Since the DAO controls Avana's capital, it could keep the first layer deactivated as leverage. Aave votes take 7–10 days while a deficit sits recorded.
- **First-come residual.** "First come, first served" on a residual is a bank-run rule.
- **Use Umbrella instead.** Umbrella already exists, and Avana could earmark a stake there.

Even the case against accepts that holding Hub shares is better than raw tokens for payout mechanics, and that never covering across chains is right.

**Why Avana Labs kept the design.**

- **Fragmentation.** It is the price of Aave V4's accounting. A deficit in one asset can only be burned with shares of that asset on that Hub, and a pooled reserve would have to swap into the right asset under stress, which is the moment swaps fail. The RiskModule's coverage ratio sizes each bucket to its own draw caps, so idle capital is bounded by what each line can actually lose.
- **Wrong-way risk.** Aave V4 has no supplier write-down: the objection's "suppliers written down 10%" cannot happen to the reserve's shares. A residual stays recorded and the share price does not fall. Utilization does not matter for coverage, because `eliminateDeficit` burns shares without moving liquidity.
- **Dust griefing.** The coverage caller holds a role with no delay and covers any recorded deficit, dust included, in one call. The ARFC commits to covering within 72 hours, so a dust deficit locks withdrawals for at most that long, not indefinitely. Liquidation rounding never reaches the Hub as a deficit, because the LiquidationModule takes it from the liquidator's payout.
- **Deactivation risk.** It is bounded the other way round: a deactivated Avana layer makes the DAO's own money pay first. So the DAO bears the cost of leaving Avana's layer switched off.
- **The first-come residual and Umbrella.** Both are disclosed in the ARFC as the DAO's choice for losses beyond both layers. Umbrella cannot earmark coverage for a single integration's Spoke without changing Umbrella.

**Two further proposals, both rejected.**

- **A dust threshold on the withdrawal lock.** Avana Labs decided not to add one: a withdrawal stays locked by any recorded deficit, dust included. The coverage caller clears a dust deficit in one call, the monitor warns on any Hub deficit and pages when one stays uncovered for 24 hours (M-15), and the ARFC commits to covering within 72 hours. A threshold would let a layer withdraw while a deficit is recorded, which breaks "coverage first".
- **A limit on how long the Avana layer may stay deactivated.** Avana Labs decided not to add one. While the Avana layer is inactive on the Hub, the offset no longer waits for it and pays first (`FirstLossReserve._frontBalance` reads an inactive layer as 0), so the DAO bears the cost of keeping Avana's layer switched off. The DAO controls both layers through its AccessManager, so a limit written into them would be one the DAO could lift.

Neither touches the loss order.

## Conclusion

The reserve covers only what Aave V4 records as a deficit, only for the Spokes and the asset it is set up for, and in a fixed order: Avana, then the DAO, then disclosure. It holds its money as Hub shares because that is the only form Aave V4 can burn to cancel a deficit. It is a plain contract listed on the Hub, not an Aave Spoke. Merging the two layers into one contract with a constructor setting removes the inheritance without changing either layer's behaviour. The 14-day withdrawal delay and the "coverage first" lock keep the money in front of the lenders.

## Invariants the tests check

`test/invariant/FirstLossReserve.invariant.t.sol`, `test/fuzz/FirstLossReserve.fuzz.t.sol`, on the local Aave V4 Hub:

- **Real deficits only.** The reserve never pays when no deficit is recorded, never pays past one, and never pays for a Spoke it does not allow.
- **Recorded deficit adds up.** The recorded deficit always equals the losses reported minus what was covered.
- **Loss order holds.** The offset never pays while the Avana layer is active on the Hub and holds funds.
- **Balances add up.** Both layers' balances equal what was funded minus what was covered, give or take share rounding.
