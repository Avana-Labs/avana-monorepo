// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {PauseReason, PauseState} from "../../src/types/MarketTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensPreviewCollateralUnitTest
/// @notice Re-credit and repay-with-collateral previews against the real Aave V4 Spoke and the real Collateralization:
/// every gate and the sizing of SPEC-LIQ-020.
/// forge-config: default.isolate = false
contract LensPreviewCollateralUnitTest is LensFixture {
    uint128 internal constant UNITS = 10_000e6;

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, UNITS);
    }

    // ─── previewRecredit ───

    // TEST-238 verifies: REQ-LENS-038, SPEC-CAP-001, Q-254
    function test_TEST_238_recreditAfterDonation() public {
        (uint128 added, uint256 charge, bool rescue) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(added + charge, 0, "nothing to add");
        assertFalse(rescue, "nothing to book");
        vault.addUnits(_key(1), 2500e6);
        (added, charge, rescue) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(added, coll.previewRecredit(INTEGRATION, _key(1)), "Collateralization's units");
        assertEq(added, 2500e6, "2,500 whole vault tokens");
        assertEq(charge, 5000e8, "at the accepted $2.00");
        assertFalse(rescue, "a regular top-up");
    }

    // TEST-238 verifies: REQ-LENS-038, SPEC-CAP-001
    function test_TEST_238_recreditChargeRoundsUpAtStressFloor() public {
        vault.addUnits(_key(1), 3);
        lpo.setAccepted(199_990_000, uint64(block.timestamp));
        (, uint256 charge,) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(charge, 600, "ceil(3 x 199,990,000 / 1e6)");
        store.setCaps(MARKET_ID, 1_000_000e8, 100_000e8, 3e8);
        (, charge,) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(charge, 900, "stress floor above the accepted price");
    }

    // TEST-238 verifies: REQ-LENS-038, REQ-RISK-066, Q-252
    function test_TEST_238_recreditRescueOnlyCases() public {
        vault.addUnits(_key(1), 2500e6);
        assertFalse(_rescueOnly(), "regular");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        assertTrue(_rescueOnly(), "Paused(General)");
        reg.setPause(aave.hub, PauseState.Frozen, PauseReason.None);
        assertFalse(_rescueOnly(), "Frozen does not force a rescue");
        reg.setPause(aave.hub, PauseState.None, PauseReason.None);
        reg.setFrozen(alice, true);
        assertTrue(_rescueOnly(), "frozen depositor");
        reg.setFrozen(alice, false);
        rm.setMarketBreaker(MARKET_ID, 1 << 11, uint64(block.timestamp + 60));
        assertTrue(_rescueOnly(), "POOL_DEPTH breaker");
        rm.setMarketBreaker(MARKET_ID, 1 | (1 << 10), uint64(block.timestamp + 60));
        assertFalse(_rescueOnly(), "ORACLE and CONFIG_DRIFT never stop a top-up");
        rm.setMarketBreaker(MARKET_ID, 0, 0);
        store.setMinPledgeUsd(MARKET_ID, 5001e8);
        assertTrue(_rescueOnly(), "charge below minPledgeUsd");
    }

    // TEST-238 verifies: REQ-LENS-038
    function test_TEST_238_recreditUnknownPositionReverts() public {
        vm.expectRevert();
        lens.previewRecredit(MARKET_ID, _key(99));
    }

    // ─── previewRepayWithCollateral ───

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020, Q-255
    function test_TEST_239_repayWithCollateralSizing() public {
        _borrow(aliceProxy, 8000e18);
        (uint256 x, uint256 out, uint256 hfAfter) =
            lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 1000e6, debtReserveId);
        uint256 v = 2000e18;
        uint256 vnet = v * 9900 / 1e4 - 2e12 - 1e18;
        uint256 cap = vnet * 1e4 / (1e4 + 10);
        assertEq(x, cap, "x = min(debt, cap)");
        uint256 premium = (x * 5 + 9999) / 1e4;
        assertEq(out, v - x - premium, "V - x - premium");
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy);
        uint256 w = Math.mulDiv(a.avgCollateralFactor, a.totalCollateralValue, 1e18) - 1600e26;
        uint256 debtRay = a.totalDebtValueRay - x * 1e8 * RAY;
        assertEq(hfAfter, Math.mulDiv(w * 1e18, RAY, debtRay), "Aave HF with the units out and x repaid");
        assertGt(hfAfter, a.healthFactor, "the health factor rises");
    }

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020
    function test_TEST_239_repayWithCollateralCappedByDebt() public {
        _borrow(aliceProxy, 100e18);
        (uint256 x, uint256 out, uint256 hfAfter) =
            lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 1000e6, debtReserveId);
        assertEq(x, 100e18, "the whole debt");
        assertEq(out, 2000e18 - 100e18 - 0.05e18, "the rest to the wallet");
        assertEq(hfAfter, type(uint256).max, "no debt remains");
    }

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020
    function test_TEST_239_repayWithCollateralUsdcDebt() public {
        _borrowUsdc(aliceProxy, 8000e6);
        (uint256 x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 1000e6, usdcReserveId);
        uint256 v = uint256(1000e6) * 2e8 * 1e6 / (1e6 * 0.9999e8);
        uint256 vnet = v * 9900 / 1e4 - 3 - 1e6;
        assertEq(x, vnet * 1e4 / (1e4 + 10), "USDC counts 1, one raw USDT 2 units, epsilon 1 USDC");
    }

    // TEST-239 verifies: REQ-LENS-038
    function test_TEST_239_repayWithCollateralRevertCasesReturnZeros() public {
        uint256 hf = _hf(aliceProxy);
        _assertRwcZero(alice, _key(1), 1000e6, debtReserveId, hf, "no debt");
        _borrow(aliceProxy, 8000e18);
        hf = _hf(aliceProxy);
        _assertRwcZero(alice, _key(1), 0, debtReserveId, hf, "zero units");
        _assertRwcZero(alice, _key(1), UNITS + 1, debtReserveId, hf, "above the record's credited units");
        _open(bob, bobProxy, 2, 1000e6);
        _assertRwcZero(alice, _key(2), 100e6, debtReserveId, hf, "another account's record");
        _assertRwcZero(alice, _key(77), 100e6, debtReserveId, hf, "no record");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        _assertRwcZero(alice, _key(1), 100e6, debtReserveId, hf, "Paused(MintPathSuspect)");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        (uint256 x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 100e6, debtReserveId);
        assertGt(x, 0, "Paused(General) leaves repay with collateral open");
        reg.setPause(aave.hub, PauseState.Frozen, PauseReason.None);
        (x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 100e6, debtReserveId);
        assertGt(x, 0, "Frozen leaves repay with collateral open");
        reg.setPause(aave.hub, PauseState.None, PauseReason.None);
        reg.setFrozen(alice, true);
        (x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 100e6, debtReserveId);
        assertGt(x, 0, "a frozen wallet can still repay with collateral (REQ-ADAPTER-082, Q-356)");
    }

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020
    function test_TEST_239_repayWithCollateralThatLowersHealthReturnsZeros() public {
        _borrow(aliceProxy, 15_000e18);
        uint256 hf = _hf(aliceProxy);
        // One whole vault token ($2) repays about $0.98 after the $1 allowance while it removes $1.60 of weighted
        // collateral: the AaveAdapter refuses a repayment that lowers the health factor while debt remains.
        _assertRwcZero(alice, _key(1), 1e6, debtReserveId, hf, "HealthFactorNotImproved");
        (uint256 x,, uint256 after_) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 1000e6, debtReserveId);
        assertGt(x, 0, "a larger repayment improves it");
        assertGt(after_, hf, "and is shown");
    }

    // TEST-239 verifies: REQ-LENS-038
    function test_TEST_239_repayWithCollateralUndeployedProxy() public view {
        (uint256 x, uint256 out, uint256 hf) =
            lens.previewRepayWithCollateral(bob, MARKET_ID, _key(1), 100e6, debtReserveId);
        assertEq(x + out, 0, "no account");
        assertEq(hf, type(uint256).max, "no debt: Aave's max");
    }

    // TEST-239 verifies: REQ-LENS-038, REQ-LENS-032
    function test_TEST_239_repayWithCollateralUnknownReserveReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, 9));
        lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 100e6, 9);
    }

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020
    function test_TEST_239_repayWithCollateralWithinReconciledUnits() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        uint256 seized = _seizeAndKeep(aliceProxy, 3000e18);
        _setVtPrice(2e8);
        uint256 limit = coll.previewRelease(INTEGRATION, _key(1));
        assertEq(limit, UNITS - seized, "credited after reconciliation");
        (uint256 x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(limit), debtReserveId);
        assertGt(x, 0, "within the reconciled units");
        uint256 hf = _hf(aliceProxy);
        _assertRwcZero(alice, _key(1), uint128(limit + 1), debtReserveId, hf, "one unit above");
    }

    // ─── helpers ───

    function _rescueOnly() internal view returns (bool rescue) {
        (,, rescue) = lens.previewRecredit(MARKET_ID, _key(1));
    }

    function _assertRwcZero(
        address wallet,
        bytes32 key,
        uint128 units,
        uint256 reserveId,
        uint256 hf,
        string memory why
    ) internal view {
        (uint256 x, uint256 out, uint256 hfAfter) =
            lens.previewRepayWithCollateral(wallet, MARKET_ID, key, units, reserveId);
        assertEq(x, 0, why);
        assertEq(out, 0, why);
        assertEq(hfAfter, hf, why);
    }
}
