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

Aave V2's AMM market (`UniswapV2PriceProvider`, aave/price-aggregators) used B's formula only part of the time. Its
`latestAnswer` values both reserves at Chainlink prices, `v0 = r0 · p0` and `v1 = r1 · p1`. When the two differ by more
than `MAX_PRICE_DEVIATION` (5%, `scripts/config.ts`), the pair's spot is off Chainlink and it prices the LP token
geometrically, `2 · √(v0 · v1) / supply`: the same `√k` valuation as B, which its specification calls exact under both
the trade and the `sync` attacks. Otherwise it takes the arithmetic shortcut `(v0 + v1) / supply`, which is exact only
when the pool sits at Chainlink's price and costs less gas. Avana keeps the geometric formula always and drops the
shortcut. By AM-GM, `2 · √(v0 · v1) ≤ v0 + v1`, so Avana never values an LP token above Aave's provider in any state;
inside the 5% window the two differ by at most 0.03% (at the edge, `2 · √1.05 / 2.05 = 0.9997`), and outside it they
are equal. The shortcut's gas saving does not apply: Avana's oracle never reads the reserves at all, and pricing one
liquidity unit at the fair price costs the same on every read.

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
  protocol fee `_mintFee` would mint next, so a pending fee never overstates the credit. It is counted whenever
  `kLast` is set, also while `feeTo` is off: v2-core keeps `kLast` until the next mint or burn, so a fee switched on
  after a pledge mints on all growth since then. Counted only while the fee is on, as Aave's provider does, a credit
  read with the fee off came out 0.03% above the LP's liquidity after the switch in the regression test. With the fee
  off Avana therefore reads at most the pending fee below Aave's provider, never above. With tick spacing 1 the Full
  range band is exactly those ticks, so the credit is the liquidity, and the existing full-range `LPOracle` prices it.
- Full range only. `RiskModule.listPool` (with `tickSpacing = 1`) still lists the pair's Custom range market, but no v2
  position fits inside it (`NotInsideBand`), so governance never activates it. Listing needs both tokens listed on the CDP
  Spoke's Aave V4 price Spoke, as for every pool.
- v2 fees compound into `k`, so there is nothing to collect. The record's liquidity is fixed at the pledge. A removal or
  unwind burns only the LP that holds the removed liquidity at the pair's √k now, `⌈liquidity · supply / √k⌉` with the
  pending protocol fee in the supply, and never more than the same fraction of the record's LP (what the NFT held at the
  pledge plus LP added through the LPVault). Fee growth since the pledge therefore stays in the position, as v3 and v4
  fees do, and a release returns it with the NFT. Until 2026-11-23 the burn took the record's fraction, growth included,
  so a partial liquidation paid the borrower's growth on the unwound share to the liquidator: $432 on a $10,000
  position with 10% growth, against $4,296 of seized units (`LiquidationUniswapV2FeeGrowth.AaveV4.integration.t.sol`).
  LP sent straight to a pledged
  position through the open `increase` is not credited, so it is never burned either: it goes back with the NFT, as
  liquidity added straight to a Uniswap v3 position does.
- Token amounts out of `burn` are the LPVault's balance differences, so a fee-on-transfer or rebasing token cannot pay
  one position from another's tokens. Such tokens are not listed: a negative rebase followed by `sync` lowers `k` below
  the pledged credit. A removal that would redeem zero of either token (dust on a heavily skewed pair) burns nothing,
  so the pair's `burn` never reverts a liquidation.
- Not in scope: Aerodrome basic pools.
