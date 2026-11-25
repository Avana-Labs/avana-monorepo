---
title: Market Parameters
description: Each Avana market's band and listing values per Spoke, the loss layers, and the protocol-wide Avana and Aave-side rules.
updated: {{updated}}
---

**Deployment values.** Each network's section shows the values that network's deployment listed with, read from its release manifest and deploy output. On mainnet the Aave DAO sets collateral factors, caps, liquidation bonuses, rate curves and First-Loss Reserve minimums through its proposals; Avana's LTVs copy Aave's own collateral factors.

{{networks}}

## All networks

These rules are the same on every network. Bounds are enforced on-chain unless the description says otherwise. `Set by governance` means the value is set by a call of the governance role (Avana's AccessManager) or by an Aave DAO payload; `Per network` means each network's section gives it.

### Markets

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| Markets per pool | 2 | — | `listPool` lists each pool as a Full range market, whose band is the pool's usable tick range, and a Custom range market, a band around the listing tick. Both share one LTV. A pledge goes to Full range when the position is full range, to Custom range when it lies fully inside that band, and is refused otherwise. | `RiskModule.sol` `listPool`, `IAaveAdapter.sol` `pledge`; `design/risk.md` Decision 1 |
| Band | Fixed for life | — | A market's band never changes once listed, so one vault-token unit always means one unit of credit in that band. | `design/risk.md` Decision 3 |
| Custom range width | Stable ±1% (101 / 100 ticks), Correlated ±5% (513 / 488), Volatile 0.345× to 2.898× (10,643 / 10,641) | Set by governance per Spoke kind (`setSpokeWidth`); a listing can give its own | Ticks below and above the listing tick, rounded outward to the tick spacing. | `RiskModule.sol` constructor, `BandMath.sol` |
| `MIN_BAND_SPACINGS` | 4 | — | Fewest tick spacings a Custom range band spans. A band must also be strictly narrower than full range and contain Aave's price when `listPool` executes. | `BandMath.sol`, `RiskModule.sol` `listPool` |
| LTV | Lower of the two tokens' collateral factors on the price Spoke | 1–9,999 bps | Read from the CDP Spoke's price Spoke when the listing is proposed. A correlated pair on a Correlated Spoke may instead take the listing's `eModeLtvBps`. The vault-token reserve's collateral factor equals it. | `09_ListMarkets.s.sol` `_ltv`, `RiskModule.sol` `listPool` |
| Max liquidation bonus | Higher of the two tokens' on the price Spoke | — | The vault-token reserve's max liquidation bonus; the CDP Spoke's liquidation configuration is the price Spoke's. | `09_ListMarkets.s.sol` `_marketRow`, `AaveConfigLogic.sol` `maxTokenBonus` |
| Add cap | The listing's `marketUsdCap`, in whole vault tokens | — | Supply cap of the vault-token reserve. A whole vault token is worth at least $1 at listing, so the cap in tokens bounds the market's USD value at listing prices. | `10_AaveListingPayload.s.sol` |
| Vault-token decimals | Fewest at which a whole token is worth at least $1 at listing | 6–18 | Chosen by the RiskModule when it lists the market. | `BandMath.sol` (`MIN_UNIT_VALUE`, `MIN_UNIT_DECIMALS`, `MAX_UNIT_DECIMALS`) |
| Activation check | — | — | `activateMarket` requires the LPOracle to price this market from the price Spoke's reserves named at listing, the Spoke reserve to hold the vault token with the LPOracle as price source, a draw cap of 0, receive-shares off, a liquidation fee of 0, the collateral factor equal to the LTV and the max liquidation bonus as above. | `RiskModule.sol` `activateMarket`, `AaveConfigLogic.sol` |
| `MAX_POSITIONS` | 16 | — | Most open positions one account holds in its LPVault. | `LPVault.sol` |

### Oracles

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| LPOracle price | Aave V4's prices of both pool tokens | — | Each read takes both tokens' prices from the price Spoke's AaveOracle (whatever source Aave governance set, CAPO included), the fair square-root price of the two clamped to the band, and values what one whole vault token holds there, rounded down. It keeps no state. | `LPOracle.sol`, `LPPriceMath.sol` |
| Answer decimals | 8 | — | Decimals of every LPOracle answer and of the prices it reads. | `LPPriceMath.sol` (`DECIMALS`) |
| `MAX_PRICE` | $10,000,000,000 per token | — | Largest token price the LPOracle serves, small enough that its price math cannot overflow. | `LPPriceMath.sol` |

### Borrowing, fees and keepers

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| `checkBorrow` | — | — | A borrow needs a debt reserve registered on its Spoke, at least one registered keeper, and First-Loss coverage of its (Hub, asset) at `coverageRatioBps`; Aave checks the health factor. | `RiskModule.sol` `checkBorrow` |
| `coverageRatioBps` | Set by governance | 0–10,000 bps | Required funded balance of the First-Loss Reserve of each (Hub, asset), as a share of the draw caps of every Spoke borrowing that asset. | `RiskModule.sol` `setCoverageRatio` |
| `feeShareBps` | Set by governance | 0–5,000 bps (`MAX_FEE_SHARE_BPS`) | Avana's share of each liquidation's bonus, paid to `feeRecipient` in the seized pool tokens. | `RiskModule.sol` `setFee`, `LiquidationMath.sol` `feeUnits` |
| `feeRecipient` | Avana treasury | Non-zero address | Receives the fee share; set with the share by `setFee`. | `RiskModule.sol` `setFee` |
| `MAX_KEEPERS` | 16 | — | Most keepers one RiskModule registers. Borrowing stops while none is; liquidation is open to anyone. | `RiskModule.sol` |
| Keeper top-up | Per network | `minBalanceWei` > 0, `targetBalanceWei` > `minBalanceWei` | The keeper top-up wallet refills each keeper signer below the minimum to the target. Required on every chain but a local node. | `DeployInputs.sol` `_keeperTopUp`, `11_FundKeepers.s.sol` |

### Aave-side settings

The Aave DAO sets these on its Hubs and Spokes; the deployment payloads propose Avana's values.

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| Lend Spoke caps | Add cap `MAX_ALLOWED_SPOKE_CAP`, draw cap 0 | — | Each Lend Spoke takes supply of its Hub's debt assets and draws nothing. | `06_AaveDeploymentPayload.s.sol` `_hubSpokes` |
| CDP Spoke debt caps | Add cap 0, draw cap set by governance | — | Each CDP Spoke draws a debt asset up to its draw cap and takes no supply of it. The draw caps size the First-Loss coverage `checkBorrow` requires. | `06_AaveDeploymentPayload.s.sol` `_spokeOnAssets` |
| Debt reserves | Listed not borrowable, then made borrowable | — | The deployment payload lists each CDP Spoke's debt reserves with collateral factor 0 and not borrowable; the listing payload makes the reserves of `listing.debtReserves` borrowable. | `06_AaveDeploymentPayload.s.sol`, `10_AaveListingPayload.s.sol` |
| Rate curve | Set by governance; Avana proposes 90% optimal usage, 0 base, 4% and 60% growth | — | Aave V4's kinked curve for each debt asset on each Hub, applied when the asset is listed. | `06_AaveDeploymentPayload.s.sol` `_rateModel` |
| Liquidity fee | Set by governance; 0 unless the payload gives one | — | Share of borrow interest the Hub keeps for its fee receiver, the treasury Spoke. | `06_AaveDeploymentPayload.s.sol` `_liquidityFee` |
| CDP liquidation configuration | The price Spoke's | — | Target health factor, health factor for the max bonus and bonus factor of each CDP Spoke, copied from its price Spoke. | `06_AaveDeploymentPayload.s.sol` `_hubSpokes` |

### Loss layers

Each covered (Hub, debt asset) has Avana's First-Loss Reserve, funded by Avana Labs, and behind it the DAO deficit offset, funded by the Aave DAO treasury. Both are the same FirstLossReserve contract, governed through the Aave AccessManager.

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| Loss order | Avana, then the DAO, then disclosure | — | The offset pays only the part of a deficit beyond what the Avana layer holds while that layer is active on the Hub. A loss beyond both stays recorded on the Hub. | `FirstLossReserve.sol` `coverDeficit`, `design/reserve.md` |
| Coverage | `min(maxAmount, deficit beyond the front layer, balance)` | — | Covers only a deficit the Hub recorded for an allowed CDP Spoke, in the reserve's own asset, by burning its Hub added shares. | `FirstLossReserve.sol` |
| Minimum | Per network | — | Funded balance the funding proposal sets; a cover or withdrawal that leaves less raises an alert. Each network's minimums are under its Loss layers. | `07_DeployFirstLossReserves.s.sol`, `FirstLossReserve.sol` `setMinimum` |
| `WITHDRAWAL_DELAY` | 1,209,600 s (14 days) | — | Execution delay of the withdraw role on the Aave AccessManager. A withdrawal reverts while an allowed Spoke has a recorded deficit. | `FirstLossReserve.sol`, `08_AaveLossLayersPayload.s.sol` |
| `fund` | Anyone | — | Pulls the asset straight to the Hub and adds it to the reserve; the funder gets no claim. | `FirstLossReserve.sol` `fund` |

### Governance delays

| Parameter | Value | Bounds | Description | Source |
| --- | --- | --- | --- | --- |
| Governance delay | Per network | 345,600–432,000 s (4 to 5 days) | Execution delay of `AVANA_GOVERNANCE_ROLE` for the governance Safe: the config's `timelockNormalDelay` when it lies between 4 and 5 days, else 4 days. Each network's value is under its Chain settings. | `AvanaAccess.sol` `governanceDelay`, `03_DeployAvana.s.sol` |
| Tighten delay | 43,200 s (12 hours) for the governance Safe; none for the Joint Configuration Safe | — | Execution delay of `AVANA_TIGHTEN_ROLE`: `removeDebtReserve` and `removeKeeper`. | `AvanaAccess.sol` (`TIGHTEN_DELAY`), `03_DeployAvana.s.sol` |
| Reserve withdrawal delay | 1,209,600 s (14 days) | — | Execution delay of the First-Loss Reserves' withdraw role, held by the Aave governance executor. | `AvanaAccess.sol` (`RESERVE_WITHDRAW_DELAY`), `08_AaveLossLayersPayload.s.sol` |
