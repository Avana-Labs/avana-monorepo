# Uniswap v2 Full range markets

## Problem

Uniswap v2 LP tokens on Ethereum are ERC-20s, not position NFTs. Avana should accept them as Full range collateral
without a second custody or liquidation path, and without letting anyone raise the credit of an LP token by moving the
pair's price or reserves inside one transaction.

## Options

Worked example: a $10,000 position in a WETH/USDC pair at $2,000/ETH. The pair holds 100 ETH and 200,000 USDC; the
position is 2.5% of the LP supply (2.5 ETH + 5,000 USDC). An attacker then sells 300 ETH into the pair (flash swap or
plain swap), leaving about 400 ETH and 50,125 USDC.

| Option | Credit before | Credit after the swap | Notes |
| --- | --- | --- | --- |
| A. LP value from the reserves at Chainlink prices: `share · (r0 · p0 + r1 · p1)` | $10,000 | $21,253 | The swap more than doubles the collateral for one transaction. Rejected. |
| B. √k share, priced by the existing full-range `LPOracle` | $10,000 | $10,000 | `liquidity = lp · √(r0 · r1) / supply`; a swap only raises `k` by its fee. Chosen. |
| C. Hold the ERC-20 in the LPVault by amount per account | as B | as B | Every LPVault, adapter and liquidation path is keyed by an NFT; this forks all of them. Rejected. |

Aave V2's AMM market made the same choice as B: it priced Uniswap v2 LP tokens from Chainlink prices and the pool's
invariant, not from the raw reserves.

Under B a full-range liquidity `L` is worth `2 · L · √(p0 · p1)` at the fair price, whatever the reserves. That is at
most what the reserves hold (AM-GM), so an in-kind liquidation at manipulated reserves pays at least the oracle value:
in the example 2.5% of the moved reserves is 10 ETH + 1,253 USDC, about $21,253, for $10,000 of credit. A donation
followed by `sync` raises `k` for every holder. With a 2.5% share, donating 0.5 ETH ($1,000) raises the attacker's
credit by about $25.

## Decision

- `UniswapV2Positions` wraps v2 LP tokens of the factory's own pairs into ERC-721 positions. The shared `LPVault` then
  holds, credits, releases and unwinds them unchanged, through `UniswapV2Integration`. It has no roles: anyone may add
  LP to a position, and only the NFT's owner (the LPVault, once pledged) takes LP out.
- A position reads as `[MIN_TICK, MAX_TICK]` with `liquidity = lp · √(r0 · r1) / supply`. The supply includes the
  protocol fee `_mintFee` would mint next, so a pending fee never overstates the credit. With tick spacing 1 the Full
  range band is exactly those ticks, so the credit is the liquidity, and the existing full-range `LPOracle` prices it.
- Full range only. `RiskModule.listPool` (with `tickSpacing = 1`) still lists the pair's Custom range market, but no v2
  position fits inside it (`NotInsideBand`), so governance never activates it. Listing needs Chainlink routes for both
  tokens, as for every pool.
- v2 fees compound into `k`, so there is nothing to collect. The record's liquidity is fixed at the pledge. A removal or
  unwind burns the same fraction of the position's LP, so later fee growth is shared in the same proportion, and a
  release returns all of it.
- Token amounts out of `burn` are the LPVault's balance differences, so a fee-on-transfer or rebasing token cannot pay
  one position from another's tokens. Such tokens are not listed: a negative rebase followed by `sync` lowers `k` below
  the pledged credit. A removal that would redeem zero of either token (dust on a heavily skewed pair) burns nothing,
  so the pair's `burn` never reverts a liquidation.
- Not in scope: Aerodrome basic pools.
