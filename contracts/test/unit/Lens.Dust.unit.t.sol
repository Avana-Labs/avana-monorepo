// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title LensDustUnitTest
/// @notice The dust branch of the ready-to-send parameters on its own: a partial liquidation whose remainder lies
/// between Aave's $1,000 dust threshold and the Lens's $1,050 margin asks for the margined whole debt, one just above
/// the margin asks for Aave's size, for an 18-decimal and a 6-decimal debt asset; and the Aave paused flag of the debt
/// reserve.
/// forge-config: default.isolate = false
contract LensDustUnitTest is LensFixture {
    uint256 internal constant LOW = 1000e8;
    uint256 internal constant HIGH = 1050e8;

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
    }

    // TEST-069 verifies: REQ-LENS-028, Q-268
    function test_TEST_069_ghoRemainderInsideTheMarginIsMargined() public {
        _borrow(aliceProxy, 5000e18);
        LiquidationPreview memory p = _findRemainder(debtReserveId, 1e18, LOW, HIGH);
        uint256 total = _debtOf(aliceProxy, debtReserveId);
        assertEq(p.params.debtToCover, (total * 10_500 + 9999) / 10_000, "remainder in ($1,000, $1,050): margined");
        (uint256 repaid,) = _execute(address(debt), debtReserveId, p.params.debtToCover);
        assertEq(repaid, p.expectedDebtRepaid, "Aave still repays its own size");
    }

    // TEST-069 verifies: REQ-LENS-028
    function test_TEST_069_ghoRemainderAboveTheMarginIsExact() public {
        _borrow(aliceProxy, 5000e18);
        LiquidationPreview memory p = _findRemainder(debtReserveId, 1e18, HIGH, 1100e8);
        assertEq(p.params.debtToCover, p.expectedDebtRepaid, "remainder above $1,050: Aave's size");
    }

    // TEST-069 verifies: REQ-LENS-028
    function test_TEST_069_usdcRemainderInsideTheMarginIsMargined() public {
        _borrowUsdc(aliceProxy, 5000e6);
        LiquidationPreview memory p = _findRemainder(usdcReserveId, 1e6, LOW, HIGH);
        uint256 total = _debtOf(aliceProxy, usdcReserveId);
        assertEq(p.params.debtToCover, (total * 10_500 + 9999) / 10_000, "6-decimal debt valued at its decimals");
    }

    // TEST-069 verifies: REQ-LENS-028
    function test_TEST_069_usdcRemainderAboveTheMarginIsExact() public {
        _borrowUsdc(aliceProxy, 5000e6);
        LiquidationPreview memory p = _findRemainder(usdcReserveId, 1e6, HIGH, 1100e8);
        assertEq(p.params.debtToCover, p.expectedDebtRepaid, "remainder above $1,050 at $0.9999: Aave's size");
    }

    // TEST-069 verifies: REQ-LENS-016
    function test_TEST_069_debtReservePausedFlag() public {
        _setReservePaused(debtReserveId, true);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, T0);
        assertTrue(p.debtReservePaused, "liquidationCall would revert ReservePaused");
        assertFalse(lens.previewLiquidation(aliceProxy, usdcReserveId, T0).debtReservePaused, "the other reserve");
    }

    // ─── helpers ───

    /// @dev Binary search of the vault-token price for a partial liquidation whose remainder, valued at the debt
    /// reserve's Aave price, lies in [lo, hi) (8-decimal USD). The remainder shrinks as the price falls.
    function _findRemainder(
        uint256 reserveId,
        uint256 unit,
        uint256 lo,
        uint256 hi
    ) internal returns (LiquidationPreview memory p) {
        uint256 low = 0.3e8;
        uint256 high = 0.64e8;
        for (uint256 i = 0; i < 64; ++i) {
            uint256 mid = (low + high) / 2;
            _setVtPrice(int256(mid));
            p = lens.previewLiquidation(aliceProxy, reserveId, T0);
            uint256 rest = _debtOf(aliceProxy, reserveId) - p.expectedDebtRepaid;
            uint256 price = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy).healthFactor >= 1e18
                ? 0
                : _reservePrice(reserveId);
            uint256 value = rest * price / unit;
            if (p.expectedDebtRepaid != 0 && value >= lo && value < hi) return p;
            if (p.expectedDebtRepaid == 0 || value >= hi) high = mid;
            else low = mid;
        }
        revert("no price gives a remainder in the band");
    }

    function _reservePrice(
        uint256 reserveId
    ) internal view returns (uint256 price) {
        (bool ok, bytes memory data) =
            aave.cdpOracle.staticcall(abi.encodeWithSignature("getReservePrice(uint256)", reserveId));
        require(ok, "price");
        price = abi.decode(data, (uint256));
    }

    function _execute(
        address asset,
        uint256 reserveId,
        uint256 debtToCover
    ) internal returns (uint256 repaid, uint256 seized) {
        CollPoolToken(asset).mint(lpVaultSwap, debtToCover);
        uint256 before = CollPoolToken(asset).balanceOf(lpVaultSwap);
        uint256 units = token.balanceOf(lpVaultSwap);
        vm.startPrank(lpVaultSwap);
        CollPoolToken(asset).approve(aave.cdpSpoke, debtToCover);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, reserveId, aliceProxy, debtToCover, false);
        vm.stopPrank();
        (repaid, seized) = (before - CollPoolToken(asset).balanceOf(lpVaultSwap), token.balanceOf(lpVaultSwap) - units);
    }
}
