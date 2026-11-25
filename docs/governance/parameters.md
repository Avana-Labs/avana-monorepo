# Avana parameters

Last updated: 2026-11-24

Every value on this page exists in code; each row names the file and line that holds or checks it. Contract files are under `contracts/src/`, deploy scripts under `contracts/script/deploy/`. Values that the network config sets per chain are read by the deploy script named in the row; the proposal they belong to is the [ARFC](arfc-avana-lp-collateral.md). How a value changes is in the [governance README](README.md#changing-a-parameter).

## A. Avana settings (RiskModule, one per integration)

Each is a RiskModule setter, restricted through Avana's AccessManager.

| Parameter | What it does | Bound in code | Set from | Role and delay |
|---|---|---|---|---|
| Fee share `feeShareBps` and `feeRecipient` | Avana's share of each liquidation's bonus, paid in kind in the two pool tokens (`LiquidationMath.feeUnits`, `LiquidationMath.sol:25`), and who receives it | at most `MAX_FEE_SHARE_BPS` = 5,000 bps (`RiskModule.sol:39`); recipient not zero (`RiskModule.sol:213`); setter `setFee` (`RiskModule.sol:209`) | `parameters.globals.avanaFeeShareBps`, `parameters.globals.feeRecipient` (`09_ListMarkets.s.sol:111-112`); the ARFC proposes 2,000 bps (20%) | Governance, 4 to 5 days |
| Coverage ratio `coverageRatioBps` | The share of the summed draw caps of every Avana CDP Spoke borrowing an asset that the asset's First-Loss Reserve must hold; below it `checkBorrow` refuses every new borrow of the asset (`CoverageBelowRatio`, `RiskModule.sol:259`). Required amount `drawCapSum · 10^decimals · ratioBps / 10^4`, rounded up (`AaveConfigLogic.sol:101`) | at most 10,000 bps (`RiskModule.sol:199`); setter `setCoverageRatio` (`RiskModule.sol:196`) | `parameters.coverageRatioBps` (`09_ListMarkets.s.sol:113`); the ARFC leaves the value to the funding ARFC | Governance, 4 to 5 days |
| Custom range default width per Spoke kind | The band around the listing price a Custom range market gets when its listing names no width. Defaults (ticks below / above): Stable 101 / 100 (±1%), Correlated 513 / 488 (±5%), Volatile 10,643 / 10,641 (0.345x to 2.898x) (`RiskModule.sol:67-69`) | each side above 0 and at most 2 · `MAX_TICK` (`RiskModule.sol:440`); setter `setSpokeWidth` (`RiskModule.sol:92`); a change touches no listed market | Constructor defaults | Governance, 4 to 5 days |
| Per-pool width override | `ListPoolParams.width`; zero on both sides means the Spoke kind's default (`RiskModule.sol:393`) | as above | The listing operation (`09_ListMarkets` passes none, so every market takes the default) | Governance, with `listPool` |
| Market LTV `ltvBps` | Fixed per pool at listing; `activateMarket` requires the Aave reserve's collateral factor to equal it (`AaveConfigLogic.sol:79`) | above 0 and below 10,000 bps (`RiskModule.sol:106`) | The lower of the two tokens' collateral factors on the price Spoke, or the market's `eModeLtvBps` on a Correlated Spoke (`09_ListMarkets.s.sol:205-222`) | Governance, with `listPool` |
| Spoke registration | Each CDP Spoke's Hub, kind (Stable, Correlated, Volatile) and price Spoke; a registered Spoke cannot change its Hub or price Spoke | `RiskModule.sol:73-90` | `listing.spokes` (`09_ListMarkets.s.sol:89-108`) | Governance, 4 to 5 days |
| Debt reserves | Which CDP Spoke reserves can be borrowed through Avana, each with its (Hub, asset)'s First-Loss Reserve | the reserve must be listed on the Spoke and the First-Loss Reserve must match its Hub and asset (`RiskModule.sol:152-176`); `removeDebtReserve` (`RiskModule.sol:179`) | `listing.debtReserves` and `coverage.json` (`09_ListMarkets`) | `setDebtReserve`: governance, 4 to 5 days. `removeDebtReserve`: tighten, 12 hours (the Joint Configuration Safe at once) |
| Keepers | The keeper registry. It gates no call: liquidation is open to anyone. With no keeper registered, `checkBorrow` refuses every new borrow (`RiskModule.sol:257`) | at most `MAX_KEEPERS` = 16 per RiskModule (`RiskModule.sol:37`, `:228`); `addKeeper` (`RiskModule.sol:224`), `removeKeeper` (`RiskModule.sol:237`) | `keepers` (`09_ListMarkets.s.sol:114`) | `addKeeper`: governance, 4 to 5 days. `removeKeeper`: tighten, 12 hours (the Joint Configuration Safe at once) |

## B. Fixed in code

| Value | What it does | Where |
|---|---|---|
| Tighten delay, 12 hours | Execution delay of `AVANA_TIGHTEN_ROLE` for the governance Safe | `AvanaAccess.sol:34` (`contracts/script/deploy/lib/`) |
| Governance delay, 4 to 5 days | Execution delay of `AVANA_GOVERNANCE_ROLE`: the config's `timelockNormalDelay` when it lies in that range, else 4 days | `AvanaAccess.sol:37`, `:40`, `:49-51`; read in `03_DeployAvana.s.sol:190` |
| First-Loss Reserve withdrawal delay, 14 days | `WITHDRAWAL_DELAY`, the withdraw role's delay on the Aave AccessManager | `FirstLossReserve.sol:26`; granted in `08_AaveLossLayersPayload.s.sol:68`; `AvanaAccess.sol:43` |
| Minimum band width, 4 tick spacings | `MIN_BAND_SPACINGS`: the fewest tick spacings a Custom range band spans | `BandMath.sol:15`, `RiskModule.sol:35` |
| Vault-token decimals, 6 to 18 | The fewest decimals at which a whole vault token is worth at least $1 at listing (`MIN_UNIT_VALUE` = 1e8, 8-decimal USD) | `BandMath.sol:17-19`, `:75`; `VaultToken.sol:18-19` |
| Positions per account, 16 | `MAX_POSITIONS` an account can hold in one LPVault | `LPVault.sol:29`, `:81` |

## C. Set by the Aave DAO

Avana proposes a starting point in the config and the ARFCs; the Aave DAO decides through its AIPs. The code below writes or checks each value.

| Parameter | What it does | Where in code |
|---|---|---|
| Draw cap per CDP Spoke and debt asset | What a CDP Spoke can borrow of one asset. The ARFC proposes draw caps summing to 2M GHO on Ethereum to start | `aavePayload.debtAssets[].drawCap`, written by `06_AaveDeploymentPayload.s.sol:333`; summed in `AaveConfigLogic.sol:101-117` |
| Rate curve per debt asset | Aave V4's kinked utilization curve | `06_AaveDeploymentPayload.s.sol:248-261` (default when the config names none: `:254`) |
| Bootstrap supply (test networks) | The DAO treasury's first supply on each Lend Spoke | `06_AaveDeploymentPayload.s.sol:365` |
| First-Loss Reserve minimum, DAO Deficit Offset minimum | Each layer's `minimum`; Avana Labs funds its layer to it, and the DAO its offset | `aavePayload.debtAssets[].coverageMinimum`, `.offsetMinimum` (`07_DeployFirstLossReserves.s.sol:77-78`); setter `FirstLossReserve.setMinimum` (`FirstLossReserve.sol:121`), reserve-admin role |
| Allowed CDP Spokes per loss layer | Which Spokes' deficits a layer covers | `FirstLossReserve.setAllowedSpoke` (`FirstLossReserve.sol:107`), set by `08_AaveLossLayersPayload.s.sol:136-139` |
| Vault-token supply cap `addCap` | What a market's CDP Spoke reserve can hold, in whole vault tokens | the market's `marketUsdCap` (`09_ListMarkets.s.sol:352`), written by `10_AaveListingPayload.s.sol:196`, `:216` |
| Vault-token reserve settings | Draw cap 0, receive-shares off, liquidation fee 0, collateral factor equal to the market's LTV, max liquidation bonus the higher of the two tokens' on the price Spoke, the CDP Spoke's liquidation config equal to the price Spoke's, price source the market's LPOracle | written by `10_AaveListingPayload`; checked by `activateMarket` in `AaveConfigLogic.sol:75-81`, `:129-134` |
| CDP Spoke liquidation config | Target health factor, health factor for the max bonus, bonus factor: copied from the price Spoke | `06_AaveDeploymentPayload.s.sol:281-287` |

Nothing else is an Avana parameter. Aave's own controls (freezes, pauses, caps, collateral factors after listing) are Aave's and change only through Aave governance.
