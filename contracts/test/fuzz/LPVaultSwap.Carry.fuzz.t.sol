// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapCarryFuzzTest
/// @notice The sub-share carry of pending settlement fuzzed (2.11 REQ-SWAP-070, REQ-FLR-038): for any number of
/// settlements whose `R` the Hub would mint no share for (`previewAddByAssets(R + carry) = 0`), the amount is kept as
/// LPVaultSwap's carry for that market, never funded and never paid out; the first settlement whose `R + carry` buys at
/// least one share funds exactly `R + carry` into the Coverage Spoke and clears the carry; residues of every
/// settlement go to `feeRecipient`, never to the caller.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 128
contract LPVaultSwapCarryFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    function _pendingOf(
        uint256 debtToCover
    ) internal {
        _seizeAndKeep(proxy, debtToCover);
        _liquidateAs(keeper, _params(proxy, 100e6));
    }

    /// @notice `k` carried settlements then one funded: the funded amount is the sum of every `R`.
    // TEST-170 verifies: REQ-SWAP-070, REQ-SWAP-042, REQ-FLR-038, Q-211
    function testFuzz_TEST_170_carryAccumulatesThenFunds(
        uint8 k,
        uint256 size
    ) public {
        k = uint8(bound(k, 1, 3));
        size = bound(size, 50e6, 250e6);
        uint256 fundedBefore = usdcCoverage.fundedBalance();
        uint256 carried = 0;
        for (uint256 i = 0; i < k; ++i) {
            _pendingOf(size);
            // Only the settlement sees a Hub that would mint no share; Aave's own liquidation runs unmocked.
            vm.mockCall(
                aave.hub, abi.encodeWithSelector(IAaveV4Hub.previewAddByAssets.selector), abi.encode(uint256(0))
            );
            (,, uint256 added) = lvs.settlePending(MARKET_ID, usdcReserveId);
            vm.clearMockedCalls();
            carried += added;
            assertEq(usdcCoverage.fundedBalance(), fundedBefore, "a sub-share amount is not funded");
            assertEq(usdc.balanceOf(address(lvs)), carried, "carried in LPVaultSwap's balance");
        }
        _pendingOf(size);
        address caller = makeAddr("anyCaller");
        vm.prank(caller);
        (,, uint256 last) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(usdcCoverage.fundedBalance(), fundedBefore + carried + last, "R + carry funded");
        assertEq(usdc.balanceOf(address(lvs)), 0, "carry cleared");
        assertEq(usdc.balanceOf(caller), 0, "the caller receives nothing");
    }

    /// @notice A carry never leaks into a liquidation: a liquidation between carried settlements settles to the same
    /// figures as without the carry, and the carry is untouched by it.
    // TEST-170 verifies: REQ-SWAP-070, REQ-SWAP-042, SPEC-LIQ-006
    function testFuzz_TEST_170_carryInvisibleToLiquidation(
        uint256 size,
        uint256 debtToCover
    ) public {
        size = bound(size, 50e6, 400e6);
        debtToCover = bound(debtToCover, 50e6, 1500e6);
        uint256 snapshot = vm.snapshotState();
        _pendingOf(size);
        uint256 clean = _liquidateAs(keeper, _params(proxy, debtToCover)).keeperOut;
        vm.revertToState(snapshot);
        _pendingOf(size);
        vm.mockCall(aave.hub, abi.encodeWithSelector(IAaveV4Hub.previewAddByAssets.selector), abi.encode(uint256(0)));
        (,, uint256 carried) = lvs.settlePending(MARKET_ID, usdcReserveId);
        vm.clearMockedCalls();
        uint256 withCarry = _liquidateAs(keeper, _params(proxy, debtToCover)).keeperOut;
        assertApproxEqAbs(withCarry, clean, 2, "the carry changes no liquidation figure");
        assertEq(usdc.balanceOf(address(lvs)), carried, "the carry is untouched");
    }
}
