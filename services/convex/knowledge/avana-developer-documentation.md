# Avana developer documentation

## Borrow Spoke

A Borrow Spoke is an Aave V4 CDP Spoke. Avana's AaveAdapter is its position manager. Pledge locks an LP position in the LPVault and mints the market's vault token. Borrow, repay and health are the Spoke's.

## Oracle

One immutable LPOracle per market. It reads Aave's price of each pool token from the price Spoke fixed when the Spoke was registered. It does not call the pool, a Chainlink aggregator, or a TWAP.

## Liquidation Flow

`LiquidationModule.liquidate` is permissionless. It repays debt on the Spoke, burns vault tokens and tells the LPVault to unwind the position. The keeper registry does not gate the call. While the registry is empty, new borrows are refused.

## Governance

Restricted Avana functions go through the chain's AccessManager.

| Role | Who | Delay |
|---|---|---|
| Admin | Aave governance executor | The AIP |
| Governance | Governance Safe | 4 to 5 days |
| Tighten | Joint Configuration Safe, and the governance Safe | None for the Joint Configuration Safe; 12 hours for the governance Safe |

Removing a debt reserve or a keeper stops new borrowing of that reserve, or of the whole RiskModule once no keeper remains. Repayment and liquidation stay open. Avana has no circuit breaker and no pause.

## Recoverable value

Borrow power is the vault token's Aave collateral value. That value is the oracle's answer for the credited liquidity, which is bounded by the position's recoverable value inside the band.
