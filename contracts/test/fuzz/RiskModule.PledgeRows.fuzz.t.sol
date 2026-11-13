// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {stdError} from "forge-std/StdError.sol";

/// @title RiskModulePledgeRowsFuzzTest
/// @notice The reviewed RiskModule's `checkPledge` on the real MarketRegistry (the fixture's market `MID`, 18-decimal
/// vault token, stress floor $1.00, `minPledgeUsd` $10, `marketUsdCap` $1,000,000, depositor cap $5,000,000): its
/// rounding sites (TEST-070), its arithmetic at the listing bounds (TEST-071), and that a pledge it admits stays within
/// the caps and the minimum (TEST-097).
contract RiskModulePledgeRowsFuzzTest is RiskModuleFixture {
    uint256 internal constant STRESS_FLOOR = 1e8;

    function setUp() public {
        _deployRiskWorld();
    }

    function _ceilDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // TEST-070 verifies: SPEC-CAP-001, REQ-RISK-057, REQ-RISK-026
    // Sources: MATH-UO-27, HYP-48
    /// @notice The cap charge rounds up and the `minPledgeUsd` value rounds down, both against the borrower: for any
    /// `L` and accepted price, an admitted pledge books exactly `ceil(L * max(price, stressFloor) / 10^18)`, and a
    /// refused one reports `BelowMinPledge(floor(L * price / 10^18), minPledgeUsd)`.
    function testFuzz_TEST_070_chargeRoundsUpValueRoundsDown(
        uint128 units,
        uint256 price
    ) public {
        units = uint128(bound(units, 1, 300_000e18));
        price = bound(price, 0.5e8, 3e8);
        oracle.setPrices(price, int256(price));
        uint256 value = uint256(units) * price / 1e18;
        uint256 minimum = store.minPledgeUsd(mid);
        PledgeCounters memory k = _counters();
        if (value < minimum) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BelowMinPledge.selector, value, minimum));
            _pledge(units, k, false);
            return;
        }
        PledgeCharge memory c = _pledge(units, k, false);
        uint256 booked = price > STRESS_FLOOR ? price : STRESS_FLOOR;
        assertEq(c.usdCharge, _ceilDiv(uint256(units) * booked, 1e18), "charge rounded up at max(price, floor)");
        assertGe(c.usdCharge * 1e18, uint256(units) * booked, "never below the exact charge");
    }

    // TEST-071 verifies: SPEC-CAP-001, REQ-RISK-057
    // Sources: MATH-UO-29, HYP-41
    /// @notice `L * price8` and the charge never overflow inside the listing bounds: with every cap lifted and `L` up
    /// to `2^128 - 1` at prices up to $10^10 per whole token, `checkPledge` either admits the pledge or refuses it with
    /// one of its own errors, never an arithmetic panic.
    function testFuzz_TEST_071_noOverflowAtTheListingBounds(
        uint128 units,
        uint256 price
    ) public {
        units = uint128(bound(units, 1, type(uint128).max));
        price = bound(price, 1, 1e18);
        oracle.setPrices(price, int256(price));
        store.setCaps(mid, type(uint128).max, 0, STRESS_FLOOR);
        store.setTokenCap(address(hub), address(usdc), type(uint128).max);
        store.setTokenCap(address(hub), address(usdt), type(uint128).max);
        store.setDepositorCap(address(hub), type(uint128).max);
        store.setMinPledge(mid, 0);
        PledgeCounters memory k = _counters();
        try riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), units, k, false) returns (
            PledgeCharge memory c
        ) {
            uint256 booked = price > STRESS_FLOOR ? price : STRESS_FLOOR;
            assertEq(c.usdCharge, _ceilDiv(uint256(units) * booked, 1e18), "exact charge at the bound");
        } catch (bytes memory err) {
            assertTrue(bytes4(err) != bytes4(stdError.arithmeticError), "arithmetic panic");
            assertTrue(keccak256(err) != keccak256(stdError.arithmeticError), "arithmetic panic");
        }
    }

    // TEST-097 verifies: INV-027, INV-028, INV-069, REQ-RISK-021, REQ-RISK-057
    // Sources: MATH-UO-25, HYP-10, HYP-55
    /// @notice Whatever the counters Collateralization passes, a pledge the RiskModule admits leaves the market's
    /// regular counter within `marketUsdCap` and the depositor's within `depositorUsdCap`, and had a value of at least
    /// `minPledgeUsd` at the served price.
    function testFuzz_TEST_097_admittedPledgeStaysWithinTheCaps(
        uint128 units,
        uint256 regularUsed,
        uint256 depositorUsed,
        uint256 price
    ) public {
        units = uint128(bound(units, 1e18, 600_000e18));
        price = bound(price, 0.5e8, 3e8);
        oracle.setPrices(price, int256(price));
        PledgeCounters memory k = _counters();
        k.regularUsed = uint128(bound(regularUsed, 0, 1_100_000e8));
        k.depositorUsed = bound(depositorUsed, 0, 5_500_000e8);
        try riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), units, k, false) returns (
            PledgeCharge memory c
        ) {
            assertLe(uint256(k.regularUsed) + c.usdCharge - c.sliceUsd, store.marketUsdCap(mid), "market cap");
            assertLe(k.depositorUsed + c.usdCharge, store.depositorUsdCap(address(hub)), "depositor cap");
            assertGe(uint256(units) * price / 1e18, store.minPledgeUsd(mid), "minimum value");
        } catch {}
    }
}
