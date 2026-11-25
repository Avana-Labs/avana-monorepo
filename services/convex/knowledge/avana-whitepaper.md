# Avana

## Collateral

A listed pool has two markets, Full range and Custom range. An NFT inside the band is credited once, at pledge, as a share of one unit of liquidity spread over the band. One vault-token base unit is one credit unit.

## Price

The LPOracle answers what one unit of band liquidity is worth now. It takes Aave V4's prices of the two tokens, clamps the price to the band, and values the resulting amounts. The guarantee is that credit times that answer is at most the position's value at the same price.

## Borrow Spoke

Each AMM integration has a CDP Spoke on an Aave V4 Hub. Lenders supply on a Lend Spoke. Borrowers draw the Hub's assets against the vault token. There is no Hub-to-Hub credit line in Avana's deployment.

## Loss

Each Hub asset Avana lists has two loss layers, both First-Loss Reserves on Aave's AccessManager: Avana's layer, then the DAO deficit offset. A draw does not reach the next layer until the one in front of it is empty.

## Liquidation Flow

Liquidation is open to every address. The module unwinds the position and repays. What remains goes to the owner. The valuation used for borrow power is recoverable value.
