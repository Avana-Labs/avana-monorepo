// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {SettlementReport} from "../../src/types/SettlementReport.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";

/// @title LPVaultSwapRoundingFuzzTest
/// @notice Rounding, overflow and route-output properties of real liquidations on the real LPVaultSwap, its
/// `DexPathRoute` swap routes and the local Aave V4: every LPVaultSwap rounding site rounds against the caller and the
/// gaps stay with it (TEST-070); the debt-unit conversions never overflow for 6- and 18-decimal debt assets across
/// the feed bounds (TEST-071); route output at any spot within the effective slippage meets the floor (TEST-217).
/// forge-config: default.isolate = false
contract LPVaultSwapRoundingFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @notice For any repayment and collateral price: the effective slippage is rounded down
    /// (`s·b ≤ 10⁴·(b − 10⁴)`), the floor is `⌈V (10⁴ − s) / 10⁴⌉ − U − ε` (rounded up before the subtractions), the
    /// Avana fee is rounded down (`A·10⁴ ≤ gain × feeShare`), and LPVaultSwap ends with no debt asset, so every
    /// rounding gap of the settlement falls in the caller's `keeperOut`.
    // TEST-070 verifies: SPEC-LIQ-003, SPEC-LIQ-005, SPEC-LIQ-008, REQ-SWAP-042
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_TEST_070_settlementRoundsAgainstTheCaller(
        uint256 x,
        uint256 price
    ) public {
        x = bound(x, 50e6, 1950e6);
        price = bound(price, 160_000_000, 220_000_000);
        lpOracle.setAnswer(int256(price));
        LiquidationParams memory p = _params(proxy, x);
        p.maxShortfall = x / 20;
        vm.recordLogs();
        LiquidationResult memory r = _liquidateAs(keeper, p);
        (SettlementReport memory rep,) = _settledReport(vm.getRecordedLogs());
        uint256 b = rep.bonusBps;
        uint256 s = rep.effectiveSlippageBps;
        assertEq(s, _slippageOf(b, SLIPPAGE_BPS), "s");
        if (b > BPS) assertLe(s * b, BPS * (b - BPS), "s rounds down");
        // The LPOracle stand-in is also the AaveOracle source here, so both collateral prices are `price`.
        uint256 v = _valueOf(r.unitsSeized, price, PRICE_UNIT, 6);
        uint256 cut = 2 + FLOOR_ROUNDING_ALLOWANCE_USDC;
        assertEq(r.minOut, _floorOf(v, s, 2, FLOOR_ROUNDING_ALLOWANCE_USDC), "minRec");
        if (r.minOut > 0) assertGe((r.minOut + cut) * BPS, v * (BPS - s), "floor rounds up before U and eps");
        uint256 gain = v > r.debtRepaid ? v - r.debtRepaid : 0;
        assertLe(r.avanaFee * BPS, gain * AVANA_FEE_SHARE_BPS, "fee rounds down");
        assertEq(r.shortfall, r.minOut > r.recovered ? r.minOut - r.recovered : 0, "the caller tops up only the gap");
        assertEq(usdc.balanceOf(address(lvs)), 0, "no USDC left in LPVaultSwap");
        assertEq(usdt.balanceOf(address(lvs)), 0, "no USDT left in LPVaultSwap");
    }

    /// @notice No overflow in the recovery floor's debt-unit conversions: for USDC (6 decimals) and GHO (18 decimals)
    /// debt, leg prices anywhere in the feeds' accepted range `[1, 10¹²]` (8 decimals) and any collateral price in
    /// `[1, 10¹²]`, a liquidation either settles or reverts with a named error, never with an arithmetic panic.
    // TEST-071 verifies: SPEC-LIQ-005, SPEC-LIQ-018, REQ-SWAP-021
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_TEST_071_noOverflowInTheDebtUnitConversions(
        uint256 leg0,
        uint256 leg1,
        uint256 price,
        bool useGho
    ) public {
        (address ghoProxy,) = _openGhoAccount();
        uint256[] memory prices = new uint256[](2);
        prices[0] = bound(leg0, 1, 1e12);
        prices[1] = bound(leg1, 1, 1e12);
        lpOracle.setPrices(prices);
        lpOracle.setAnswer(int256(bound(price, 1, 1e12)));
        LiquidationParams memory p = useGho ? _ghoParams(ghoProxy, 1000e18) : _params(proxy, 1000e6);
        PayoutToken asset = useGho ? gho : usdc;
        _fund(asset, keeper, p.debtToCover);
        vm.prank(keeper);
        (bool ok, bytes memory err) = address(lvs).call(abi.encodeCall(lvs.liquidate, (p)));
        if (!ok && err.length >= 4) {
            assertTrue(bytes4(err) != bytes4(keccak256("Panic(uint256)")), "no arithmetic panic");
        }
    }

    /// @notice Route output meets the floor at any spot within the effective slippage: with the USDT pools priced
    /// anywhere from the oracle rate down to `(1 − s)` of it (s = 100 bps at Aave's bonus of 10,500), the USDT leg goes
    /// through a route and the liquidation settles with `R ≥ minRec` and no shortfall.
    // TEST-217 verifies: SPEC-LIQ-005, SPEC-LIQ-018, INV-034
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_TEST_217_routeOutputMeetsTheFloorWithinSlippage(
        uint256 rate
    ) public {
        rate = bound(rate, 9900, 10_000);
        usdtUsdcPool.setRate(rate * 9995 / 10_000, 10_000);
        usdtUsdcPool2.setRate(rate * 9995 / 10_000, 10_000);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGe(r.recovered, r.minOut, "R >= minRec");
        assertEq(r.shortfall, 0, "no shortfall");
    }

    function _ghoParams(
        address p,
        uint256 x
    ) internal view returns (LiquidationParams memory q) {
        q = _params(p, x);
        q.debtReserveId = ghoReserveId;
    }

    /// @dev Carol borrows GHO against 10,000 units pledged at $2.50; at $2.10 her HF is below 1.
    function _openGhoAccount() internal returns (address p, bytes32 key) {
        (p, key) = _openAccount(carol, 10_000e6, 0, 250_000_000);
        lpOracle.setAnswer(250_000_000);
        adapter.borrow(p, ghoReserveId, address(gho), 18_000e18, carol);
        lpOracle.setAnswer(int256(P_VAULT));
    }
}
