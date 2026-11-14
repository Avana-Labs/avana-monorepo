// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IDebtOracle} from "../../oracle/debt-oracle/IDebtOracle.sol";
import {DebtPriceView} from "../../oracle/debt-oracle/types/DebtPriceView.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {PriceAge} from "../../oracle/lp-oracle/PriceAge.sol";
import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
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
import {RouteMode} from "./types/RouteMode.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Loops run over the market tokens (2 to 4), the intermediates a route names and at most 4 payouts; every
// callee is a pool token, a registry-listed route, the registry or the PayoutEscrow, and a revert reverts the whole call.
// forge-lint: disable-start(calls-loop)
// Every external call here runs while LPVaultSwap holds the Lock (REQ-SWAP-002), so no Avana entry point can
// re-enter; RouteFailed reports a route call after it failed and has to follow it.
// forge-lint: disable-start(reentrancy-events)
// NoRouteAvailable and the payout gas check inside the leg and payout loops are the specified refusals (REQ-SWAP-022,
// REQ-SWAP-076): a leg without a working route or a call without the gas for a transfer must revert the whole call.
// forge-lint: disable-start(require-revert-in-loop)
/// @title LPVaultSwapSettlement
/// @notice The settlement steps `liquidate`, `settlePending` and `deleverage` share: the market and debt-reserve
/// checks, the price rules of the seized market and the repaid reserve, the prices a valuation uses, the released-token
/// measurement, the swap legs at their oracle minimums over the market's recorded routes, the residue measurement and
/// the gas-limited payout delivery with its escrow fallback.
/// @dev Every amount is a balance delta of LPVaultSwap's own balance across the step that moved it (REQ-SWAP-108);
/// every parameter and record is read during the call (REQ-SWAP-047). The residue of a token is its balance at the end
/// of the swaps less its balance just before the burn, for every market token and every intermediate token of a route
/// that was called, so a residue paid to its recipient leaves LPVaultSwap's balance of that token unchanged
/// (REQ-SWAP-024, REQ-SWAP-042).
/// @custom:spec REQ-SWAP-004, REQ-SWAP-007, REQ-SWAP-008, REQ-SWAP-021, REQ-SWAP-022, REQ-SWAP-023, REQ-SWAP-024, REQ-SWAP-047, REQ-SWAP-076, REQ-SWAP-087, REQ-SWAP-091, REQ-SWAP-100, REQ-SWAP-108, REQ-SWAP-121, SPEC-LIQ-004, SPEC-LIQ-012, SPEC-LIQ-013, SPEC-LIQ-018
abstract contract LPVaultSwapSettlement is LPVaultSwapStorage {
    using SafeERC20 for IERC20;

    /// @dev Tokens whose residue a call pays out: the market's tokens in pool order, then the intermediate tokens of
    /// the routes it called, each with its balance just before the burn (a market token) or before the first route
    /// that names it. `asset` (the settlement asset) is never tracked: what arrives in it is recovery.
    struct Tracked {
        address asset;
        address[] tokens;
        uint256[] start;
        uint256 count;
    }

    /// @dev Inputs of the swap legs of one call.
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

    // ─────────────────────────────────────────────────────────────────────────────────────── records and gates

    /// @dev The market record, checked against its vault token's immutables (`UnknownMarket`).
    /// @custom:spec REQ-SWAP-004, REQ-SWAP-047
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

    /// @dev The debt reserve's record: enabled in the MarketRegistry for `spoke`, with an asset (`UnknownDebtReserve`).
    /// Aave's `borrowable` flag is not read: Aave keeps repaying and liquidating a reserve whose new borrowing it turned
    /// off, and so does LPVaultSwap (REQ-SWAP-003).
    /// @custom:spec REQ-SWAP-087, REQ-SWAP-095, REQ-SWAP-003
    function _loadDebtReserve(
        address spoke,
        uint256 reserveId
    ) internal view returns (DebtReserveDef memory def) {
        IMarketRegistry mr = IMarketRegistry(_MARKET_REGISTRY);
        if (!mr.isApprovedDebtReserve(spoke, reserveId)) revert UnknownDebtReserve(reserveId);
        def = mr.getDebtReserve(spoke, reserveId);
        if (def.asset == address(0)) revert UnknownDebtReserve(reserveId);
    }

    /// @dev `SharesNotEqualAssets` unless the vault-token asset's added shares equal its added assets on its Hub.
    /// @custom:spec REQ-SWAP-007, REQ-SWAP-052
    function _requireSharesEqualAssets(
        address hub,
        uint256 assetId
    ) internal view {
        if (IAaveV4Hub(hub).getAddedAssets(assetId) != IAaveV4Hub(hub).getAddedShares(assetId)) {
            revert SharesNotEqualAssets();
        }
    }

    /// @dev Collateral price rule (a) to (d) after `poke()`: `StalePrice` if the market's price is liquidation-paused,
    /// Cached or Expired, inside or past the disagreement pause, or has a leg older than its
    /// `liquidationPriceMaxAge`. Returns whether the market is in its grace window.
    /// @custom:spec REQ-SWAP-008, REQ-SWAP-009, REQ-SWAP-050, SPEC-LIQ-012
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

    /// @dev Debt price rule for the repaid reserve: none for a fixed-price source (GHO); otherwise, after `poke()`, its
    /// DebtOracle must be Live, not liquidation-paused, and every leg within its `liquidationPriceMaxAge`
    /// (`DebtPriceStale`).
    /// @custom:spec REQ-SWAP-091, REQ-SWAP-096
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

    /// @dev True when a used leg is older than the ParameterStore's `liquidationPriceMaxAge` for its feed.
    function _legStale(
        address feed,
        uint64 updatedAt
    ) private view returns (bool) {
        if (feed == address(0)) return false;
        return !PriceAge.liquidationFresh(updatedAt, IParameterStore(_PARAMETER_STORE).liquidationPriceMaxAge(feed));
    }

    /// @dev `Pc`: the smaller of the AaveOracle price of the collateral reserve and the LPOracle's served price.
    /// @custom:spec SPEC-LIQ-004
    function _collateralPrice(
        Market memory m
    ) internal view returns (uint256 pc) {
        pc = IAaveV4Oracle(IAaveV4Spoke(m.spoke).ORACLE()).getReservePrice(m.reserveId);
        int256 lp = ILPOracle(m.lpOracle).latestAnswer();
        if (lp <= 0) return 0;
        // lp > 0 is checked above (a non-positive answer is stale); the cast is of a positive int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint256(lp) < pc) pc = uint256(lp);
    }

    /// @dev `Pdebt`: the larger of the AaveOracle price of the reserve and its DebtOracle's (the AaveOracle's fixed
    /// price alone for a fixed-price source such as GHO).
    /// @custom:spec SPEC-LIQ-004, SPEC-LIQ-014
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

    // ─────────────────────────────────────────────────────────────────────────────── measurement and valuation

    /// @dev Snapshot of the market's tokens before the burn (the start of the recovery window).
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

    /// @dev `aᵢ`: the rise of each of the first `n` tracked balances since the snapshot (REQ-SWAP-021).
    /// @custom:spec REQ-SWAP-021, REQ-SWAP-108
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

    /// @dev `U = Σᵢ ⌈pᵢ × 10^dd / (10^dᵢ × Pdebt)⌉`, 1 for a token that is the settlement asset.
    /// @custom:spec SPEC-LIQ-005, SPEC-LIQ-014
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

    /// @dev Each tracked token's balance now less its start: the route residues and dust legs to pay out.
    /// @custom:spec REQ-SWAP-024, REQ-SWAP-121
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

    // ──────────────────────────────────────────────────────────────────────────────────────────────── swap legs

    /// @dev Swaps every released token other than the settlement asset that is not a dust leg, each at its
    /// SPEC-LIQ-018 minimum; returns the route used per token (0 none, 1 primary, 2 backup).
    /// @custom:spec REQ-SWAP-022, REQ-SWAP-100, REQ-SWAP-121, SPEC-LIQ-018, INV-083
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

    /// @dev One leg: the usable primary in `PrimaryThenBackup` mode, then the usable backup, each with the same
    /// minimum; `NoRouteAvailable` when neither swaps.
    /// @custom:spec REQ-SWAP-022, REQ-SWAP-058, REQ-SWAP-059, REQ-SWAP-110, SPEC-LIQ-013
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

    /// @dev Tracks the route's intermediate tokens, approves exactly the leg input, calls `swap(aᵢ, minOutᵢ)` inside
    /// try/catch and resets the allowance whether the call succeeded or reverted. A primary that reverts emits
    /// `RouteFailed`.
    /// @custom:spec REQ-SWAP-022, REQ-SWAP-023, REQ-SWAP-024, REQ-SWAP-058, REQ-SWAP-100
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

    /// @dev Adds `token` to the tracked set with its current balance, once; the settlement asset is never tracked.
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

    /// @dev First four bytes of a revert reason, 0 when shorter.
    function _selector(
        bytes memory reason
    ) private pure returns (bytes4 sel) {
        // bytes4 of revert data is the selector by definition; shorter data leaves the selector 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (reason.length >= 4) sel = bytes4(reason);
    }

    // ──────────────────────────────────────────────────────────────────────────────────────────── payout delivery

    /// @dev REQ-SWAP-076 delivery of an escrowable payout: skips 0; reads LPVaultSwap's balance; reverts
    /// `InsufficientGas` unless `gasleft() ≥ ⌈PAYOUT_TRANSFER_GAS × 64 / 63⌉ + POST_CALL_GAS`; calls
    /// `token.transfer(recipient, amount)` with exactly `PAYOUT_TRANSFER_GAS` gas and no return data copied; measures
    /// what left its balance and deposits the undelivered rest in the PayoutEscrow credited to `recipient`. Returns
    /// whether a deposit was made.
    /// @custom:spec REQ-SWAP-076, REQ-SWAP-077, REQ-SWAP-082, REQ-SWAP-083, REQ-SWAP-114
    function _deliver(
        address token,
        address recipient,
        uint256 amount
    ) internal returns (bool escrowed) {
        if (amount == 0) return false;
        uint256 before = IERC20(token).balanceOf(address(this));
        bytes memory data = abi.encodeCall(IERC20.transfer, (recipient, amount));
        if (gasleft() < _PAYOUT_GAS_REQUIRED) revert InsufficientGas(gasleft(), _PAYOUT_GAS_REQUIRED);
        // A gas-limited call that copies no return data: a reverting, false-returning, gas-burning or return-bombing
        // token cannot revert the settlement; only the measured balance counts.
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
