// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapViews} from "../../liquidation/lp-vault-swap/ILPVaultSwapViews.sol";
import {SettlementMath} from "../../liquidation/lp-vault-swap/SettlementMath.sol";
import {LiquidationParams} from "../../liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {RouteMode} from "../../liquidation/lp-vault-swap/types/RouteMode.sol";
import {IDebtOracle} from "../../oracle/debt-oracle/IDebtOracle.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {IAaveAdapterViews} from "../../policy/aave-adapter/IAaveAdapterViews.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {Market} from "../../types/Market.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {LensBase} from "./LensBase.sol";
import {LensConstants} from "./LensConstants.sol";
import {LensLiquidationSizing} from "./LensLiquidationSizing.sol";
import {LiquidationPreview} from "./types/LiquidationPreview.sol";
import {PriceInput} from "./types/PriceInput.sol";
import {RouteStatus} from "./types/RouteStatus.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensLiquidation
/// @notice The liquidation preview: every gate as LPVaultSwap evaluates it, Aave's own sizing of the repayment and the
/// seizure, ready-to-send `LiquidationParams` with the inclusion margin, and the expected recovery floor, payout and
/// caller loss in the debt asset.
/// @dev Advisory: LPVaultSwap recomputes and enforces every check on execution and Aave sizes the seizure inside
/// `liquidationCall`. Gates read fresh prices only for the seized market and the repaid reserve.
/// @custom:spec REQ-LENS-016, REQ-LENS-017, REQ-LENS-028, REQ-LENS-029, REQ-LENS-032, REQ-LENS-033, Q-232, Q-247, Q-268, Q-404
// View calls in loops over listings bounded by governance (Spokes, debt reserves, markets, pool tokens), one
// page of at most LENS_MAX_PAGE records or the caller's own arrays (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
abstract contract LensLiquidation is LensBase {
    /// @dev Aave's `HEALTH_FACTOR_LIQUIDATION_THRESHOLD`, WAD.
    uint256 internal constant LIQUIDATION_THRESHOLD = 1e18;

    /// @dev Aave's `DUST_LIQUIDATION_THRESHOLD`, $1,000 in Aave value units (USD × 1e26).
    uint256 internal constant DUST_LIQUIDATION_THRESHOLD = 1000e26;

    /// @dev `LensAaveSizing`: Aave's pinned liquidation sizing, built with Aave's settings.
    address internal immutable _AAVE_SIZING;

    /// @dev Everything the preview reads about the account once.
    struct Ctx {
        Market m;
        DebtReserveDef def;
        address spoke;
        uint256 total;
        uint256 debtPriceAave;
        uint8 debtDecimals;
    }

    /// @notice Fixes the Aave sizing contract.
    /// @param sizing `LensAaveSizing`.
    /// @custom:spec REQ-LENS-017
    constructor(
        address sizing
    ) {
        if (sizing == address(0)) revert InvalidModules();
        _AAVE_SIZING = sizing;
    }

    /// @notice Returns `LensAaveSizing`, the pinned Aave V4 liquidation sizing the preview calls.
    /// @return sizing Constructor immutable.
    /// @custom:spec REQ-LENS-017
    function AAVE_SIZING() external view returns (address sizing) {
        sizing = _AAVE_SIZING;
    }

    /// @notice `ILensLiquidation.previewLiquidation`: every liquidation gate, Aave's sizing and ready-to-send
    /// `LiquidationParams` for one account and debt reserve, with the expected seizure, floor, payouts and caller loss.
    /// @custom:spec REQ-LENS-016, REQ-LENS-017, REQ-LENS-028, REQ-LENS-029, REQ-LENS-032, REQ-LENS-033, REQ-LENS-005, REQ-LENS-006, REQ-LENS-007
    function previewLiquidation(
        address proxy,
        uint256 debtReserveId,
        uint256 deadline
    ) external view returns (LiquidationPreview memory p) {
        _unlocked();
        Ctx memory c = _context(p, proxy, debtReserveId);
        _accountGates(p, c);
        _priceGates(p, c);
        LensLiquidationSizing.Sizing memory s =
            LensLiquidationSizing.size(_AAVE_SIZING, c.spoke, proxy, c.m.reserveId, debtReserveId);
        p.expectedDebtRepaid = s.debtRepaid;
        p.expectedUnitsSeized = s.unitsSeized;
        _params(p, c, s, deadline);
        _expected(p, c);
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev Resolves the proxy's market and the debt reserve and fills the identity and Aave account fields.
    /// @custom:spec REQ-LENS-016, REQ-LENS-032, REQ-LENS-033
    function _context(
        LiquidationPreview memory p,
        address proxy,
        uint256 debtReserveId
    ) internal view returns (Ctx memory c) {
        // forge-lint: disable-next-line(unused-return)
        (address spoke, uint256 marketId, address vaultToken,) = IAaveAdapterViews(_ADAPTER).accountOf(proxy);
        if (vaultToken == address(0) || !IVaultToken(vaultToken).isValidProxy(proxy)) revert UnknownProxy(proxy);
        c.spoke = spoke;
        c.def = _debtReserve(spoke, debtReserveId);
        c.m = _market(marketId);
        (p.blockNumber, p.timestamp, p.proxy, p.marketId, p.vaultToken) =
        (block.number, block.timestamp, proxy, marketId, vaultToken);
        (p.reserveId, p.debtReserveId, p.debtAsset) = (c.m.reserveId, debtReserveId, c.def.asset);
        p.healthFactor = IAaveV4Spoke(spoke).getUserAccountData(proxy).healthFactor;
        p.aaveLiquidatable = p.healthFactor < LIQUIDATION_THRESHOLD;
        // Aave's bonus curve is defined below 1e18; an account it cannot liquidate reports the bonus at the threshold,
        // the smallest one Aave pays.
        uint256 bonusHf = p.aaveLiquidatable ? p.healthFactor : LIQUIDATION_THRESHOLD;
        p.bonusBps = IAaveV4Spoke(spoke).getLiquidationBonus(c.m.reserveId, proxy, bonusHf);
        IAaveV4Spoke.LiquidationConfig memory lc = IAaveV4Spoke(spoke).getLiquidationConfig();
        (p.targetHealthFactor, p.healthFactorForMaxBonus, p.liquidationBonusFactor) =
        (lc.targetHealthFactor, lc.healthFactorForMaxBonus, lc.liquidationBonusFactor);
        p.suppliedUnits = IAaveV4Spoke(spoke).getUserSuppliedShares(c.m.reserveId, proxy);
        c.total = IAaveV4Spoke(spoke).getUserTotalDebt(debtReserveId, proxy);
        c.debtPriceAave = IAaveV4Oracle(IAaveV4Spoke(spoke).ORACLE()).getReservePrice(debtReserveId);
        c.debtDecimals = IAaveV4Spoke(spoke).getReserve(debtReserveId).decimals;
    }

    /// @dev Gates that do not read a price: Hub shares, routes, committed operators, Aave paused flags, the pause state
    /// (informational) and the effective slippage.
    /// @custom:spec REQ-LENS-016, SPEC-LIQ-001, SPEC-LIQ-003
    function _accountGates(
        LiquidationPreview memory p,
        Ctx memory c
    ) internal view {
        IAaveV4Hub hub = IAaveV4Hub(c.m.hub);
        p.sharesEqualAssets = hub.getAddedAssets(c.m.hubAssetId) == hub.getAddedShares(c.m.hubAssetId);
        p.routeUsable = _routes(p.marketId, c.m.tokens, c.def.asset);
        p.activeKeeperCount = ILPVaultSwapViews(_LP_VAULT_SWAP).activeKeeperCount();
        p.vaultTokenReservePaused = IAaveV4Spoke(c.spoke).getReserveConfig(c.m.reserveId).paused;
        p.debtReservePaused = IAaveV4Spoke(c.spoke).getReserveConfig(p.debtReserveId).paused;
        p.pauseState = _registry().pauseState(c.m.hub);
        uint32 key = IAaveV4Spoke(c.spoke).getUserPosition(c.m.reserveId, p.proxy).dynamicConfigKey;
        uint256 lf = IAaveV4Spoke(c.spoke).getDynamicReserveConfig(c.m.reserveId, key).liquidationFee;
        uint256 allowance = _store().getMarketParams(p.marketId).slippageAllowanceBps;
        p.slippageBps = SettlementMath.effectiveSlippage(SettlementMath.netBonus(p.bonusBps, lf), allowance);
    }

    /// @dev Price gates of the seized market and the repaid reserve only, and the stress valuation of every other debt
    /// reserve of the account, which never blocks.
    /// @custom:spec REQ-LENS-016, REQ-SWAP-008, REQ-SWAP-009, Q-247
    function _priceGates(
        LiquidationPreview memory p,
        Ctx memory c
    ) internal view {
        PriceStateView memory ps = ILPOracle(c.m.lpOracle).getPriceState();
        p.debtPriceFresh = _debtView(c.spoke, c.def).liquidationFresh;
        PriceInput[] memory inputs = _inputs(ps.tokens);
        bool inputsFresh = true;
        for (uint256 i = 0; i < inputs.length; ++i) {
            if (!inputs[i].liquidationFresh) inputsFresh = false;
        }
        p.pricesUsable = !ps.liquidationPaused && inputsFresh && p.debtPriceFresh;
        p.feedsDisagree = ps.disagreementPauseActive;
        p.inGrace = ps.inGrace;
        p.belowGraceHealthFactor = ps.inGrace && p.healthFactor < _store().graceHealthFactor();
        p.stressValued = _stressValued(c.spoke, p.proxy, p.debtReserveId);
    }

    /// @dev Whether another debt reserve with debt is served above its DebtOracle's accepted price.
    /// @custom:spec REQ-LENS-016, REQ-LENS-030
    function _stressValued(
        address spoke,
        address proxy,
        uint256 debtReserveId
    ) internal view returns (bool stressed) {
        uint256[] memory ids = _registry().getDebtReserveIds(spoke);
        address oracle = IAaveV4Spoke(spoke).ORACLE();
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] == debtReserveId || IAaveV4Spoke(spoke).getUserTotalDebt(ids[i], proxy) == 0) continue;
            DebtReserveDef memory def = _registry().getDebtReserve(spoke, ids[i]);
            if (def.fixedPrice) continue;
            // forge-lint: disable-next-line(unused-return)
            (uint256 accepted,) = IDebtOracle(def.priceSource).lastAcceptedPrice();
            if (IAaveV4Oracle(oracle).getReservePrice(ids[i]) > accepted) stressed = true;
        }
    }

    /// @dev One `RouteStatus` per (pool token other than the debt asset, primary and backup slot).
    /// @custom:spec REQ-LENS-016, Q-379
    function _routes(
        uint256 marketId,
        address[] memory tokens,
        address debtAsset
    ) internal view returns (RouteStatus[] memory out) {
        uint256 n = 0;
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (tokens[i] != debtAsset) n += 2;
        }
        out = new RouteStatus[](n);
        n = 0;
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (tokens[i] == debtAsset) continue;
            for (uint8 kind = 0; kind < 2; ++kind) {
                // forge-lint: disable-next-line(unused-return)
                (, bool usable) = _registry().getRoute(marketId, tokens[i], debtAsset, kind);
                out[n++] = RouteStatus({token: tokens[i], debtAsset: debtAsset, routeKind: kind, usable: usable});
            }
        }
    }

    /// @dev Ready-to-send parameters: the margined whole debt when the repayment is the whole debt, seizes every
    /// supplied share, or leaves a remainder within the margin of Aave's dust threshold; Aave's repayment otherwise.
    /// Every amount is 0 at a health factor of at least 1e18.
    /// @custom:spec REQ-LENS-028, Q-235, Q-251, Q-268, Q-404
    function _params(
        LiquidationPreview memory p,
        Ctx memory c,
        LensLiquidationSizing.Sizing memory s,
        uint256 deadline
    ) internal pure {
        LiquidationParams memory q = p.params;
        (q.proxy, q.marketId, q.debtReserveId, q.deadline) = (p.proxy, p.marketId, p.debtReserveId, deadline);
        q.minAmounts = new uint256[](0);
        q.routeMode = RouteMode.PrimaryThenBackup;
        for (uint256 i = 0; i < p.routeUsable.length; ++i) {
            if (p.routeUsable[i].routeKind == 0 && !p.routeUsable[i].usable) q.routeMode = RouteMode.BackupOnly;
        }
        if (!p.aaveLiquidatable || s.debtRepaid == 0) return;
        uint256 bps = SettlementMath.BPS;
        uint256 margin = LensConstants.LENS_DUST_MARGIN_BPS;
        uint256 rest = c.total > s.debtRepaid ? c.total - s.debtRepaid : 0;
        uint256 restValue = rest * c.debtPriceAave * 10 ** (18 - c.debtDecimals);
        bool nearDust = restValue * bps < DUST_LIQUIDATION_THRESHOLD * (bps + margin);
        if (s.wholeDebt || s.allCollateral || nearDust) {
            q.debtToCover = Math.mulDiv(c.total, bps + margin, bps, Math.Rounding.Ceil);
        } else {
            q.debtToCover = s.debtRepaid;
        }
    }

    /// @dev Expected amounts at the oracle value: the recovery floor, the payout for caller funding
    /// `params.debtToCover` with every route at the oracle value, Avana's fee, the borrower surplus, the net payout and
    /// the loss the caller may bear, plus the floor of one whole vault token.
    /// @custom:spec REQ-LENS-029, SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-022, Q-345, Q-397
    function _expected(
        LiquidationPreview memory p,
        Ctx memory c
    ) internal view {
        uint256 pc = _collateralPrice(c.m);
        uint256 pd = _debtPrice(c.spoke, c.def);
        if (pc == 0 || pd == 0) return;
        // forge-lint: disable-next-line(unused-return)
        (uint256[] memory prices,,) = ILPOracle(c.m.lpOracle).getTokenPrices();
        uint256 eps = _store().floorRoundingAllowance(c.def.asset);
        uint256 u = _unitValues(c, prices, pd);
        uint256 dv = c.m.decimals;
        p.minOutPerWholeToken = SettlementMath.recoveryFloor(
            SettlementMath.seizedValue(10 ** dv, pc, c.m.decimals, c.def.decimals, pd), p.slippageBps, u, eps
        );
        uint256 units = p.expectedUnitsSeized;
        if (units == 0) return;
        uint256 v = SettlementMath.seizedValue(units, pc, c.m.decimals, c.def.decimals, pd);
        p.recoveryFloor = SettlementMath.recoveryFloor(v, p.slippageBps, u, eps);
        uint256 d = p.expectedDebtRepaid;
        SettlementMath.Payouts memory pay = SettlementMath.payouts(v, d, v, _store().avanaFeeShareBps());
        (p.expectedAvanaFee, p.expectedBorrowerSurplus) = (pay.avanaFee, pay.borrowerSurplus);
        uint256 kf = p.params.debtToCover;
        p.expectedPayout = kf + v - d - pay.avanaFee - pay.borrowerSurplus;
        p.expectedNetPayout = p.expectedPayout > kf ? p.expectedPayout - kf : 0;
        uint256 rv = _unwoundValue(p.marketId, c, units, prices, pd);
        p.expectedCallerLoss = d > rv ? d - rv : 0;
    }

    /// @dev `U` of SPEC-LIQ-005: one raw unit of each pool token in the debt asset, rounded up; the debt asset counts 1.
    /// @custom:spec SPEC-LIQ-005
    function _unitValues(
        Ctx memory c,
        uint256[] memory prices,
        uint256 debtPrice
    ) internal pure returns (uint256 u) {
        for (uint256 i = 0; i < c.m.tokens.length; ++i) {
            if (c.m.tokens[i] == c.def.asset) {
                ++u;
            } else if (prices[i] != 0) {
                u += _tokenValue(1, prices[i], c.m.tokenDecimals[i], c.def.decimals, debtPrice, true);
            }
        }
    }

    /// @dev `Rv`: the oracle value of the unwound amounts in the debt asset, each leg rounded down. The unwound amounts
    /// are the fair composition of `units` at the oracle price vector, floored, then one raw unit less per token.
    /// @custom:spec REQ-LENS-029, SPEC-LIQ-018
    function _unwoundValue(
        uint256 marketId,
        Ctx memory c,
        uint256 units,
        uint256[] memory prices,
        uint256 debtPrice
    ) internal view returns (uint256 rv) {
        // forge-lint: disable-next-line(unused-return)
        (uint256[] memory amounts,) = IAmmIntegration(c.m.integration).composition(marketId, units, prices);
        for (uint256 i = 0; i < amounts.length; ++i) {
            uint256 a = amounts[i] > 0 ? amounts[i] - 1 : 0;
            if (a == 0) continue;
            if (c.m.tokens[i] == c.def.asset) {
                rv += a;
            } else if (prices[i] != 0) {
                rv += _tokenValue(a, prices[i], c.m.tokenDecimals[i], c.def.decimals, debtPrice, false);
            }
        }
    }
}
// forge-lint: disable-end(calls-loop)
