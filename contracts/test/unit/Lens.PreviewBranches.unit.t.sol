// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Oracle} from "../../src/interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensPreviewBranchesUnitTest
/// @notice Borrower previews at their price edges: a debt reserve Aave prices at 0, a re-credit booked at a fresh
/// LPOracle answer below the accepted price, and a repay with collateral while the LPOracle serves no positive answer.
/// forge-config: default.isolate = false
contract LensPreviewBranchesUnitTest is LensFixture {
    uint128 internal constant UNITS = 10_000e6;

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, UNITS);
    }

    // ─── previewBorrowMax / previewBorrowRecommended ───

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-044, REQ-LENS-007
    /// @notice Alice holds $20,000 of collateral at CF 80 % and no debt. Aave's oracle answers 0 for the GHO reserve:
    /// a debt unit worth 0 gives no capacity to divide, so both previews are 0 rather than a division by zero, while
    /// the USDC reserve (priced $0.9999) keeps its capacity.
    function test_TEST_247_borrowPreviewZeroWhenTheDebtUnitHasNoPrice() public {
        address oracle = IAaveV4Spoke(aave.cdpSpoke).ORACLE();
        uint256 usdcBefore = lens.previewBorrowMax(alice, MARKET_ID, usdcReserveId, block.timestamp);
        assertGt(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), 0, "priced: capacity");
        vm.mockCall(
            oracle, abi.encodeWithSelector(IAaveV4Oracle.getReservePrice.selector, debtReserveId), abi.encode(0)
        );
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertEq(rec, 0, "no recommended borrow at a zero unit value");
        assertEq(max, 0, "no maximum borrow at a zero unit value");
        assertEq(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), 0, "previewBorrowMax too");
        assertEq(lens.previewBorrowMax(alice, MARKET_ID, usdcReserveId, block.timestamp), usdcBefore, "USDC unaffected");
        vm.clearMockedCalls();
    }

    // ─── previewRecredit ───

    // TEST-238 verifies: REQ-LENS-038, SPEC-CAP-001
    /// @notice 2,500 whole vault tokens are donated to Alice's position. The accepted price is $2.00 and the stress
    /// floor $1.00. A fresh answer of $1.50 books the re-credit at $1.50 (3,750 USD); a fresh answer of $2.50 above the
    /// accepted price leaves $2.00 (5,000 USD); a fresh answer of $0.50 is lifted to the $1.00 floor (2,500 USD); a
    /// non-positive fresh answer leaves the accepted $2.00.
    function test_TEST_238_recreditBookedAtTheLowerFreshAnswer() public {
        vault.addUnits(_key(1), 2500e6);
        _setFresh(1.5e8);
        (uint128 added, uint256 charge, bool rescue) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(added, 2500e6, "2,500 whole vault tokens");
        assertEq(charge, 3750e8, "2,500 x $1.50: min(fresh, accepted)");
        assertFalse(rescue, "a regular top-up");
        _setFresh(2.5e8);
        (, charge,) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(charge, 5000e8, "a fresh answer above the accepted price leaves $2.00");
        _setFresh(0.5e8);
        (, charge,) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(charge, 2500e8, "the $1.00 stress floor lifts a $0.50 fresh answer");
        _setFresh(-1);
        (, charge,) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(charge, 5000e8, "a negative fresh answer leaves the accepted price");
        vm.clearMockedCalls();
    }

    // ─── previewRepayWithCollateral ───

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020, REQ-LENS-007
    /// @notice Alice owes 8,000 GHO. Every gate of a repay with collateral passes (Live, fresh inputs, fixed-price
    /// GHO), but the LPOracle's served answer is 0, then -1: the collateral price `Pc = min(Aave, LPOracle)` is 0, so
    /// SPEC-LIQ-020 sizes nothing and the preview returns zeros with the current health factor, never a revert. At
    /// the $2.00 answer the same 1,000 units repay a positive amount.
    function test_TEST_239_repayWithCollateralZeroCollateralPrice() public {
        _borrow(aliceProxy, 8000e18);
        uint256 hf = _hf(aliceProxy);
        (uint256 x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 1000e6, debtReserveId);
        assertGt(x, 0, "priced: a positive repayment");
        lpo.setAnswer(true, 0);
        _assertRwcZero(hf, "an LPOracle answer of 0");
        lpo.setAnswer(true, -1);
        _assertRwcZero(hf, "a negative LPOracle answer counts 0");
        lpo.setAnswer(false, 0);
        (x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 1000e6, debtReserveId);
        assertGt(x, 0, "the answer back: sized again");
    }

    // ─── helpers ───

    /// @dev Mocks the LPOracle's `getPriceState` with its current view and `freshAnswer` set.
    function _setFresh(
        int256 fresh
    ) internal {
        vm.clearMockedCalls();
        PriceStateView memory v = lpo.getPriceState();
        v.freshAnswer = fresh;
        vm.mockCall(address(lpo), abi.encodeWithSelector(lpo.getPriceState.selector), abi.encode(v));
    }

    function _assertRwcZero(
        uint256 hf,
        string memory why
    ) internal view {
        (uint256 x, uint256 out, uint256 hfAfter) =
            lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 1000e6, debtReserveId);
        assertEq(x, 0, why);
        assertEq(out, 0, why);
        assertEq(hfAfter, hf, why);
    }
}
