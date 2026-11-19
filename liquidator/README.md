# liquidator

Avana's own liquidation bot, outside the protocol and its audit.

`FlashLiquidator` and `OperatorFlashLiquidator` borrow the debt asset from the chain's Aave V3 Pool, call
`LPVaultSwap.liquidate` and repay the loan from the payout ([LIFECYCLE.md](src/LIFECYCLE.md)). They import the
protocol's interfaces and types from `../contracts/src` (remapped as `avana/`) and its dependencies from
`../contracts/dependencies`, so install those first (`forge soldeer install` in `contracts/`).

```sh
cd liquidator
forge build
```
