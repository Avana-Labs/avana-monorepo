// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Oracle} from "../../src/interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
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
