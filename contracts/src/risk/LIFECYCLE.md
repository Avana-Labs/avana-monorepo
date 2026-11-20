# RiskModule lifecycle

Interface: [IRiskModule.sol](IRiskModule.sol). Design: [DESIGN.md](DESIGN.md).

1. **Setup (DAO).** Calls `registerSpoke(spoke, hub, kind)` for each CDP Spoke, `setDebtReserve(spoke, reserveId, firstLossReserve)` for each borrowable asset, then `setCoverageRatio`, `setFee` and `addKeeper`. The AccessManager grants the RiskModule the LPVault's `listMarket`.
2. **Listing (DAO, one call per pool).** `listPool` lists the Full range and Custom range markets in the LPVault at one LTV, checks the Chainlink price against the Custom band, and records each market's vault-token decimals.
3. **Deployment.** For each market, a VaultToken (market ID, Hub, LiquidationModule, the recorded decimals, the AccessManager) and an LPOracle (the same feeds) are deployed. Aave lists the reserve with the oracle as its source: collateral factor = the market's LTV, draw cap 0, receive-shares off, liquidation fee 0.
4. **Activation.** `activateMarket(marketId, vaultToken, lpOracle)` checks all of the above and marks the market active.
5. **Use.** The AaveAdapter routes each position with `routeOf`, reads `creditOf`, and calls `checkBorrow` before each borrow: the debt reserve is registered, a keeper exists, and the First-Loss Reserve covers the draw caps.
6. **Depeg or drift.** The steward freezes the Aave reserves on a depeg. A drifted volatile pool gets a new listing (a new pair). Old markets keep their bands and positions.
