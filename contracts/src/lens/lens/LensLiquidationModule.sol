// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwap} from "../../liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {SettlementMath} from "../../liquidation/lp-vault-swap/SettlementMath.sol";
import {LiquidationParams, RouteMode} from "../../liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {ILPOracle} from "../../oracle/ILPOracle.sol";
import {IAaveAdapter} from "../../policy/aave-adapter/IAaveAdapter.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/MarketRegistryTypes.sol";
import {Market} from "../../types/MarketTypes.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {LensBase} from "./LensBase.sol";
import {LensConstants} from "./LensConstants.sol";
import {LensLiquidationSizing} from "./LensLiquidationSizing.sol";
import {LiquidationPreview, RouteStatus} from "./types/LensTypes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensLiquidationModule
/// @notice Lens module serving `ILens.previewLiquidation`.
contract LensLiquidationModule is LensBase {
    // forge-lint: disable-start(calls-loop)
    /// @dev Aave's `HEALTH_FACTOR_LIQUIDATION_THRESHOLD`, WAD.
    uint256 internal constant LIQUIDATION_THRESHOLD = 1e18;

    /// @dev Aave's `DUST_LIQUIDATION_THRESHOLD`, in Aave value units.
    uint256 internal constant DUST_LIQUIDATION_THRESHOLD = 1000e26;

    address internal immutable _AAVE_SIZING;

    struct Ctx {
        Market m;
        DebtReserveDef def;
        address spoke;
        uint256 total;
        uint256 debtPriceAave;
        uint8 debtDecimals;
    }

    function AAVE_SIZING() external view returns (address sizing) {
        sizing = _AAVE_SIZING;
    }

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

    function _context(
        LiquidationPreview memory p,
        address proxy,
        uint256 debtReserveId
    ) internal view returns (Ctx memory c) {
        // forge-lint: disable-next-line(unused-return)
        (address spoke, uint256 marketId, address vaultToken,) = IAaveAdapter(_ADAPTER).accountOf(proxy);
        if (vaultToken == address(0) || !IVaultToken(vaultToken).isValidProxy(proxy)) revert UnknownProxy(proxy);
        c.spoke = spoke;
        c.def = _debtReserve(spoke, debtReserveId);
        c.m = _market(marketId);
        (p.blockNumber, p.timestamp, p.proxy, p.marketId, p.vaultToken) =
        (block.number, block.timestamp, proxy, marketId, vaultToken);
        (p.reserveId, p.debtReserveId, p.debtAsset) = (c.m.reserveId, debtReserveId, c.def.asset);
        p.healthFactor = IAaveV4Spoke(spoke).getUserAccountData(proxy).healthFactor;
        p.aaveLiquidatable = p.healthFactor < LIQUIDATION_THRESHOLD;
        // Aave's bonus curve is defined below 1e18; a non-liquidatable account reports the smallest bonus.
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

    /// @dev Gates that do not read a price, plus the pause state (informational) and effective slippage.
    function _accountGates(
        LiquidationPreview memory p,
        Ctx memory c
    ) internal view {
        IAaveV4Hub hub = IAaveV4Hub(c.m.hub);
        p.sharesEqualAssets = hub.getAddedAssets(c.m.hubAssetId) == hub.getAddedShares(c.m.hubAssetId);
        p.routeUsable = _routes(p.marketId, c.m.tokens, c.def.asset);
        p.activeKeeperCount = ILPVaultSwap(_LP_VAULT_SWAP).activeKeeperCount();
        p.vaultTokenReservePaused = IAaveV4Spoke(c.spoke).getReserveConfig(c.m.reserveId).paused;
        p.debtReservePaused = IAaveV4Spoke(c.spoke).getReserveConfig(p.debtReserveId).paused;
        uint32 key = IAaveV4Spoke(c.spoke).getUserPosition(c.m.reserveId, p.proxy).dynamicConfigKey;
        uint256 lf = IAaveV4Spoke(c.spoke).getDynamicReserveConfig(c.m.reserveId, key).liquidationFee;
        uint256 allowance = _store().getMarketParams(p.marketId).slippageAllowanceBps;
        p.slippageBps = SettlementMath.effectiveSlippage(SettlementMath.netBonus(p.bonusBps, lf), allowance);
    }

    /// @dev Price gates of the seized market and repaid reserve; other reserves' stress valuation never blocks.
    function _priceGates(
        LiquidationPreview memory p,
        Ctx memory c
    ) internal view {
        p.debtPriceFresh = _debtView(c.spoke, c.def).liquidationFresh;
        p.pricesUsable = ILPOracle(c.m.lpOracle).getPriceStatus().liquidationFresh && p.debtPriceFresh;
    }

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

    /// @dev `PrimaryThenBackup` when every token has a usable route, else `BackupOnly` if any primary is unusable.
    function _routeMode(
        RouteStatus[] memory routes
    ) internal pure returns (RouteMode) {
        for (uint256 i = 0; i < routes.length; ++i) {
            if (!_hasUsableRoute(routes, routes[i].token)) {
                return _anyPrimaryDown(routes) ? RouteMode.BackupOnly : RouteMode.PrimaryThenBackup;
            }
        }
        return RouteMode.PrimaryThenBackup;
    }

    function _hasUsableRoute(
        RouteStatus[] memory routes,
        address token
    ) private pure returns (bool) {
        for (uint256 i = 0; i < routes.length; ++i) {
            if (routes[i].token == token && routes[i].usable) return true;
        }
        return false;
    }

    function _anyPrimaryDown(
        RouteStatus[] memory routes
    ) private pure returns (bool) {
        for (uint256 i = 0; i < routes.length; ++i) {
            if (routes[i].routeKind == 0 && !routes[i].usable) return true;
        }
        return false;
    }

    /// @dev Margined whole debt when Aave's dust rule could apply, else Aave's repayment; 0 when not liquidatable.
    function _params(
        LiquidationPreview memory p,
        Ctx memory c,
        LensLiquidationSizing.Sizing memory s,
        uint256 deadline
    ) internal pure {
        LiquidationParams memory q = p.params;
        (q.proxy, q.marketId, q.debtReserveId, q.deadline) = (p.proxy, p.marketId, p.debtReserveId, deadline);
        q.minAmounts = new uint256[](0);
        q.routeMode = _routeMode(p.routeUsable);
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

    /// @dev Expected amounts with every route at the oracle value, for caller funding of `params.debtToCover`.
    function _expected(
        LiquidationPreview memory p,
        Ctx memory c
    ) internal view {
        uint256 pc = _collateralPrice(c.m);
        uint256 pd = _debtPrice(c.spoke, c.def);
        if (pc == 0 || pd == 0) return;
        // forge-lint: disable-next-line(unused-return)
        (uint256[] memory prices,) = ILPOracle(c.m.lpOracle).getTokenPrices();
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

    /// @dev `U`: one raw unit of each pool token in the debt asset, rounded up; the debt asset counts 1.
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

    /// @dev `Rv`: oracle value of the unwound amounts (fair composition less one raw unit per token), rounded down.
    function _unwoundValue(
        uint256 marketId,
        Ctx memory c,
        uint256 units,
        uint256[] memory prices,
        uint256 debtPrice
    ) internal view returns (uint256 rv) {
        // forge-lint: disable-next-line(unused-return)
        (uint256[] memory amounts,) = ILPVault(c.m.integration).composition(marketId, units, prices);
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

    // forge-lint: disable-end(calls-loop)

    /// @param core The nine core addresses, in `LensBase` order.
    /// @param sizing `LensAaveSizing`, Aave's pinned liquidation sizing.
    constructor(
        address[9] memory core,
        address sizing
    ) LensBase(core) {
        if (sizing == address(0)) revert InvalidModules();
        _AAVE_SIZING = sizing;
    }
}
