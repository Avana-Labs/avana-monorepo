// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IDebtOracle} from "../../oracle/debt-oracle/IDebtOracle.sol";
import {DebtPriceView} from "../../oracle/debt-oracle/types/DebtPriceView.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {LPPriceMath} from "../../oracle/lp-oracle/LPPriceMath.sol";
import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/MarketRegistryTypes.sol";
import {IParameterStore} from "../../policy/parameter-store/IParameterStore.sol";
import {Market} from "../../types/Market.sol";
import {PriceState} from "../../types/PriceState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {TokenPriceView} from "../../types/TokenPriceView.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {IPayoutEscrow} from "../payout-escrow/IPayoutEscrow.sol";
import {ISettlementRoute} from "../settlement-routes/ISettlementRoute.sol";
import {LPVaultSwapStorage} from "./LPVaultSwapStorage.sol";
import {SettlementMath} from "./SettlementMath.sol";
import {RouteMode} from "./types/LPVaultSwapTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Loops run over a few market tokens, route intermediates and payouts; a revert reverts the whole call.
// forge-lint: disable-start(calls-loop)
// Every external call here runs under the Lock; RouteFailed must follow the failed route call.
// forge-lint: disable-start(reentrancy-events)
// A leg without a working route, or a payout without enough gas, must revert the whole call.
// forge-lint: disable-start(require-revert-in-loop)
/// @title LPVaultSwapSettlement
/// @notice The settlement steps `liquidate`, `settlePending` and `deleverage` share: record and price checks,
/// valuation prices, swap legs, residue measurement and gas-limited payout delivery.
/// @dev Every amount is a delta of LPVaultSwap's own balance.
abstract contract LPVaultSwapSettlement is LPVaultSwapStorage {
    using SafeERC20 for IERC20;

    /// @dev Tokens whose residue a call pays out, with their starting balances; `asset` is never tracked.
    struct Tracked {
        address asset;
        address[] tokens;
        uint256[] start;
        uint256 count;
    }

    struct LegArgs {
        uint256 marketId;
        address asset;
        uint8 assetDecimals;
        uint256 assetPrice;
        uint256 sLeg;
        uint256 allowance;
        RouteMode mode;
        address[] tokens;
        uint8[] decimals;
        uint256[] prices;
        uint256[] amounts;
    }

    function _loadMarket(
        uint256 marketId
    ) internal view returns (Market memory m) {
        m = IMarketRegistry(_MARKET_REGISTRY).getMarket(marketId);
        address vt = m.vaultToken;
        if (
            vt == address(0) || IVaultToken(vt).hub() != m.hub || IVaultToken(vt).spoke() != m.spoke
                || IVaultToken(vt).marketId() != marketId
        ) revert UnknownMarket();
    }

    /// @dev Aave's `borrowable` flag is not read, so a reserve closed to new borrowing is still liquidated.
    function _loadDebtReserve(
        address spoke,
        uint256 reserveId
    ) internal view returns (DebtReserveDef memory def) {
        IMarketRegistry mr = IMarketRegistry(_MARKET_REGISTRY);
        if (!mr.isApprovedDebtReserve(spoke, reserveId)) revert UnknownDebtReserve(reserveId);
        def = mr.getDebtReserve(spoke, reserveId);
        if (def.asset == address(0)) revert UnknownDebtReserve(reserveId);
    }

    function _requireSharesEqualAssets(
        address hub,
        uint256 assetId
    ) internal view {
        if (IAaveV4Hub(hub).getAddedAssets(assetId) != IAaveV4Hub(hub).getAddedShares(assetId)) {
            revert SharesNotEqualAssets();
        }
    }

    function _checkCollateralPrice(
        address lpOracle
    ) internal returns (bool inGrace) {
        // The poke result is read back through getPriceState below, which also carries the flags and leg ages.
        // forge-lint: disable-next-line(unused-return)
        ILPOracle(lpOracle).poke();
        PriceStateView memory ps = ILPOracle(lpOracle).getPriceState();
        bool stale = ps.liquidationPaused || ps.state == PriceState.Cached || ps.state == PriceState.Expired
            || ps.disagreementPauseActive || ps.disagreementExpired;
        uint256 n = ps.tokens.length;
        for (uint256 i = 0; i < n && !stale; ++i) {
            TokenPriceView memory t = ps.tokens[i];
            stale = _legStale(t.legFeeds[0], t.legUpdatedAt[0]) || _legStale(t.legFeeds[1], t.legUpdatedAt[1]);
        }
        if (stale) revert StalePrice();
        inGrace = ps.inGrace;
    }

    function _checkDebtPrice(
        DebtReserveDef memory def,
        uint256 reserveId
    ) internal {
        if (def.fixedPrice) return;
        address oracle = def.priceSource;
        if (oracle == address(0)) revert DebtPriceStale(reserveId);
        // The poke result is read back through getPriceState below, with the liquidation flag and leg ages.
        // forge-lint: disable-next-line(unused-return)
        IDebtOracle(oracle).poke();
        DebtPriceView memory v = IDebtOracle(oracle).getPriceState();
        if (
            v.state != PriceState.Live || v.liquidationPaused || _legStale(v.legFeeds[0], v.legUpdatedAt[0])
                || _legStale(v.legFeeds[1], v.legUpdatedAt[1])
        ) revert DebtPriceStale(reserveId);
    }

    function _legStale(
        address feed,
        uint64 updatedAt
    ) private view returns (bool) {
        if (feed == address(0)) return false;
        return !LPPriceMath.liquidationFresh(updatedAt, IParameterStore(_PARAMETER_STORE).liquidationPriceMaxAge(feed));
    }

    /// @dev The smaller of the AaveOracle price of the collateral reserve and the LPOracle's served price.
    function _collateralPrice(
        Market memory m
    ) internal view returns (uint256 price) {
        price = IAaveV4Oracle(IAaveV4Spoke(m.spoke).ORACLE()).getReservePrice(m.reserveId);
        int256 lp = ILPOracle(m.lpOracle).latestAnswer();
        if (lp <= 0) return 0;
        // lp > 0 is checked above (a non-positive answer is stale); the cast is of a positive int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint256(lp) < price) price = uint256(lp);
    }

    /// @dev The larger of the AaveOracle price of the reserve and its DebtOracle's; the AaveOracle's alone if fixed.
    function _debtPrice(
        address spoke,
        uint256 reserveId,
        DebtReserveDef memory def
    ) internal view returns (uint256 pd) {
        pd = IAaveV4Oracle(IAaveV4Spoke(spoke).ORACLE()).getReservePrice(reserveId);
        if (def.fixedPrice) return pd;
        int256 d = IDebtOracle(def.priceSource).latestAnswer();
        // The cast runs only for d > 0 (same expression), so it is of a positive int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (d > 0 && uint256(d) > pd) pd = uint256(d);
    }

    function _snapshot(
        address[] memory tokens,
        address asset
    ) internal view returns (Tracked memory t) {
        uint256 n = tokens.length;
        t.asset = asset;
        t.tokens = new address[](n + 4);
        t.start = new uint256[](n + 4);
        for (uint256 i = 0; i < n; ++i) {
            t.tokens[i] = tokens[i];
            t.start[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
        t.count = n;
    }

    function _released(
        Tracked memory t,
        uint256 n
    ) internal view returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 b = IERC20(t.tokens[i]).balanceOf(address(this));
            a[i] = b > t.start[i] ? b - t.start[i] : 0;
        }
    }

    function _unitSum(
        LegArgs memory l
    ) internal pure returns (uint256 u) {
        uint256 n = l.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            u += l.tokens[i] == l.asset
                ? 1
                : SettlementMath.unitValue(l.prices[i], l.decimals[i], l.assetDecimals, l.assetPrice);
        }
    }

    function _residues(
        Tracked memory t
    ) internal view returns (uint256[] memory r) {
        r = new uint256[](t.count);
        for (uint256 i = 0; i < t.count; ++i) {
            if (t.tokens[i] == t.asset) continue;
            uint256 b = IERC20(t.tokens[i]).balanceOf(address(this));
            r[i] = b > t.start[i] ? b - t.start[i] : 0;
        }
    }

    /// @dev Returns the route used per token: 0 none, 1 primary, 2 backup.
    function _swapLegs(
        LegArgs memory l,
        Tracked memory t
    ) internal returns (uint8[] memory used) {
        uint256 n = l.tokens.length;
        uint256[] memory vLeg = new uint256[](n);
        uint256[] memory uLeg = new uint256[](n);
        uint256 swapped = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (l.tokens[i] == l.asset || l.amounts[i] == 0) continue;
            vLeg[i] = SettlementMath.legValue(l.amounts[i], l.prices[i], l.decimals[i], l.assetDecimals, l.assetPrice);
            uLeg[i] = SettlementMath.unitValue(l.prices[i], l.decimals[i], l.assetDecimals, l.assetPrice);
            if (SettlementMath.isDustLeg(vLeg[i], uLeg[i])) vLeg[i] = 0;
            else ++swapped;
        }
        used = new uint8[](n);
        for (uint256 i = 0; i < n; ++i) {
            if (vLeg[i] == 0) continue;
            uint256 minOut = SettlementMath.legMinOut(vLeg[i], l.sLeg, uLeg[i], l.allowance, swapped);
            used[i] = _swapLeg(l, i, minOut, t);
        }
    }

    function _swapLeg(
        LegArgs memory l,
        uint256 i,
        uint256 minOut,
        Tracked memory t
    ) private returns (uint8) {
        IMarketRegistry mr = IMarketRegistry(_MARKET_REGISTRY);
        if (l.mode == RouteMode.PrimaryThenBackup) {
            (address primary, bool usable) = mr.getRoute(l.marketId, l.tokens[i], l.asset, 0);
            if (usable && _tryRoute(l, i, primary, minOut, t, true)) return 1;
        }
        (address backup, bool backupUsable) = mr.getRoute(l.marketId, l.tokens[i], l.asset, 1);
        if (backupUsable && _tryRoute(l, i, backup, minOut, t, false)) return 2;
        revert NoRouteAvailable();
    }

    function _tryRoute(
        LegArgs memory l,
        uint256 i,
        address route,
        uint256 minOut,
        Tracked memory t,
        bool primary
    ) private returns (bool ok) {
        try ISettlementRoute(route).intermediates() returns (address[] memory im) {
            for (uint256 j = 0; j < im.length; ++j) {
                _track(t, im[j]);
            }
        } catch (bytes memory reason) {
            if (primary) emit RouteFailed(l.marketId, l.tokens[i], route, _selector(reason));
            return false;
        }
        IERC20 token = IERC20(l.tokens[i]);
        token.forceApprove(route, l.amounts[i]);
        try ISettlementRoute(route).swap(l.amounts[i], minOut) returns (uint256) {
            ok = true;
        } catch (bytes memory reason) {
            if (primary) emit RouteFailed(l.marketId, l.tokens[i], route, _selector(reason));
        }
        token.forceApprove(route, 0);
    }

    function _track(
        Tracked memory t,
        address token
    ) private view {
        if (token == t.asset) return;
        for (uint256 k = 0; k < t.count; ++k) {
            if (t.tokens[k] == token) return;
        }
        if (t.count == t.tokens.length) {
            address[] memory tokens = new address[](t.count * 2);
            uint256[] memory start = new uint256[](t.count * 2);
            for (uint256 k = 0; k < t.count; ++k) {
                tokens[k] = t.tokens[k];
                start[k] = t.start[k];
            }
            t.tokens = tokens;
            t.start = start;
        }
        t.tokens[t.count] = token;
        t.start[t.count] = IERC20(token).balanceOf(address(this));
        ++t.count;
    }

    function _selector(
        bytes memory reason
    ) private pure returns (bytes4 sel) {
        // bytes4 of revert data is the selector by definition; shorter data leaves the selector 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (reason.length >= 4) sel = bytes4(reason);
    }

    /// @dev Gas-limited transfer; any undelivered rest goes to the PayoutEscrow. Returns whether it escrowed.
    function _deliver(
        address token,
        address recipient,
        uint256 amount
    ) internal returns (bool escrowed) {
        if (amount == 0) return false;
        uint256 before = IERC20(token).balanceOf(address(this));
        bytes memory data = abi.encodeCall(IERC20.transfer, (recipient, amount));
        if (gasleft() < _PAYOUT_GAS_REQUIRED) revert InsufficientGas(gasleft(), _PAYOUT_GAS_REQUIRED);
        // Copies no return data, so no token behaviour can revert the settlement; only the measured balance counts.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            pop(call(_PAYOUT_TRANSFER_GAS, token, 0, add(data, 0x20), mload(data), 0, 0))
        }
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        uint256 sent = before > afterBalance ? before - afterBalance : 0;
        if (sent >= amount) return false;
        uint256 rest = amount - sent;
        IERC20(token).forceApprove(_PAYOUT_ESCROW, rest);
        IPayoutEscrow(_PAYOUT_ESCROW).deposit(token, recipient, rest);
        IERC20(token).forceApprove(_PAYOUT_ESCROW, 0);
        escrowed = true;
    }
}
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(reentrancy-events)
// forge-lint: disable-end(require-revert-in-loop)
