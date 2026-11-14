# Integration assumptions: external-protocol check

Date: 2026-11-10. Scope: every external-protocol assumption in `docs/spec/04-security/03-external-dependencies.md`, `docs/spec/02-contracts/01, 05, 06, 10, 11, 12`, the vendored interfaces in `contracts/src/interfaces/external/`, and the AMM-neutral proposal (multi-Hub, Aerodrome Slipstream on Base, flash-mint liquidation). Base-chain, Slipstream, Uniswap v4 and the "standard Spoke plus transfer-restricted vault token" question are covered in depth in the internal research note `amm-integration-facts.md`; rows below on those topics give only the result and the source line.

## Sources and method

| Source | Ref |
|---|---|
| Aave V4 | `aave/aave-v4` `a3ef63ea6415d25237a9775bf66e76e9993561c2` (still `main` HEAD on 2026-11-10); liquidation-manager variant at `455a40659431a512aa541fe62d18cb0ae918c9d4` (newest variant commit, 2026-10-26) |
| GHO | `aave/gho-core` `c6335a0bb9cba099960c5378b1ff0db190b8da8f`; `aave-dao/aave-address-book` `main` and `cd30f7e4de8870e04bf95df04384d7f92cd7a963` |
| Uniswap v3 | `Uniswap/v3-core` and `Uniswap/v3-periphery` `main` |
| Slipstream | `aerodrome-finance/slipstream` `main` |
| Chainlink | `smartcontractkit/chainlink-evm` `4d83db2`; Chainlink reference data directory (`feeds-mainnet.json`, `feeds-ethereum-mainnet-base-1.json`), read 2026-11-10 |
| Live chain state | Ethereum mainnet block 26,383,651 (timestamp 1,794,303,431), read-only `eth_call` |

Abbreviations: `AV4` = `https://github.com/aave/aave-v4/blob/a3ef63ea6415d25237a9775bf66e76e9993561c2`; `AV4V` = `https://github.com/aave/aave-v4/blob/455a40659431a512aa541fe62d18cb0ae918c9d4`; `GC` = `https://github.com/aave/gho-core/blob/c6335a0bb9cba099960c5378b1ff0db190b8da8f`; `AB` = `https://github.com/aave-dao/aave-address-book/blob/main/src`; `V3C` / `V3P` = `https://github.com/Uniswap/v3-core/blob/main/contracts` / `https://github.com/Uniswap/v3-periphery/blob/main/contracts`; `SS` = `https://github.com/aerodrome-finance/slipstream/blob/main/contracts`; `RDD` = `https://reference-data-directory.vercel.app`.

Status counts (60 assumptions): **CONFIRMED 45 · WRONG 10 · UNVERIFIABLE 5**. The 10 WRONG rows give 8 findings (B16 and B19 fold into AMMN-INT-04, A8 is AMMN-INT-04).

## 1. Aave V4 interfaces (signatures, structs, events, errors)

| # | Assumption | Spec location | Source evidence | Status | Impact and fix |
|---|---|---|---|---|---|
| A1 | `IAaveV4Spoke` structs `Reserve`, `ReserveConfig`, `DynamicReserveConfig`, `LiquidationConfig`, `UserPosition`, `UserAccountData` match field order and widths | `contracts/src/interfaces/external/aave/IAaveV4Spoke.sol:24-84` | `AV4/src/spoke/interfaces/ISpoke.sol#L44-L137` | CONFIRMED | `hub` (`IHubBase`) and `flags` (`ReserveFlags is uint8`) encode as `address`/`uint8`, as the interface notes |
| A2 | `supply`, `withdraw`, `borrow`, `repay` `(reserveId, amount, onBehalfOf) → (uint256, uint256)`; `liquidationCall` 5 args; `setUsingAsCollateral`; all view getters and `ORACLE()`, `MAX_USER_RESERVES_LIMIT()` | `IAaveV4Spoke.sol:91-267` | `ISpoke.sol#L488-L786` | CONFIRMED | Selectors identical |
| A3 | `withdraw`/`borrow` pay `msg.sender`; `supply`/`repay` pull from `msg.sender`; caller must be `onBehalfOf` or an approved active manager | `IAaveV4Spoke.sol:97-128`, `05-position-proxy-and-proxy-manager.md` | `ISpoke.sol#L480-L539` (natspec), `AV4/src/spoke/Spoke.sol#L909-L913` | CONFIRMED | — |
| A4 | Spoke events `Supply`, `Withdraw`, `Borrow`, `Repay`, `LiquidationCall` (11 fields), `ReportDeficit`, `SetUsingAsCollateral` | `IAaveV4SpokeEvents.sol:12-73` | `ISpoke.sol#L197-L297` | CONFIRMED | Canonical Spoke only; see AMMN-INT-04 for the variant's event |
| A5 | `extSload(bytes32)` is inherited by the Spoke | `IAaveV4ExtSload.sol:15` | `ISpoke.sol#L15` (`is ... IExtSload`) | CONFIRMED | — |
| A6 | `IAaveV4Hub`: `PremiumDelta`, `AssetConfig`, `SpokeConfig`; `add`, `remove`, `eliminateDeficit`, every getter and constant; events `Add`, `Remove`, `ReportDeficit`, `EliminateDeficit` | `IAaveV4Hub.sol:15-231` | `AV4/src/hub/interfaces/IHubBase.sol#L12-L335`, `AV4/src/hub/interfaces/IHub.sol#L59-L422` | CONFIRMED | — |
| A7 | `IAaveV4Oracle`: `decimals()`, `getReservePrice(reserveId)`, `getReserveSource(reserveId)`; `IAaveV4PriceFeed`: `decimals()`, `description()`, `latestAnswer() → int256` with no reserve argument | `IAaveV4Oracle.sol:14-28`, `IAaveV4PriceFeed.sol:12-21` | `AV4/src/spoke/interfaces/IPriceOracle.sol#L16-L22`, `IAaveOracle.sol#L67`, `IPriceFeed.sol#L9-L15` | CONFIRMED | — |
| A8 | Liquidation-manager Spoke: canonical 5-argument `liquidationCall` runs the canonical body for `LIQUIDATION_MANAGER`; getters `APPROVED_DEBT_RESERVES()`, `isApprovedDebtReserve()` "replace that variant's single debt-reserve getter" | `IAaveV4Spoke.sol:8-16, 130-142, 269-288`; `01-avana-hub-and-spokes.md:285-295` (`REQ-HUB-092…095`) | `AV4V/src/spoke/` variant Spoke L58-L66 (5-arg overload is `pure` and always reverts `UnsupportedLiquidationCall()`), variant interface L56-L67 (4-arg `liquidationCall(debtReserveId, debtToCover, user, maxCollateralToRemove) returns (uint256, uint256)`), getter is `MANAGED_COLLATERAL_RESERVE_ID()`, no debt-reserve getter | **WRONG** | AMMN-INT-04 |
| A9 | `ICoverageSpoke` is an Avana-specified contract; `fund` → `HUB.add`, `coverDeficit` → `HUB.eliminateDeficit` | `ICoverageSpoke.sol:78-104` | No Aave source; Hub side checked in B7-B9 | UNVERIFIABLE | No upstream contract exists. Verify with a fork test that deploys it on the pinned Hub, grants `HUB_DEFICIT_ELIMINATOR_ROLE`, registers it with `drawCap = 0`, and covers a deficit created by a real `liquidationCall` |

## 2. Aave V4 mechanics

| # | Assumption | Spec location | Source evidence | Status | Impact and fix |
|---|---|---|---|---|---|
| B1 | Health factor `= floor(Σ V_m × CF_m (bps→WAD) × RAY / Σ debtRay-value)`; collateral `V = previewRemoveByShares(shares) × price × 10^(18−d)`; `type(uint256).max` with no debt | `06-aave-adapter.md:238` (`SPEC-PROXY-006`) | `AV4/src/spoke/Spoke.sol#L706-L783`; `AV4/src/spoke/libraries/SpokeUtils.sol#L34-L40` | CONFIRMED | Aave values debt at full RAY precision (`drawnShares × drawnIndex + premiumDebtRay`), not rounded base units; the spec already says gates read Aave's value |
| B2 | Oracle decimals fixed at 8; Value unit 1e26 = $1 | `06-aave-adapter.md:232` | `Spoke.sol#L99`, `SpokeUtils.sol#L13` | CONFIRMED | — |
| B3 | AaveOracle has no staleness check; reverts only on unset source or `price ≤ 0`; `setReserveSource` requires matching decimals | EXT-003 `03-external-dependencies.md:36` | `AV4/src/spoke/AaveOracle.sol#L44-L88` | CONFIRMED | — |
| B4 | Bonus: `minLB = 10_000 + floor((maxLB − 10_000) × factor / 10_000)`; linear above `healthFactorForMaxBonus`, floored; `percentMulUp(maxLB, CF) < 10_000` enforced | `01-avana-hub-and-spokes.md:125-127` (`SPEC-HUB-005`) | `AV4/src/spoke/libraries/LiquidationLogic.sol#L312-L333`; `Spoke.sol#L921-L930` | CONFIRMED | Worked value 10,290 at `h = 0.97` reproduces |
| B5 | Close factor: debt taken restores `targetHealthFactor`; dust rule `DUST_LIQUIDATION_THRESHOLD = 1000e26` ($1,000) forces full liquidation | EXT-002 `:26`; `11-lpvaultswap.md:17` | `LiquidationLogic.sol#L185`, `#L775-L813` | CONFIRMED (canonical Spoke) | Not true on the existing variant: AMMN-INT-04 |
| B6 | `liquidationCall` checks: self-liquidation, `debtToCover > 0`, collateral and debt reserves not paused, supplied shares > 0, HF < 1, `CF > 0 && usingAsCollateral`; frozen blocks only `receiveShares = true`; CF 0 makes collateral unseizable | EXT-002 `:27-28`; `01:238-241` | `LiquidationLogic.sol#L533-L559` | CONFIRMED | — |
| B7 | Deficit reported only inside `liquidationCall` when the single active collateral is emptied and debt remains; `reportDeficit` for every borrowed reserve | `01:227` (`REQ-HUB-055`) | `LiquidationLogic.sol#L260-L303`, `#L816-L826`; `AV4/src/hub/Hub.sol#L304-L330` | CONFIRMED | — |
| B8 | `eliminateDeficit` is `restricted`, burns the caller Spoke's added shares, covers `min(amount, ceil(deficitRay/RAY))`; Hub does not check which Spoke's deficit is covered | EXT-004 `:46`; `ICoverageSpoke.sol:89-104` | `Hub.sol#L333-L359`, `#L889-L895` | CONFIRMED | Caller must be an active Spoke listed for that asset |
| B9 | `Hub.add` requires the tokens already in the Hub (`balance ≥ liquidity + amount`), active, not halted, within `addCap` | `ICoverageSpoke.sol:79-81` | `Hub.sol#L200-L221`, `#L814-L829` | CONFIRMED | Any active Spoke can claim stray Hub balance; `fund` must transfer and add in one call, as specified |
| B10 | A Hub halt "stops everything except fee collection" | EXT-001 `03-external-dependencies.md:18` | `Hub.sol#L875-L898`: `_validateReportDeficit`, `_validateEliminateDeficit`, `_validatePayFeeShares` check only `active`; `refreshPremium` checks only `active` (`#L362-L373`) | **WRONG** | AMMN-INT-08 |
| B11 | Shares: `toSharesDown/Up` with 1e6 virtual assets and shares; supply shares `= floor(amount × (S+1e6)/(A+1e6))`; equal to `amount` while A = S | `01:137` (`SPEC-HUB-008`) | `AV4/src/hub/libraries/SharesMath.sol#L8-L55` | CONFIRMED | — |
| B12 | Vault-token asset has `addedShares == addedAssets` when `drawCap = 0`, `liquidityFee = 0`, no reinvestment controller | EXT-001 `:17` | `AV4/src/hub/libraries/AssetLogic.sol#L79-L96` (`liquidity + owed − …`, no balance read) | CONFIRMED | Donations to the Hub do not change the ratio |
| B13 | Caps are whole tokens (`cap × 10^decimals`), `type(uint40).max` = no cap; drawCap counts drawn + premium + deficit; Hub decimals 6..18 | `IAaveV4Hub.sol:32`; `07-risk-module.md:152` | `Hub.sol#L38`, `#L54-L60`, `#L824-L855` | CONFIRMED | — |
| B14 | `riskPremiumThreshold`: `premiumShares ≤ percentMulUp(drawnShares, threshold)` checked on every premium change; a too-low threshold makes repay and liquidation revert `InvalidPremiumChange` | `01:122` | `Hub.sol#L757-L762` | CONFIRMED | — |
| B15 | Frozen collateral does not block `borrow` | EXT-002 `:27` | `Spoke.sol#L282`, `#L871-L876` | CONFIRMED | — |
| B16 | `MAX_USER_RESERVES_LIMIT` counts collateral and borrow reserves separately and is set by the DAO at deployment; Avana sets no markets-per-account bound | `01:182` (`REQ-HUB-025`); `07:135` (`REQ-RISK-008`) | Canonical: `ISpoke.sol#L785-L786`. Existing variant: `uint16 internal constant USER_RESERVES_LIMIT = 1` passed to `Spoke(oracle_, USER_RESERVES_LIMIT)` (`AV4V/src/spoke/` variant Spoke L12-L20) | **WRONG** (for the only liquidation-manager Spoke in Aave's repo) | AMMN-INT-04 |
| B17 | `liquidationFee` taken as Hub shares through `payFeeShares` to the asset's fee receiver; a variant can reject non-zero fees in `_validateDynamicReserveConfig` | `01:288` (`REQ-HUB-093`) | `LiquidationLogic.sol#L479-L482`, `#L690-L694`; variant L141-L146 (`require(config.liquidationFee == 0, UnsupportedLiquidationFee())`) | CONFIRMED | — |
| B18 | At `455a406` the only `Spoke.sol` change from the pin is `virtual`/`public` markers | `01:285` | GitHub compare `a3ef63e...455a406`: `src/spoke/Spoke.sol` +32/−27, all visibility/`virtual` changes; 455a406 is 49 ahead, 1 behind (non-`src` commit) | CONFIRMED | "Canonical `SpokeInstance` byte-identical" is UNVERIFIABLE without a build: compile `SpokeInstance` at both commits with the pinned `foundry.toml` and compare runtime bytecode |
| B19 | Variant applies its borrowable check "against a single debt reserve ID" | `01:285` | Variant checks `reserveId != MANAGED_COLLATERAL_RESERVE_ID || !borrowable` (variant L150-L155) — the single ID is the collateral reserve | **WRONG** (description) | Folded into AMMN-INT-04 |
| B20 | Aave's fixed $1 GHO price source on the Borrow Spoke | EXT-003 `:36` | No fixed GHO feed in `aave-v4` `src/`; mainnet V4 GHO source not in the address book | UNVERIFIABLE | Fork test: read `AaveOracle.getReserveSource(ghoReserveId)` on a mainnet V4 Spoke that lists GHO and assert `latestAnswer() == 1e8` and no owner/upgrade path |

## 3. Uniswap v3 and Slipstream

| # | Assumption | Spec location | Source evidence | Status | Impact and fix |
|---|---|---|---|---|---|
| C1 | `INonfungiblePositionManager` structs and `positions`, `mint`, `increaseLiquidity`, `decreaseLiquidity`, `collect` | `uniswap/INonfungiblePositionManager.sol` | `V3P/interfaces/INonfungiblePositionManager.sol`; `V3P/NonfungiblePositionManager.sol#L128-L379` | CONFIRMED | — |
| C2 | `increaseLiquidity` permissionless; `decreaseLiquidity`, `collect`, `burn` need owner/approval | EXT-006 `:69` | `NonfungiblePositionManager.sol#L198` (no modifier), `#L261`, `#L313`, `#L377` (`isAuthorizedForToken`) | CONFIRMED | — |
| C3 | `decreaseLiquidity` principal rounds down; adds principal plus accrued fees to `tokensOwed`; `collect` pays `min(max, tokensOwed)`, so a principal-capped collect leaves fees owed | `02-lp-vault.md:85, 92` (`REQ-VAULT-149/161`) | `NonfungiblePositionManager.sol#L265-L300`, `#L330-L360`; `V3C/libraries/SqrtPriceMath.sol#L201-L230` (negative liquidity → `roundUp = false`) | CONFIRMED | `decreaseLiquidity` requires `liquidity > 0` (`#L265`) and `collect` requires a non-zero max (`#L316`); the spec skips `collect` when both amounts are 0, so callers must also never pass 0 liquidity |
| C4 | Fee growth to `tokensOwed` via `mulDiv(Δgrowth, liquidity, Q128)`, rounded down | `02-lp-vault.md:106` | `NonfungiblePositionManager.sol#L281-L300` | CONFIRMED | — |
| C5 | Approvals cleared on transfer; `permit` checks the current owner, ERC-1271 for contracts; `mint` uses `_mint` (no `onERC721Received`) | EXT-006 `:69` | `NonfungiblePositionManager.sol#L156`, `#L389-L399`; `V3P/base/ERC721Permit.sol` (`isContract(owner)` → `isValidSignature`) | CONFIRMED | — |
| C6 | `slot0()` has 7 fields incl. `feeProtocol`; `unlocked` is false during a swap | `uniswap/IUniswapV3Pool.sol`; EXT-007 `:78` | `V3C/UniswapV3Pool.sol#L104-L108`, `#L607-L615`, `#L787` | CONFIRMED | — |
| C7 | `observe` reverts `OLD` when the window exceeds stored observations, so cardinality must cover `twapWindow` | EXT-007 `:79` | `V3C/libraries/Oracle.sol#L226` | CONFIRMED | — |
| C8 | Slipstream `slot0` has a different layout | proposal "Launch integrations" | `SS/core/interfaces/pool/ICLPoolState.sol#L18-L28` (6 fields, no `feeProtocol`) | CONFIRMED | Decoding through `IUniswapV3Pool` reverts on short return data; needs its own interface (details in `amm-integration-facts.md` §4) |
| C9 | Slipstream NFT manager and factory differ: `tickSpacing` in place of `fee` | proposal | `SS/periphery/interfaces/INonfungiblePositionManager.sol#L67-L83` (`int24 tickSpacing` at the `fee` slot); `SS/core/interfaces/ICLFactory.sol#L118` `getPool(a, b, int24 tickSpacing)` | CONFIRMED | `positions()` decodes through the Uniswap ABI without reverting and returns `tickSpacing` as `fee`; a shared reader must branch by AMM protocol, never by ABI success |

## 4. Chainlink

| # | Assumption | Spec location | Source evidence | Status | Impact and fix |
|---|---|---|---|---|---|
| D1 | Every primary leg has a heartbeat ≤ 3,600 s, so `borrowPriceMaxAge = min(heartbeat + 600, 4,200)` holds; a primary above 3,600 s is not listable | EXT-008 `:91-93`; EXT-020 `:111`; EXT-024 `:121`; `10-lp-oracle.md:305` (`REQ-ORACLE-054`); `06-aave-adapter.md:245` | `RDD/feeds-mainnet.json`: USDC/USD `0x8fFfFfd4…18f6` heartbeat 82,800 s, USDT/USD `0x3E7d1eAB…e32D` 86,400 s, GHO/USD `0x3f12643D…77FC` 86,400 s, USDS/USD 82,800 s; only DAI/USD is 3,600 s. Live at block 26,383,651: USDC/USD age 13,500 s, USDT/USD 67,704 s, GHO/USD 44,220 s | **WRONG** | AMMN-INT-01 |
| D2 | Base: all stable legs are 86,400 s; ETH/USD 1,200 s | proposal (Slipstream on Base) | `RDD/feeds-ethereum-mainnet-base-1.json` | CONFIRMED (fact) | Same failure as D1 on Base |
| D3 | No L2 sequencer check is needed | spec has no sequencer rule (grep of `docs/spec/` finds none); proposal puts Slipstream on Base at launch | Base L2 Sequencer Uptime feed `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` (`RDD/feeds-ethereum-mainnet-base-1.json`) | **WRONG** | AMMN-INT-06 |
| D4 | Round IDs `(phaseId << 64) | aggregatorRoundId`; `phaseAggregators(uint16)` is public and keeps past phases | EXT-025 `:131` | `chainlink-evm/4d83db2/contracts/src/v0.6/data-feeds/AggregatorProxy.sol#L21-L25`, `#L355-L415` | CONFIRMED | — |
| D5 | A new phase starts its round IDs at 1 | EXT-025 `:131` | Depends on aggregator type, not the proxy | UNVERIFIABLE | Fork test: for each listed leg, walk `phaseAggregators(phaseId())` and assert `getRoundData((phaseId << 64) | 1)` returns a non-zero `updatedAt` |
| D6 | `minAnswer`/`maxAnswer` readable and meaningful | EXT-008 `:89`; `10-lp-oracle.md:141` | Live: USDC/USD and USDT/USD aggregators `minAnswer = 1`, `maxAnswer = 1.05e8`; GHO/USD `maxAnswer ≈ 9.6e52` | CONFIRMED | A $1.05 upper bound on USDC/USDT makes a de-peg upward read Invalid; `minAnswer = 1` gives no lower guard. The spec's own band check must carry the lower bound |
| D7 | Deviation thresholds as published | EXT-008 `:91` | USDC/USD 0.25%, USDT/USD 0.25%, GHO/USD 0.5%, DAI/USD 0.25% (`RDD`) | CONFIRMED | Listing margin `(1 − CF)` must exceed these |

## 5. GHO, GSM, Sky, Curve

| # | Assumption | Spec location | Source evidence | Status | Impact and fix |
|---|---|---|---|---|---|
| E1 | `flashLoan` fee 0 for `isFlashBorrower(msg.sender)`; `maxFlashLoan = capacity − level`; `onFlashLoan(initiator = msg.sender, …)` | EXT-011 `:153`; EXT-012 `:163` | `GC/src/contracts/facilitators/flashMinter/GhoFlashMinter.sol#L68-L122` | CONFIRMED | `flashFee` checks the caller of `flashFee`, so a Lens read returns the public fee, not LPVaultSwap's |
| E2 | FlashMinter `0xb639…62B8`; bucket covers the largest liquidation | EXT-011 `:151-153` | `AB/GhoEthereum.sol#L14-L16`; live `getFee() = 0`, `maxFlashLoan = 2,000,000 GHO`, level 0 | CONFIRMED | Equal to `creditLineGho`; a non-GHO debt buy leg plus a GHO liquidation in one block share it |
| E3 | `IGhoFlashMinter.FlashMint` event and `flashLoan` signature | `gho/IGhoFlashMinter.sol:21-40` | `GC/src/contracts/facilitators/flashMinter/interfaces/IGhoFlashMinter.sol` | CONFIRMED | — |
| E4 | GHO FlashMinter (and GSM) used for every liquidation, including on Base | proposal "Liquidation (decided)" step 1 | `AB/GhoBase.sol#L7-L22`: token, CCIP pool and stewards only; no FlashMinter, no GSM | **WRONG** | AMMN-INT-05 |
| E5 | GSM USDC `0xFeeb…9535`, GSM USDT `0x535b…6B7B` (address book `cd30f7e4`) | EXT-013 `:173` | `AB/GhoEthereum.sol#L38-L41` now lists `0x3A38…4112` and `0x8822…E5F3`. Live: `0xFeeb…` and `0x535b…` `getIsSeized() = true`, `getExposureCap() = 0`, available liquidity 0 | **WRONG** | AMMN-INT-02 |
| E6 | GSM underlying is the static aToken wrapper | EXT-013 `:173` | Live `UNDERLYING_ASSET()`: `waEthUSDC 0xD4fa…D23E`, `waEthUSDT 0x7Bc3…3Af8`; `getGhoAmountForSellAsset(1e6) = 1.193 GHO` | CONFIRMED | One wrapper unit is worth ~1.19 USDC; every GSM leg must wrap and size in wrapper units |
| E7 | GSM `buyAsset` has underlying liquidity for a USDC debt buy | EXT-013 `:175`; EXT-021 `:205` | Live GSM USDC `getAvailableLiquidity() = 29,227` (0.029 waEthUSDC); GSM USDT 29.5M | **WRONG** (current state) | AMMN-INT-03 |
| E8 | GSM interface (`sellAsset`, `buyAsset`, `getGhoAmountFor*`, freeze/seize getters) works on the live GSMs | `gho/IGsm.sol` | Live calls on `0x3A38…4112` succeed with the vendored selectors | CONFIRMED | Interface is pinned to `gho-core`; the live GSMs come from `aave-dao/gho-origin`. Re-pin the comment |
| E9 | GSM freezes when USDC leaves ~0.99 | EXT-013 `:175` | Oracle swap freezer config not read | UNVERIFIABLE | Fork test: read `GSM_USDC_ORACLE_SWAP_FREEZER` freeze/unfreeze bounds and assert the value in the listing |
| E10 | LitePSM `buyGem(usr, gemAmt) → daiInWad`, `tout()`; DAI–USDS `usdsToDai(usr, wad)` | `sky/ILitePsm.sol`, `sky/IDaiUsds.sol` | Addresses not pinned in the spec | UNVERIFIABLE | Fork test against the addresses chosen in the route config |
| E11 | Curve StableSwap-NG `exchange(int128, int128, uint256, uint256)` exists | `curve/ICurveStableSwapNG.sol` | NG `exchange` has a defaulted `_receiver`, so Vyper emits both the 4- and 5-argument selectors | CONFIRMED | — |

## 6. Proposal-level integration claims

| # | Assumption | Spec location | Source evidence | Status | Impact and fix |
|---|---|---|---|---|---|
| F1 | A Spoke reserve can point at any `(Hub, assetId)`, so a Volatile CDP Spoke can borrow USDC funded by the Stable Hub under its own `drawCap` | proposal "Instance scope"; EXT-022 | `ISpoke.sol#L431-L437` (`addReserve(hub, assetId, …)`), `#L659` (`getReserveId(hub, assetId)`); caps per `(asset, spoke)` `IHub.sol#L94-L100` | CONFIRMED | — |
| F2 | One Coverage Spoke per funding Hub × debt asset can cover deficits there | proposal; EXT-004 | `Hub.sol#L333-L359` (caller must be a listed active Spoke of that asset on that Hub) | CONFIRMED | — |
| F3 | Standard Spoke with public `liquidationCall` plus a transfer-restricted vault token makes LPVaultSwap the only settler | proposal "Liquidation (decided)", open point | `LiquidationLogic.sol#L465-L466` (`receiveShares = true` credits Spoke shares, no token transfer), `#L479-L482` (fee shares via `payFeeShares`, no transfer) | **WRONG** (as stated) | AMMN-INT-07 |
| F4 | One LP market per CDP Spoke; two markets → two proxies and two health factors | proposal "Instance scope" | Matches the existing variant (`MANAGED_COLLATERAL_RESERVE_ID`, user limit 1) | CONFIRMED | This is the only design the existing Aave variant supports; the "vault holds multiple approved markets" variant conflicts with it |

## Findings

### AMMN-INT-01 — Stablecoin Chainlink heartbeats are 23–24 h, not ≤ 1 h (Critical)

- **Wrong assumption.** `REQ-ORACLE-054` requires every primary leg to have `feedHeartbeat ≤ 3,600` s, and the launch age limit is `borrowPriceMaxAge = 4,200` s. On Ethereum, USDC/USD heartbeat is 82,800 s, USDT/USD 86,400 s, GHO/USD 86,400 s and USDS/USD 82,800 s; on Base every stable feed is 86,400 s. Calm stable feeds update only on the 0.25% deviation trigger or the heartbeat. At block 26,383,651 the USDC/USD round was 13,500 s old and USDT/USD 67,704 s old.
- **Impact.** The launch market (USDC/USDT) cannot be listed under `REQ-ORACLE-054`. If the check is relaxed but the 4,200 s age limit is kept, the LPOracle and the USDC DebtOracle are not Live for most of every day, so borrowing and withdraw-with-debt stop. Past `feedMaxAge` the market goes Cached and then Expired, which changes liquidation pricing. The `SPEC-PROXY-002` example (`4,300 s` called stale) describes the normal state of these feeds.
- **Fix.** Make age limits per feed, derived from the published heartbeat (`feedMaxAge = heartbeat + buffer`), and drop `MAX_PRIMARY_HEARTBEAT = 3,600`. For a stable feed whose answer only moves on deviation, the risk bound is deviation plus heartbeat drift, not age: keep the listing margin `(1 − CF) > deviation + drift` and size `minOpeningHealthFactor` against the 0.25% band. Re-derive `INV-023/030/031/055/056`, `SPEC-ORC-013/015` and the worked examples with 86,400 s legs, and re-run the Z3 models that use 3,600 s.
- **Verification.** Fork test at the pinned block range: for each launch leg (USDC/USD, USDT/USD, GHO/USD, DAI/USD, USDS/USD), sample `latestRoundData()` at 500 random blocks over 30 days, assert `max(age) ≤ heartbeat + buffer`, and assert `LPOracle.getPriceState()` is Live at every sampled block with the new limits. A unit test asserts `ParameterStore.setFeed` accepts a 86,400 s primary.

### AMMN-INT-02 — GSM addresses in EXT-013 are seized (High)

- **Wrong assumption.** EXT-013 names GSM USDC `0xFeeb6FE430B7523fEF2a38327241eE7153779535` and GSM USDT `0x535b2f7C20B9C83d70e519cf9991578eF9816B7B` from address book `cd30f7e4`. Both now return `getIsSeized() = true`, `getExposureCap() = 0` and zero liquidity. The current address book lists GSM USDC `0x3A3868898305f04beC7FEa77BecFf04C13444112` and GSM USDT `0x882285E62656b9623AF136Ce3078c6BdCc33F5E3` (backed by `GhoReserve`).
- **Impact.** Every USDC or USDT sell leg and every GSM buy route reverts. A liquidation whose recovery depends on the GSM falls back to DEX routes or in-kind settlement.
- **Fix.** Update the address-book pin and EXT-013; re-pin `IGsm` to `aave-dao/gho-origin`. Route approval and the route health check must require `!getIsSeized() && !getIsFrozen() && getExposureCap() > 0`.
- **Verification.** Mainnet fork test: for each GSM in the route config, assert `UNDERLYING_ASSET()` is the expected wrapper, not seized, cap > 0, and that `sellAsset` of 1,000 USDC worth of wrapper returns GHO within the fee bound.

### AMMN-INT-03 — GSM USDC has no buy-side liquidity (Medium)

- **Wrong assumption.** EXT-021 uses GSM `buyAsset` as the primary buy route for a USDC debt reserve. The live GSM USDC holds 29,227 wrapper base units (≈ $0.03) available to buy; GSM USDT holds 29.5M.
- **Impact.** Liquidation of USDC debt through the primary route fails until the GSM holds USDC; every such liquidation uses the backup route and its slippage.
- **Fix.** Make the buy-route depth check read `getAvailableLiquidity()` (in wrapper units, converted at the wrapper rate) and fall over to the backup when below `debtToCover`; or use a DEX route as primary for USDC.
- **Verification.** Fork test: `buyExactOut(10,000e6 USDC)` through the GSM route at the current block reverts or falls over; through the backup it delivers exactly `debtToCover`.

### AMMN-INT-04 — The liquidation-manager Spoke in Aave's repository is not the one Avana's interface calls (High)

- **Wrong assumption.** `IAaveV4Spoke` and `REQ-HUB-092…095` assume a Borrow Spoke whose 5-argument `liquidationCall` runs the canonical liquidation for `LIQUIDATION_MANAGER`, with several collateral reserves per account, a DAO-set user reserve limit, an `APPROVED_DEBT_RESERVES` bitmap and canonical target-HF and dust sizing. The only such Spoke in `aave/aave-v4` (newest at `455a406`) instead:
  - reverts the 5-argument `liquidationCall` unconditionally (`UnsupportedLiquidationCall()`), and exposes `liquidationCall(debtReserveId, debtToCover, user, maxCollateralToRemove) returns (uint256 liquidationBonus, uint256 collateralAmountRemoved)`;
  - hard-codes `USER_RESERVES_LIMIT = 1` and one `MANAGED_COLLATERAL_RESERVE_ID` per Spoke;
  - repays premium first with no target-HF sizing, no dust rule and no liquidation fee, capped by `maxCollateralToRemove`;
  - emits its own 9-field liquidation event (no `receiveShares`, no `collateralSharesToLiquidator`), not `LiquidationCall`;
  - has no debt-reserve getter; the single ID it validates is the collateral reserve. The `IAaveV4Spoke` natspec ("replace that variant's single debt-reserve getter") and `01:285` ("against a single debt reserve ID") misdescribe it.
- **Impact.** Avana's required Spoke exists in no Aave source. LPVaultSwap built against `IAaveV4Spoke` cannot liquidate on the existing variant; the multi-market account in `06-aave-adapter.md` (markets A and B on one Spoke, GHO and USDC debt) is impossible on it. Launch depends on Aave Labs writing and auditing new Spoke code.
- **Fix.** Pick one: (a) adopt the existing variant. This matches the proposal's "one LP market per CDP Spoke". Add the 4-argument call and its event to `IAaveV4Spoke`, size seizures in LPVaultSwap with `maxCollateralToRemove`, and drop the target-HF and dust assumptions (`REQ-ARCH-007`, `SPEC-HUB-005` sizing, `11-lpvaultswap.md:17`). Allow one debt reserve per account per Spoke. (b) Keep the spec, but record it as a request to Aave Labs, mark every dependent requirement blocked until a commit exists, and correct the two descriptions.
- **Verification.** Fork test built from `455a406`: deploy the variant Spoke instance with `LIQUIDATION_MANAGER = LPVaultSwap`; assert (1) the 5-argument call from the manager reverts `UnsupportedLiquidationCall()`, (2) `MAX_USER_RESERVES_LIMIT() == 1`, (3) enabling a second collateral reserve reverts `UnsupportedCollateralReserve()`, (4) the 4-argument call with `maxCollateralToRemove` seizes at most that amount and reports the bonus, (5) a position with debt below $1,000 is partially liquidated (no dust rule).

### AMMN-INT-05 — No GHO FlashMinter or GSM on Base (High)

- **Wrong assumption.** The proposal's liquidation flow flash-mints GHO and converts through GHO routes for every CDP Spoke, including Aerodrome Slipstream on Base.
- **Evidence.** `aave-address-book` `src/GhoBase.sol` lists only the GHO token (CCIP burn/mint), its token pool and stewards. Details and Base flash-liquidity options are in `amm-integration-facts.md` §3.
- **Impact.** Step 1 of the liquidation flow cannot run on Base; LPVaultSwap on Base has no funding source as specified.
- **Fix.** Make the funding source per chain (a capped flash loan from an existing pool, or caller-funded only), with its own cap and fee in the ParameterStore, and size Base caps to that liquidity.
- **Verification.** Base fork test: liquidate a Slipstream-backed position end to end with the chosen funding source at the largest cap-allowed size; assert repayment and fee settle in one transaction.

### AMMN-INT-06 — No L2 sequencer uptime check (High, Base)

- **Wrong assumption.** The spec has no sequencer rule. Base has the Chainlink L2 Sequencer Uptime feed `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`.
- **Impact.** After a Base sequencer outage, feeds resume with stale rounds while only some users can transact through the L1 inbox; borrows sized on pre-outage prices and liquidations at the first post-outage price are both unsafe.
- **Fix.** On L2 deployments, the LPOracle and DebtOracle read the uptime feed: if `answer == 1` (down) or `now − startedAt < sequencerGracePeriod`, the price state is not Live for borrow. Liquidation follows the existing grace-latch rule, extended to sequencer recovery.
- **Verification.** Base fork test with a mocked uptime feed: down → borrow reverts; up for less than the grace period → borrow reverts, repay passes; after the grace period → borrow passes.

### AMMN-INT-07 — Transfer restriction alone does not make LPVaultSwap the only settler (Medium)

- **Wrong assumption.** On a standard Spoke, a transfer-restricted vault token ensures only LPVaultSwap can receive seized collateral.
- **Evidence.** `liquidationCall(..., receiveShares = true)` credits the liquidator Spoke supply shares with no ERC-20 transfer (`LiquidationLogic.sol#L465-L466`); fee shares move by `payFeeShares` with no transfer (`#L479-L482`). The restriction holds only while `receiveSharesEnabled == false` (or the reserve is frozen) and `liquidationFee == 0` on every key. Both are DAO-set reserve config.
- **Impact.** One DAO config change lets any liquidator seize vault-token shares without Avana's ledger debit, breaking `INV-014` (backing equals supply).
- **Fix.** Keep a liquidation-manager Spoke (AMMN-INT-04), or add `receiveSharesEnabled == false` and `liquidationFee == 0` on every vault reserve key to the AIP's required settings and to the RiskModule drift check. The drift check cannot stop a liquidation in the same block, so state the residual risk.
- **Verification.** Fork test on a canonical Spoke: set `receiveSharesEnabled = true`, liquidate from a third party with `receiveShares = true`, and assert the seizure succeeds with no vault-token transfer and the Collateralization ledger is not debited (the test documents the failure).

### AMMN-INT-08 — Hub halt scope is understated (Info)

- **Wrong assumption.** EXT-001 says a Hub halt of the Spoke "stops everything except fee collection".
- **Evidence.** `reportDeficit`, `eliminateDeficit`, `payFeeShares` and `refreshPremium` check only `active` (`Hub.sol#L362-L373`, `#L875-L898`).
- **Impact.** None to safety. A non-halted Coverage Spoke can still eliminate the halted Borrow Spoke's deficit, and the DAO position updater can still refresh premiums.
- **Fix.** Reword: a halt stops add, remove, draw, restore and share transfers (so supply, withdraw, borrow, repay and liquidation); deficit coverage, premium refresh and fee shares continue.
- **Verification.** Fork test: halt the Borrow Spoke on the GHO asset, then call `ICoverageSpoke.coverDeficit` on an existing deficit; assert success.

## Unverifiable items and how to close them

| # | Item | Test |
|---|---|---|
| A9 | Coverage Spoke against the pinned Hub | Deploy, grant `HUB_DEFICIT_ELIMINATOR_ROLE`, cover a real liquidation deficit |
| B18 | Canonical `SpokeInstance` byte-identical at both commits | Build both with the pinned `foundry.toml`, compare runtime bytecode |
| B20 | Fixed GHO price source on V4 | Read `getReserveSource` on a mainnet V4 GHO reserve; assert constant `1e8` and no admin |
| D5 | Phase round IDs start at 1 | Walk `phaseAggregators` per listed leg; read round 1 |
| E9 | GSM freeze band | Read the oracle swap freezer bounds on the live GSMs |
| E10 | LitePSM and DAI–USDS converter | Fork test against the addresses in the route config |
