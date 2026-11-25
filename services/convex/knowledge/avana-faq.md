# Avana FAQ

## What is Avana?

Avana lists Uniswap v3, Uniswap v4 and Aerodrome Slipstream LP positions as collateral on Aave V4. A position inside a listed band is credited once, at pledge. The vault token is priced by that market's LPOracle from Aave V4's own token prices. Borrowing, interest and health are Aave's.

## Where does the price come from?

The LPOracle reads `AaveOracle.getReservePrice` on the CDP Spoke's price Spoke. It does not read a Chainlink feed of its own, a pool spot price, or an AMM TWAP. Aave rejects a zero price. Avana adds only an overflow bound.

## Is there a circuit breaker?

No. Avana does not pause itself. A debt reserve or a keeper is removed by the Joint Configuration Safe at once, or by the governance Safe after 12 hours. Freezing or pausing an Aave reserve is Aave's control.

## Who governs a change?

Each chain has its own AccessManager. The governance Safe schedules listings and parameter changes. The delay is 4 to 5 days, or 12 hours for removing a debt reserve or a keeper. The Aave governance executor is admin and can cancel a scheduled call. The Emergency Guardian holds no role.

## What happens in a liquidation?

Anyone can liquidate. The Liquidation Flow unwinds the LP position, repays the debt and returns what is left. Borrow power uses recoverable value, not an optimistic net asset value.
