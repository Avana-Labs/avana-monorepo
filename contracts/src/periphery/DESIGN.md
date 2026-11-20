# Repay with collateral: design record

**Status: proposed in refactor step 8 (2026-11-19).** This record answers one question: can a user repay debt with part of the LP position they pledged, instead of bringing the debt token? It gives the thesis, the reasoning, every alternative with a worked $10,000 example, a debate between two agents with both sides kept, and the conclusion. The adapter it relies on is argued in the [AaveAdapter record](../adapter/DESIGN.md), and liquidation in the [LiquidationModule record](../liquidation/DESIGN.md).

**How to read the numbers.** Every example uses Base, the Uniswap v3 WETH/USDC 0.05% pool (`0xd0b5…F224`). On-chain reads at Base block 59,598,223: ETH at $1,776, in-range liquidity 1.07 × 10¹⁹, and an Aave V3 Pool flash premium of 5 bps (`FLASHLOAN_PREMIUM_TOTAL`). At that depth, selling $3,000 of ETH moves the price by about 0.001%, so the 0.05% pool fee is almost all of the swap cost. The risk settings are illustrative: a 75% liquidation threshold, a 5% maximum liquidation bonus, a target health factor of 1.10 (the ARFC's recommendation), and Avana's 20% share of the bonus. The 10 bps app fee applies only when the action goes through the Avana app. Gas on Base is a few cents and is rounded to $0.05.

**The account in every example.** The position is a $10,000 Full range position: 2.815 ETH and 5,000 USDC at $1,776. The debt is 6,500 USDC, so the health factor is 0.75 × 10,000 / 6,500 = **1.154**. Then ETH falls 20% to $1,420.80. A full-range position's value moves with the square root of the price, so the position is now worth $8,944, made up of 3.148 ETH and 4,472 USDC, and the health factor is **1.032**. The account becomes liquidatable at ETH $1,334.

## Thesis

**Ship repay with collateral, partial and full, in one entry point.** The wallet calls `AaveAdapter.allowWithdraw(FlashloanRepay, positionKey, liquidity, params)`. The helper then:

1. flash-borrows the debt asset from the Aave V3 Pool;
2. repays through the adapter's open `repay`;
3. withdraws `liquidity` of the position as the operator of that one call;
4. runs the wallet's swaps into the debt asset;
5. repays the loan and its premium;
6. sends everything left (the debt asset and both pool tokens) to the wallet.

`amount` is the debt to repay, and `type(uint256).max` repays all of it, so "full" is "partial" with the largest amount, not a second code path.

The core gains no standing approval. `allowWithdraw` opens an allowance that:

- lasts one call;
- covers one position, part of it only, never the whole NFT;
- caps the liquidity at `maxLiquidity`;
- reverts unless the account's health factor ends **at least where it started**.

## Reasoning

| Constraint | Consequence |
|---|---|
| `AaveAdapter.withdraw` accepts only the wallet that pledged; there is no operator path (step 5) | A helper cannot withdraw for a user without a core change. The smallest change that does not create standing rights is a transient, callback-scoped allowance. |
| Near liquidation, a user cannot withdraw first: Aave's health check refuses it | The debt must be repaid before the withdrawal, and that money has to come from somewhere for one transaction: a flash loan. |
| The Avana core is audited and size-limited; the periphery is not counted | The helper lives in `src/periphery`, outside the count. The adapter grows by its allowance only. The policy part is 1,082 of 1,500 lines. |
| Users who need this are often in a falling market and have no spare stablecoins | Without the feature, their options are outside cash or liquidation (alternative A). |
| Swaps need a route, and good routes change by the block | The wallet (the app) brings its route as calls. The helper approves each target for one call, then resets the approval to zero, and refuses the adapter, the LPVault and the Pool as targets. |
| A helper that holds funds or approvals between transactions is a target | The helper holds nothing between calls and takes no recipient. Leftovers always go to the wallet. |

**What the health factor rule bounds.** Repaying `x` and withdrawing liquidity worth borrowing power `w` leaves the health factor no lower only when `w ≤ HF_before × x`. With HF 1.032 and a 75% threshold, repaying $2,426 allows at most $3,338 of position value to come out, which leaves a 37% margin for swap costs and quote drift. Anything beyond that would be a withdrawal dressed up as a repayment, and the adapter refuses it. A full repayment ends at the largest health factor, so it is never limited.

## Alternatives, with the $10,000 account

### A. No repay with collateral (status quo)

The user has two ways out.

**A1. Wait, and be liquidated if the price keeps falling.** At ETH $1,320 the health factor is 0.995. Aave sizes the repayment to reach 1.10. Solving 0.75 × (8,621 − 1.05x) = 1.10 × (6,500 − x) gives x = $2,189 repaid.

| Item | Amount |
|---|---|
| Liquidation bonus paid out of the position (5%) | **$109.46** |
| — to the liquidator | $87.57 |
| — to Avana (20%) | $21.89 |
| After: collateral / debt / health factor | $6,322 / $4,311 / 1.10 |

**A2. Withdraw, swap, repay in a loop, with no flash loan** (an EIP-5792 batch of three calls). Each withdrawal must leave the health factor at 1 or above. The first loop can free $8,944 − 6,500 / 0.75 = $278. Each later loop frees one third of the previous one, because repaying $1 frees $1.33 of required collateral while removing $1 of collateral. In total, about **$416** of debt can ever be repaid this way, at a health factor of exactly 1, with one swap per loop. Reaching a safe level is impossible without outside cash.

*Cost:* nothing to build. *Risk:* a user without spare stablecoins pays about 25× more in a liquidation than a deleverage would have cost.

### B. Full repayment only

At $1,420.80, the helper:

1. flash-borrows 6,500 USDC;
2. repays the whole debt;
3. withdraws $6,520 of the position (3,260 USDC and 2.2945 ETH; a 0.25% buffer over the $6,503.25 owed);
4. sells the ETH.

| Item | Amount |
|---|---|
| Flash premium, 5 bps of 6,500 | $3.25 |
| Pool fee, 0.05% of $3,260 | $1.63 |
| Price impact (2.29 ETH on 1.07 × 10¹⁹ in-range liquidity) | $0.03 |
| Gas | $0.05 |
| App fee, 10 bps (app only) | $6.50 |
| **Total** | **$11.46** |
| Left to the wallet | 15.09 USDC and the remaining $2,424 position, free of debt |

The cost is the exposure. The user sells 2.29 ETH at the dip, and if ETH returns to $1,776, that sale has given up about $815. Full repayment also closes the loan even when the user only wanted to be safe.

### C. Partial and full in one entry point (chosen)

At $1,420.80, the user repays to a health factor of 1.20. Solving 0.75 × (8,944 − x) = 1.20 × (6,500 − x) gives x ≈ $2,426. The helper withdraws $2,433 (1,216.5 USDC and 0.8562 ETH) and sells the ETH.

| Item | Amount |
|---|---|
| Flash premium, 5 bps of 2,426 | $1.21 |
| Pool fee, 0.05% of $1,216.5 | $0.61 |
| Price impact | $0.01 |
| Gas | $0.05 |
| App fee, 10 bps | $2.43 |
| **Total** | **$4.31** |
| After: collateral / debt / health factor | $6,511 / $4,074 / **1.199** |
| New liquidation price | ETH **$989** (−30% from here, instead of −6%) |
| ETH exposure kept | 2.29 of 3.15 ETH (73%) |
| Exposure given up if ETH returns to $1,776 | about $304 |

The same entry point with `amount = type(uint256).max` is alternative B. The helper sizes the loan to the debt at execution, so interest that accrues between the quote and the block does not leave dust.

| | A1 liquidated at $1,320 | A2 loops | B full | C partial to HF 1.20 |
|---|---:|---:|---:|---:|
| Cost to the user | $109.46 | swap fees, many transactions | $11.46 | **$4.31** |
| Debt repaid | $2,189 (forced) | ≤ $416 | $6,500 | $2,426 (chosen) |
| Health factor after | 1.10 | ≈ 1.0 | no debt | 1.20 |
| ETH sold | $2,299 of position seized | small | 2.29 ETH | 0.86 ETH |
| Core change | none | none | allowance | allowance (same) |

## Debate

Two agents argued the decision. The opponent's case is kept in full substance; the proponent's answers follow each point. Where the opponent won, the design changed.

### Opponent: ship A now, revisit B before C

1. **The cost lands on the audited core.** The feature is called periphery, but it works only if the non-upgradeable adapter gains `setOperator`. Today one short, audited rule protects every pledged position: only the pledging wallet can withdraw. An operator rule turns that into "the wallet, or any contract it once approved, for as long as the approval stands". Once the debt is repaid, the health check no longer limits anything, so the operator could take the whole $8,944.
2. **A standing approval to a contract that runs user calldata.** EIP-5792 batching is not in every wallet. The fallback is three transactions, and a user who abandons the third keeps a live approval. A helper bug lets a crafted route call `adapter.withdraw` for every wallet with an approval outstanding. And `setOperator` on an official Avana contract is a new phishing target: one signature gives a fake front end full withdraw rights.
3. **The swap happens at the worst time.** People use the feature in a crash. Aave values collateral at Chainlink while the swap fills at the pool, and in-range liquidity thins out as LPs pull. "0.05% + 0.001%" is a calm-market snapshot. Base has no public mempool, but ordering, backruns and stale quotes remain. For a partial repayment, a user with outside USDC can just call `repay`: no swap, no premium, no approval.
4. **Liquidation is already a cheap, partial exit, and the numbers miss the regret.** Partial deleverage costs $4.31 against $109.46 for liquidation, which is clearly cheaper. But liquidation happens only if the price reaches $1,320, while deleveraging bets at $1,420.80 that it will. Full repayment sells 2.29 ETH at the dip, about $815 of upside if ETH recovers, roughly 70 times the fee the thesis highlights.
5. **Partial deleverage confuses users.** "I repaid but I still have debt." "Why did my position come back as only ETH?" (out-of-range withdrawals are one-sided). "Why is my HF lower than the preview?" Full repayment has one meaning.
6. **Scope.** The core needs a re-audit and Certora rules for the operator path. The helper needs its own review (flash callback, router calls, leftovers, partial arithmetic). Every router upgrade is maintenance.
7. **Conditions to accept C:**
    - no standing approval: one-transaction scope through transient storage or a permit with deadline, nonce, position key and maximum liquidity;
    - one operator fixed at deployment;
    - the core checks the outcome (debt down, health factor not lower);
    - routers from an allowlist, and `minOut` on chain within 1% of the oracle;
    - leftovers only to the wallet, with no `recipient`;
    - a separate audit, Certora rules, and B before C.

### Proponent: C, with the opponent's safeguards where they hold

1. **Standing approval: conceded, and the design changed.** The first draft had `setOperator`. It is gone. `allowWithdraw` writes the allowance to transient storage, calls the operator back, and clears it before returning:
    - nothing outlives the call, so a forgotten revoke and a three-transaction fallback cannot happen;
    - it names one position and a maximum liquidity, and is never the whole NFT;
    - the adapter checks the outcome: the account's health factor after the call must be at least what it was before (condition 3).

    Once the debt is zero, the operator can still take at most `maxLiquidity` of the named position, inside a call the wallet itself made. That is no more than the wallet could sign away with a plain `withdraw` to the wrong recipient.
2. **Phishing and helper bugs.** Every allowance requires a fresh transaction from the wallet, naming the operator, the position and the amount. Nothing remains to be harvested later. A helper bug reaches only the calling wallet's one position, inside its own call, under the health rule. Another wallet's positions are unreachable because the allowance stores the wallet. The helper also refuses the adapter, the LPVault and the Pool as swap targets, and resets each approval to zero after the call.

    **One operator fixed at deployment: not adopted.** The adapter is deployed before any helper and has no admin. Freezing one helper into it would make a router or lender change a core redeploy. The transient scope already removes the standing-rights risk the condition targets.
3. **Swap price in a crash.** The swap's own `minOut` is the bound. The app sets it from a fresh quote and, as app policy, no more than 1% under the Chainlink price. The flash loan and the health rule make a bad fill revert rather than leave the account worse. An on-chain oracle bound per pool token was **not adopted**. The LPOracle prices band units, not single tokens, so the helper would need its own feeds, an admin to keep them, and staleness handling. That is the rejected policy weight moving into the periphery. Base's sequencer orders transactions first-come, first-served, with no public mempool, which removes classic sandwiches. With outside USDC, `repay` stays the cheapest path, and the app offers it first.
4. **Liquidation and regret.** Liquidation also sells. At $1,320 it seizes $2,299 of the position as pool tokens at a 5% discount, and the liquidator sells them. The regret argument favours partial over full: C gives up about $304 of upside where B gives up $815, and A1 gives up the $109 bonus plus the seized exposure. Whether to deleverage at $1,420.80 is the user's call. The protocol's job is to make that call cost $4, not $109.
5. **UX.** The app offers two actions: "Repay all" (`amount = max`) and "Repay to a safer level", with a target health factor and a preview of the debt, health factor, liquidation price and tokens returned. A preview that goes stale reverts under the health rule or `minOut` instead of filling worse. One-sided returns are shown in the preview, because the withdrawal returns what the position holds.
6. **Scope.** The core change is one function and a 4-slot transient allowance. The Certora rules (allowance cleared after every call; no withdrawal outside it by a non-owner; health factor not lower) are listed for the audit phase. B before C buys nothing in code, because they are one function. The app can still launch "Repay all" first if the audit phase asks for it.
7. **Router allowlist: not adopted.** The helper has no admin, so an allowlist would be frozen at deployment and age badly. The transient scope and the forbidden targets make an arbitrary router safe for everyone except the caller, and the caller already chose the route.
8. **Leftovers only to the wallet: adopted.** `RepayParams` has no recipient field.

## Conclusion

Ship **C**, partial and full in one entry point, built on a one-call allowance instead of an operator approval.

- **What the user gets.** A user without spare stablecoins can step back from liquidation for about $4 on a $10,000 position, instead of paying a $109 bonus. They can choose how much to sell, from a small top-up of safety to closing the loan.
- **What the core gains.** One function. It grants no standing rights, cannot touch another wallet or another position, cannot hand out a whole NFT, and refuses any call that leaves the account less healthy.
- **What the helper is.** Outside the core count. It holds nothing between calls, takes no recipient, refuses the core contracts as swap targets, and leaves the route and its slippage bound to the wallet.

**Open points from the debate:**

- Certora rules for `allowWithdraw` in the audit phase.
- The app's 1% oracle bound on `minOut`, and its "Repay all first" launch option.
- A zero-premium flash lender (for example Morpho Blue on Base) as a later swap of `POOL`, which would save the 5 bps.

## Files

- `FlashloanRepay.sol`, `IFlashloanRepay.sol`: the helper (constructor: adapter, Aave V3 Pool).
- `./libraries/SwapCalls.sol`: caller-built swaps with reset approvals, shared with the liquidation bot's contracts.
- `../adapter/interfaces/IWithdrawReceiver.sol` and `AaveAdapter.allowWithdraw`: the one-call allowance.
- Tests: `test/unit/AaveAdapter.AllowWithdraw.unit.t.sol`, `test/unit/FlashloanRepay.unit.t.sol`, `test/fuzz/FlashloanRepay.fuzz.t.sol`.
