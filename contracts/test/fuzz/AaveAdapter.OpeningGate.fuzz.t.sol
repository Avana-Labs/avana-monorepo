// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Oracle} from "../../src/interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";

/// @title AaveAdapterOpeningGateFuzzTest
/// @notice Opening-gate rounding (TEST-077) through the real AaveAdapter and the reviewed RiskModule on the real local
/// Aave V4: whatever the amounts, a borrow or a withdrawal that leaves debt never completes with an exact
/// collateral-to-debt ratio below `max(1, hardHealthFloor)` (1.10 when the floor is set, Aave's 1.00 when it is off),
/// with debt spread over the GHO reserve (18 decimals, $1.00) and the USDC reserve (6 decimals, $0.9999).
/// @dev The exact ratio is recomputed from the AaveOracle prices and the collateral factor of the account's own dynamic key with integer
/// cross-multiplication, no rounding: `units * P_vt * CF * 10^26 >= required * (gho * P_gho + usdc * P_usdc * 10^12)`,
/// the debt read from the Spoke (which rounds owed amounts up).
/// forge-config: default.isolate = false
contract AaveAdapterOpeningGateFuzzTest is AaveAdapterRiskFixture {
    uint256 internal constant FLOOR = 1.1e18;

    bytes32 internal k1;
    bytes32 internal k2;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (k2,) = _pledgeAs(alice, MARKET_ID, UNITS / 4);
    }

    /// @dev Whether the account's exact collateral-to-debt ratio is at least `required` (1e18 = 1.00).
    function _exactRatioAtLeast(
        uint256 required
    ) internal view returns (bool) {
        IAaveV4Spoke s = IAaveV4Spoke(aave.cdpSpoke);
        IAaveV4Oracle o = IAaveV4Oracle(aave.cdpOracle);
        // Hub shares equal assets for the vault-token reserve (Collateralization requires it), so shares are units.
        uint256 units = s.getUserSuppliedShares(vtReserveId, p);
        uint32 key = s.getUserPosition(vtReserveId, p).dynamicConfigKey;
        uint256 cf = s.getDynamicReserveConfig(vtReserveId, key).collateralFactor;
        uint256 lhs = units * o.getReservePrice(vtReserveId) * cf * 1e26;
        uint256 rhs = required
            * (_debtOf(p, debtReserveId)
                * o.getReservePrice(debtReserveId)
                + _debtOf(p, usdcReserveId)
                * o.getReservePrice(usdcReserveId)
                * 1e12);
        return lhs >= rhs;
    }

    function _tryBorrow(
        uint256 reserveId,
        uint256 amount
    ) internal returns (bool ok) {
        uint256 nonce = adapterC.borrowNonce(p);
        uint256 d = _deadline();
        vm.prank(alice);
        (ok,) = adapter.call(abi.encodeCall(adapterC.borrow, (MARKET_ID, reserveId, amount, alice, d, 0, nonce)));
    }

    // TEST-077 verifies: SPEC-CF-005, REQ-RISK-068, INV-082
    // Sources: MATH-AR-03, MATH-AR-06, SYM-05
    /// @notice GHO then USDC borrows of any size, then a withdrawal of the second record with debt left: each call
    /// that completes leaves the exact ratio at or above `max(1, hardHealthFloor)`, and the largest borrows the gate
    /// admits sit within one fuzzed step of the boundary rather than far inside it.
    function testFuzz_TEST_077_noOpeningBelowTheFloor(
        uint256 gho,
        uint256 usdcAmount,
        bool floorOn
    ) public {
        gho = bound(gho, 1e18, 25_000e18);
        usdcAmount = bound(usdcAmount, 1e6, 25_000e6);
        uint256 required = 1e18;
        if (floorOn) {
            rstore.setHardFloor(MARKET_ID, FLOOR);
            required = FLOOR;
        }
        if (_tryBorrow(debtReserveId, gho)) assertTrue(_exactRatioAtLeast(required), "GHO borrow below the floor");
        if (_tryBorrow(usdcReserveId, usdcAmount)) {
            assertTrue(_exactRatioAtLeast(required), "USDC borrow below the floor");
        }
        bool indebted = _debtOf(p, debtReserveId) + _debtOf(p, usdcReserveId) > 0;
        uint256 units = coll.previewRelease(INTEGRATION, k2);
        uint256 d = _deadline();
        vm.prank(alice);
        (bool ok,) = adapter.call(abi.encodeCall(adapterC.withdraw, (MARKET_ID, _ref(k2), units, d, 0)));
        if (ok && indebted) assertTrue(_exactRatioAtLeast(required), "withdrawal with debt below the floor");
    }

    // TEST-077 verifies: SPEC-CF-005, REQ-RISK-068
    /// @notice At the edge: with the floor set, a GHO borrow sized one unit past the exact 1.10 boundary is refused,
    /// and with the floor off a borrow one unit past Aave's 1.00 boundary is refused, whatever USDC debt the account
    /// already carries; the largest admitted borrow leaves the exact ratio at or above the boundary.
    function testFuzz_TEST_077_boundaryBorrowRefused(
        uint256 usdcAmount,
        bool floorOn
    ) public {
        usdcAmount = bound(usdcAmount, 1e6, 10_000e6);
        uint256 required = 1e18;
        if (floorOn) {
            rstore.setHardFloor(MARKET_ID, FLOOR);
            required = FLOOR;
        }
        assertTrue(_tryBorrow(usdcReserveId, usdcAmount), "first USDC borrow");
        // Binary search for the largest GHO amount the gate admits.
        uint256 lo = 0;
        uint256 hi = 40_000e18;
        while (hi - lo > 1e12) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            bool ok = _tryBorrow(debtReserveId, mid);
            vm.revertToState(snap);
            if (ok) lo = mid;
            else hi = mid;
        }
        if (lo == 0) return;
        assertTrue(_tryBorrow(debtReserveId, lo), "largest admitted borrow");
        assertTrue(_exactRatioAtLeast(required), "largest admitted borrow sits at or above the boundary");
        assertFalse(_tryBorrow(debtReserveId, hi - lo), "the next step past the boundary is refused");
    }
}
