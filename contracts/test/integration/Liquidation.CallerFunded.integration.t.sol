// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapEvents} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapEvents.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title LiquidationCallerFundedIntegrationTest
/// @notice Caller-funded liquidation of an account the borrower opened through the real AaveAdapter, settled by the
/// real LPVaultSwap: the real Adapter's `burnSeized`, Collateralization's seizure, the LPVault unwind, the swap routes
/// into the debt asset and the waterfall, for each debt reserve, in both route modes and in every pause state.
/// @dev Bob's account of 2.11 (`LIQ-069`): 10,000 vault tokens pledged at $2.50 against 18,000 of debt, HF 0.933 at
/// $2.10. A 1,950 repayment seizes `1,950 × 1.05 / 2.10 = 975` vault tokens worth `V = 2,047.5`.
/// forge-config: default.isolate = false
contract LiquidationCallerFundedIntegrationTest is IntegrationFlows {
    uint256 internal constant X = 1950e6;
    uint256 internal constant C = 975e6;

    function setUp() public {
        _deployIntegration();
    }

    /// @notice Opens Bob's account against GHO instead of USDC.
    function _bobGhoAccount() internal returns (address proxy) {
        _setPrice(MARKET_ID, 250_000_000);
        (, proxy) = _pledgeVia(bob, MARKET_ID, 10_000e6);
        _borrowVia(bob, MARKET_ID, debtReserveId, 18_000e18);
        _setPrice(MARKET_ID, P_VAULT);
    }

    /// @dev Every settlement identity of `TEST-047` and `TEST-104` on one result.
    function _checkSettlement(
        LiquidationResult memory r,
        uint256 x,
        uint256 v,
        CollPoolToken asset
    ) internal view {
        assertEq(r.debtAsset, address(asset), "settled in the repaid debt asset");
        assertEq(r.callerFunds, x, "Kf = the pulled funding");
        assertLe(r.debtRepaid, r.callerFunds, "D <= Kf");
        assertEq(
            r.callerFunds + r.recovered + r.shortfall,
            r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut,
            "Kf + R + shortfall = D + A + B + keeperOut"
        );
        assertGe(r.recovered + r.shortfall, r.minOut, "R + shortfall >= minRec");
        uint256 rf = r.recovered + r.shortfall;
        uint256 s = rf > r.debtRepaid ? rf - r.debtRepaid : 0;
        uint256 g = v > r.debtRepaid ? v - r.debtRepaid : 0;
        uint256 a = g * 2000 / 10_000;
        assertEq(r.avanaFee, a < s ? a : s, "A = min(floor(G x 20 %), S)");
        assertEq(r.avanaFee + r.keeperReward + r.borrowerSurplus, s, "A + kr + B = S");
        assertEq(asset.balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no debt asset");
        assertEq(usdt.balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no pool token");
        assertEq(token.balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no vault token");
        assertFalse(lock.isLocked(), "Lock released");
        assertEq(v3Pool.flashLoanCalls(), 0, "no flash source or lender called");
    }

    // TEST-047 verifies: REQ-SWAP-011, REQ-SWAP-015, REQ-SWAP-016, REQ-SWAP-020, REQ-SWAP-045, REQ-ADAPTER-070, REQ-SWAP-028, SPEC-LIQ-006, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-022, Q-060, Q-061, Q-404
    // TEST-104 verifies: SPEC-LIQ-010, REQ-SWAP-073, INV-035, INV-038
    function test_TEST_047_callerFundedSequenceThroughRealAdapter() public {
        (address proxy,) = _bobAccount();
        uint256 supplyBefore = token.totalSupply();
        uint256 creditedBefore = coll.getTotalCredited(vt);
        uint256 debtBefore = _debtOf(proxy, usdcReserveId);
        uint256 sharesBefore = _suppliedOf(proxy, MARKET_ID);
        LiquidationParams memory p = _liqParams(proxy, MARKET_ID, usdcReserveId, X);
        _fundCaller(keeper, p);
        vm.expectEmit(true, true, false, true, adapter);
        emit IAaveAdapterEvents.SeizedUnitsBurned(MARKET_ID, vt, C);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        assertEq(r.debtRepaid, X, "D: Aave pulled the whole repayment");
        assertEq(r.unitsSeized, C, "c = 1,950 x 1.05 / 2.10");
        _checkSettlement(r, X, 2047.5e6, usdc);
        assertEq(r.avanaFee, 19.5e6, "A = 20 % of the 97.5 oracle gain");
        assertEq(supplyBefore - token.totalSupply(), C, "the Adapter burned exactly the seized units");
        assertEq(creditedBefore - coll.getTotalCredited(vt), C, "Collateralization debited them");
        assertEq(sharesBefore - _suppliedOf(proxy, MARKET_ID), C, "the proxy's shares fell by c");
        assertEq(token.totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "supply = credited");
        assertEq(debtBefore - _debtOf(proxy, usdcReserveId), X, "debt fell by D");
        assertEq(usdc.balanceOf(keeper), r.keeperOut, "keeperOut paid to the caller");
        assertEq(usdc.balanceOf(feeRecipient), r.avanaFee, "fee paid to the fee recipient");
        assertEq(usdc.balanceOf(bob), 18_000e6 + r.borrowerSurplus, "surplus (if any) to the wallet");
        assertGt(_hf(proxy), 0.933e18, "the account's health rose");
    }

    // TEST-047 verifies: REQ-SWAP-020, REQ-SWAP-045, REQ-ADAPTER-070, SPEC-LIQ-004, SPEC-LIQ-006, Q-233
    function test_TEST_047_ghoDebtReserveThroughRealAdapter() public {
        address proxy = _bobGhoAccount();
        uint256 supplyBefore = token.totalSupply();
        LiquidationParams memory p = _liqParams(proxy, MARKET_ID, debtReserveId, 1950e18);
        _fundCaller(keeper, p);
        vm.expectEmit(true, true, false, true, adapter);
        emit IAaveAdapterEvents.SeizedUnitsBurned(MARKET_ID, vt, C);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        assertEq(r.debtRepaid, 1950e18, "D in GHO");
        assertEq(r.unitsSeized, C, "same seizure at GHO $1.00");
        _checkSettlement(r, 1950e18, 2047.5e18, debt);
        assertEq(supplyBefore - token.totalSupply(), C, "burned");
        assertEq(usdc.balanceOf(lpVaultSwap), 0, "both legs swapped into GHO");
        assertEq(debt.balanceOf(keeper), r.keeperOut, "keeperOut in GHO");
    }

    // TEST-047 verifies: REQ-SWAP-003, REQ-ADAPTER-070, REQ-ADAPTER-086, INV-045, INV-046, Q-404
    function test_TEST_047_succeedsInEveryPauseStateThroughRealAdapter() public {
        address[3] memory wallets = [bob, alice, carol];
        PauseState[3] memory states = [PauseState.Frozen, PauseState.Paused, PauseState.Paused];
        PauseReason[3] memory reasons = [PauseReason.None, PauseReason.General, PauseReason.MintPathSuspect];
        for (uint256 i = 0; i < 3; ++i) {
            (address proxy,) = _openAccount(wallets[i], MARKET_ID, 10_000e6, 18_000e6, 250_000_000);
            reg.setPause(aave.hub, states[i], reasons[i]);
            reg.setFrozen(wallets[i], true);
            LiquidationResult memory r = _liquidateAs(keeper, _liqParams(proxy, MARKET_ID, usdcReserveId, X));
            assertEq(r.unitsSeized, C, "settles under the pause and the borrower's freeze");
            reg.setPause(aave.hub, PauseState.None, PauseReason.None);
        }
    }

    /// @notice A primary route that cannot meet its per-leg minimum fails over to the backup in `PrimaryThenBackup`;
    /// `BackupOnly` never calls the primary.
    // TEST-174 verifies: REQ-SWAP-022, REQ-SWAP-025, REQ-SWAP-001, SPEC-LIQ-018
    function test_TEST_174_routeModesThroughRealAdapter() public {
        (address bobProxy_,) = _bobAccount();
        (address aliceProxy_,) = _openAccount(alice, MARKET_ID, 10_000e6, 18_000e6, 250_000_000);
        (address primary,) = reg.getRoute(MARKET_ID, address(usdt), address(usdc), 0);
        usdtUsdcPool.setRate(9000, 10_000);
        uint256 backupSwaps = usdtUsdcPool2.swaps();
        LiquidationParams memory p = _liqParams(bobProxy_, MARKET_ID, usdcReserveId, X);
        address anyEoa = makeAddr("anyEoa");
        _fundCaller(anyEoa, p);
        vm.expectEmit(true, true, false, true, lpVaultSwap);
        emit ILPVaultSwapEvents.RouteFailed(MARKET_ID, address(usdt), primary, ISettlementRoute.MinOutNotMet.selector);
        vm.prank(anyEoa);
        LiquidationResult memory r = lvs.liquidate(p);
        _checkSettlement(r, X, 2047.5e6, usdc);
        assertEq(usdtUsdcPool2.swaps(), backupSwaps + 1, "the backup ran");

        usdtUsdcPool.setRate(9995, 10_000);
        uint256 primarySwaps = usdtUsdcPool.swaps();
        p = _liqParams(aliceProxy_, MARKET_ID, usdcReserveId, X);
        p.routeMode = RouteMode.BackupOnly;
        r = _liquidateAs(makeAddr("otherEoa"), p);
        _checkSettlement(r, X, 2047.5e6, usdc);
        assertEq(usdtUsdcPool.swaps(), primarySwaps, "BackupOnly never calls the primary");
        assertEq(usdtUsdcPool2.swaps(), backupSwaps + 2, "the backup ran again");
    }

    /// @notice Both routes failing refuse the liquidation by name and leave the account, the Adapter's mint record
    /// and Collateralization untouched.
    // TEST-174 verifies: REQ-SWAP-025, REQ-SWAP-042
    function test_TEST_174_bothRoutesFailRevertsWithoutState() public {
        (address proxy,) = _bobAccount();
        usdtUsdcPool.setRate(9000, 10_000);
        usdtUsdcPool2.setRate(9000, 10_000);
        uint256 supplyBefore = token.totalSupply();
        uint256 debtBefore = _debtOf(proxy, usdcReserveId);
        LiquidationParams memory p = _liqParams(proxy, MARKET_ID, usdcReserveId, X);
        usdc.mint(keeper, X);
        vm.startPrank(keeper);
        usdc.approve(lpVaultSwap, X);
        vm.expectRevert(ILPVaultSwapErrors.NoRouteAvailable.selector);
        lvs.liquidate(p);
        vm.stopPrank();
        assertEq(token.totalSupply(), supplyBefore, "nothing burned");
        assertEq(_debtOf(proxy, usdcReserveId), debtBefore, "nothing repaid");
        assertEq(usdc.balanceOf(keeper), X, "the caller keeps its funding");
        assertFalse(lock.isLocked(), "Lock free");
    }

    /// @notice A liquidation while Paused, then the borrower's own exits through the real Adapter: repay of the
    /// remainder, withdrawal of the remaining units and the position back to the wallet.
    // TEST-193 verifies: REQ-ADAPTER-047, REQ-ADAPTER-071, REQ-PROXY-032, REQ-PROXY-035, INV-045, INV-067
    function test_TEST_193_exitsAfterLiquidationWhilePaused() public {
        (address proxy, bytes32 key) = _bobAccount();
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        _liquidateAs(keeper, _liqParams(proxy, MARKET_ID, usdcReserveId, X));
        uint256 owed = _debtOf(proxy, usdcReserveId);
        _repayVia(bob, bob, MARKET_ID, usdcReserveId, owed, true);
        assertEq(_debtOf(proxy, usdcReserveId), 0, "repaid while Paused");
        uint256 left = coll.getRecord(coll.recordIdOf(INTEGRATION, key)).credited;
        _withdrawVia(bob, MARKET_ID, key, left);
        assertEq(vault.ownerOf(key), bob, "the position returned to its depositor");
        assertEq(_suppliedOf(proxy, MARKET_ID), 0, "nothing left supplied");
        assertEq(token.totalSupply(), coll.getTotalCredited(vt), "supply = credited");
    }
}
