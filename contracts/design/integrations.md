# AMM parts

Each AMM part is a thin contract on the shared [`LPVault`](../src/LPVault.sol) base; the lifecycle of a
pledged position is in [the LPVault lifecycle](vault.md#lifecycle).

- [`NfpmLPVault.sol`](../src/integrations/NfpmLPVault.sol): shared by the NonfungiblePositionManager AMMs (Uniswap v3, Slipstream):
  `increaseLiquidity`, `decreaseLiquidity` then `collect` capped at the principal, `collect` for fees, and the fee view
  from the pool's fee growth.
- [`UniswapV3Integration.sol`](../src/integrations/UniswapV3Integration.sol): the canonical NFPM and factory; a pool is its address as a word.
- [`SlipstreamIntegration.sol`](../src/integrations/SlipstreamIntegration.sol): four position-manager generations; the generation is the key's high byte.
- [`UniswapV4Integration.sol`](../src/integrations/UniswapV4Integration.sol): the PositionManager of hookless pools; a pool is its `PoolId`, registered with
  `registerPool(key)` first. Fees are taken in their own batch before each liquidity change.
- [`UniswapV2Integration.sol`](../src/integrations/UniswapV2Integration.sol): Uniswap v2 LP tokens, wrapped one pair per NFT by
  [`UniswapV2Positions.sol`](../src/integrations/UniswapV2Positions.sol); full range with liquidity `lp · √k / supply`, Full range markets only. Fees
  compound into the LP; `mint` and `burn` move liquidity. See [the v2 design record](uniswap-v2.md).
