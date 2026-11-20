# AMM parts

Each AMM part is a thin contract on the shared [`LPVault`](../vault/LPVault.sol) base; the lifecycle of a
pledged position is in [the LPVault lifecycle](../vault/LIFECYCLE.md).

- `shared/NfpmLPVault.sol`: shared by the NonfungiblePositionManager AMMs (Uniswap v3, Slipstream):
  `increaseLiquidity`, `decreaseLiquidity` then `collect` capped at the principal, `collect` for fees, and the fee view
  from the pool's fee growth.
- `uniswap-v3/UniswapV3Integration.sol`: the canonical NFPM and factory; a pool is its address as a word.
- `slipstream/SlipstreamIntegration.sol`: four position-manager generations; the generation is the key's high byte.
- `uniswap-v4/UniswapV4Integration.sol`: the PositionManager of hookless pools; a pool is its `PoolId`, registered with
  `registerPool(key)` first. Fees are taken in their own batch before each liquidity change.
- `uniswap-v2/UniswapV2Integration.sol`: Uniswap v2 LP tokens, wrapped one pair per NFT by
  `uniswap-v2/UniswapV2Positions.sol`; full range with liquidity `lp · √k / supply`, Full range markets only. Fees
  compound into the LP; `mint` and `burn` move liquidity. See [the v2 design record](uniswap-v2/DESIGN.md).
