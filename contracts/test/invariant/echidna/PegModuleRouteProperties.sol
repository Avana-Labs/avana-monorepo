// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISettlementRoute} from "../../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {PegModuleRoute} from "../../../src/liquidation/settlement-routes/PegModuleRoute.sol";
import {PegModuleKind, PegModuleStep} from "../../../src/liquidation/settlement-routes/types/PegModuleStep.sol";
import {RouteConfig} from "../../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {LockMember} from "../../utils/mocks/LockMember.sol";
import {PayoutToken} from "../../utils/mocks/PayoutToken.sol";
import {MockGsm, MockLitePsm, MockRouteCaller, MockVault4626} from "../../utils/mocks/SwapRouteMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PegModuleRouteProperties
/// @notice Echidna and Medusa properties of the `PegModule` swap route (2.12): a LitePSM route (DAI → USDC) and a GSM
/// route (USDC → static aUSDC → GHO). Between transactions: neither route holds a token or an allowance, the immutables
/// are fixed and the Lock is free. Inside one transaction: a LitePSM swap buys the largest USDC amount the DAI covers at
/// the current fee and returns the rest; a GSM swap delivers at least `minOut` of GHO to LPVaultSwap and returns unsold
/// shares; a frozen or seized GSM or a halted LitePSM reverts; the callback is always refused.
/// @dev `property_` functions run in property mode; `psmSwap`, `gsmSwap` and `callback` run in assertion mode with
/// finite branching.
contract PegModuleRouteProperties {
    Lock internal immutable LOCK;
    MockRouteCaller internal immutable SWAP;
    LockMember internal immutable ADAPTER;
    PayoutToken internal immutable DAI;
    PayoutToken internal immutable USDC;
    PayoutToken internal immutable GHO;
    MockLitePsm internal immutable PSM;
    MockVault4626 internal immutable STATA;
    MockGsm internal immutable GSM;
    PegModuleRoute internal immutable PSM_ROUTE;
    PegModuleRoute internal immutable GSM_ROUTE;

    /// @notice Number of assertion sequences run; written so each call is a transaction.
    uint256 public sequences;

    constructor() {
        SWAP = new MockRouteCaller();
        ADAPTER = new LockMember();
        LOCK = new Lock(address(ADAPTER), address(SWAP));
        SWAP.setLock(LOCK);
        ADAPTER.setLock(LOCK);
        DAI = new PayoutToken("DAI", 18);
        USDC = new PayoutToken("USDC", 6);
        GHO = new PayoutToken("GHO", 18);
        PSM = new MockLitePsm(address(DAI), address(USDC), 6);
        USDC.mint(address(PSM), 1e40);
        STATA = new MockVault4626(IERC20(address(USDC)), "stataUSDC");
        GSM = new MockGsm(address(STATA), address(GHO));
        GSM.setRate(1e12, 1);
        GSM.setLot(1e6);
        PSM_ROUTE = new PegModuleRoute(
            _config(address(DAI), address(USDC)),
            PegModuleStep({
                kind: PegModuleKind.LitePsm, module: address(PSM), wrapper: address(0), intermediate: address(0)
            })
        );
        GSM_ROUTE = new PegModuleRoute(
            _config(address(USDC), address(GHO)),
            PegModuleStep({
                kind: PegModuleKind.Gsm, module: address(GSM), wrapper: address(STATA), intermediate: address(STATA)
            })
        );
    }

    function _config(
        address tokenIn,
        address tokenOut
    ) internal view returns (RouteConfig memory) {
        return RouteConfig({
            lpVaultSwap: address(SWAP),
            lock: address(LOCK),
            aaveAdapter: address(ADAPTER),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            tokenClassMask: 1 << 1,
            uniswapV3Factory: address(0),
            slipstreamFactory: address(0),
            curveFactory: address(0)
        });
    }

    // ─── Properties (between transactions) ───

    function property_routesHoldNothing() external view returns (bool) {
        return DAI.balanceOf(address(PSM_ROUTE)) == 0 && USDC.balanceOf(address(PSM_ROUTE)) == 0
            && USDC.balanceOf(address(GSM_ROUTE)) == 0 && STATA.balanceOf(address(GSM_ROUTE)) == 0
            && GHO.balanceOf(address(GSM_ROUTE)) == 0;
    }

    function property_noAllowanceOutstanding() external view returns (bool) {
        return DAI.allowance(address(PSM_ROUTE), address(PSM)) == 0
            && USDC.allowance(address(GSM_ROUTE), address(STATA)) == 0
            && STATA.allowance(address(GSM_ROUTE), address(GSM)) == 0;
    }

    function property_immutablesFixedAndLockFree() external view returns (bool) {
        return PSM_ROUTE.routeType() == 0 && GSM_ROUTE.routeType() == 0 && PSM_ROUTE.tokenOut() == address(USDC)
            && GSM_ROUTE.tokenOut() == address(GHO) && !LOCK.isLocked();
    }

    // ─── Assertion entry points (inside one transaction) ───

    /// @notice A LitePSM swap at one of four fees (0, 1 bp, 10 bps, halted).
    function psmSwap(
        uint96 daiIn,
        uint8 feeCase
    ) external {
        uint256 tout = feeCase % 4 == 0 ? 0 : (feeCase % 4 == 1 ? 1e14 : (feeCase % 4 == 2 ? 1e15 : type(uint256).max));
        PSM.setTout(tout);
        DAI.mint(address(SWAP), daiIn);
        uint256 daiBefore = DAI.balanceOf(address(SWAP));
        uint256 usdcBefore = USDC.balanceOf(address(SWAP));
        try SWAP.swapUnderLock(PSM_ROUTE, daiIn, 1) returns (uint256 out) {
            assert(tout != type(uint256).max);
            assert(USDC.balanceOf(address(SWAP)) - usdcBefore == out);
            uint256 spent = daiBefore - DAI.balanceOf(address(SWAP));
            uint256 cost = out * 1e12 + out * 1e12 * tout / 1e18;
            assert(spent == cost && cost <= daiIn);
            uint256 next = (out + 1) * 1e12;
            assert(next + next * tout / 1e18 > daiIn);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == ISettlementRoute.MinOutNotMet.selector || daiIn == 0);
        }
        ++sequences;
    }

    /// @notice A GSM swap with the GSM live, frozen or seized.
    function gsmSwap(
        uint64 usdcIn,
        uint64 minOut,
        uint8 gsmCase
    ) external {
        GSM.setFrozen(gsmCase % 3 == 1);
        GSM.setSeized(gsmCase % 3 == 2);
        USDC.mint(address(SWAP), usdcIn);
        uint256 ghoBefore = GHO.balanceOf(address(SWAP));
        uint256 sharesBefore = STATA.balanceOf(address(SWAP));
        try SWAP.swapUnderLock(GSM_ROUTE, usdcIn, minOut) returns (uint256 out) {
            assert(gsmCase % 3 == 0);
            assert(out >= minOut && GHO.balanceOf(address(SWAP)) - ghoBefore == out);
            // Shares below one lot are not sold and come back to LPVaultSwap.
            assert(STATA.balanceOf(address(SWAP)) - sharesBefore < 1e6);
        } catch {
            assert(true);
        }
        GSM.setFrozen(false);
        GSM.setSeized(false);
        ++sequences;
    }

    /// @notice The callback is always refused on a route with no pool hop.
    function callback(
        int128 amount0,
        int128 amount1,
        bool gsmRoute
    ) external {
        PegModuleRoute route = gsmRoute ? GSM_ROUTE : PSM_ROUTE;
        try route.uniswapV3SwapCallback(amount0, amount1, "") {
            assert(false);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == ISettlementRoute.InvalidCallback.selector);
        }
        ++sequences;
    }
}
