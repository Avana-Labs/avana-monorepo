---
title: Contract Addresses
description: Addresses of the Avana Hub and Spokes, the contracts Avana deploys, and the external contracts and tokens it depends on, per network.
updated: {{updated}}
---

Each chain has one Avana Hub on Aave V4, with a Lend Spoke and the CDP Spokes where AMM liquidity positions are collateral. Each release also records its addresses in its release manifest.

Market pools and risk values are on [Market Parameters](/developers/reference/parameters); roles and who can change what are on [Access Control](/developers/reference/access-controls).

Every Avana chain runs the standard, unmodified Aave V4 release pinned at commit `a3ef63ea6415d25237a9775bf66e76e9993561c2`, and Avana's timelock and upgradeable contracts use OpenZeppelin Contracts and Contracts Upgradeable v5.1.0, pinned by commit. The libraries LPPriceMath, SettlementMath and AvanaRoles are compiled into the contracts that use them and have no address of their own.

{{networks}}
