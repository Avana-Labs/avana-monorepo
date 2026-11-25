---
title: Contract Addresses
description: Addresses of the Aave V4 Hubs and Spokes Avana lists on, the contracts Avana deploys, and the external contracts and tokens it depends on, per network.
updated: {{updated}}
---

Avana lists AMM liquidity positions as collateral on Aave V4: each chain has its Hubs, the Lend Spokes where lenders supply, and the CDP Spokes where pledged positions back borrowing. Avana deploys one core stack per AMM integration (LPVault, RiskModule, LiquidationModule, AaveAdapter and FlashloanRepay) under one AccessManager, and both loss layers of each (Hub, debt asset). Each release also records its addresses in its release manifest.

Market bands and listing values are on [Market Parameters](/developers/reference/parameters); roles and who can change what are on [Access Control](/developers/reference/access-controls).

Every Avana chain runs the standard, unmodified Aave V4 release pinned at commit `a3ef63ea6415d25237a9775bf66e76e9993561c2`, and Avana's contracts use OpenZeppelin Contracts v5.1.0, pinned by commit. No Avana contract is upgradeable. The libraries under `contracts/src` (among them LPPriceMath, BandMath, FloorCreditMath, LiquidationMath and AvanaRoles) are compiled into the contracts that use them and have no address of their own.

{{networks}}
