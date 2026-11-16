// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {UniswapV4State} from "../../src/amm/uniswap-v4/UniswapV4State.sol";
import {IUniswapV4PoolManager} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {UniswapV4IntegrationFixture} from "../utils/fixtures/UniswapV4IntegrationFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title UniswapV4IntegrationRemovalFuzzTest
/// @notice Fuzzed removals and fee reads of the Uniswap v4 LPVault on the local PoolManager. For any liquidity, swap
/// volume, final price (below, inside or above the range) and share removed, the amounts the LPVault computes at
/// `slot0` are exactly what the PoolManager credits and the recipient receives, the depositor receives exactly the
/// fees read beforehand, and the minimums hold at the exact amounts. With the pool's global fee growth started at any
/// point below 2^256, so that the swaps wrap it, the unchecked fee read equals what the PoolManager pays.
/// forge-config: default.isolate = false
contract UniswapV4IntegrationRemovalFuzzTest is UniswapV4IntegrationFixture {
    address internal recipient = makeAddr("recipient");

    // TEST-334 verifies: REQ-AMM-V4-004, SPEC-AMM-V4-003, REQ-AMM-V4-010
    function testFuzz_TEST_334_stableRemovalPaysThePoolManagersCredit(
        uint128 liquidity,
        uint256 wash,
        int256 endTick,
        uint256 share
    ) public {
        liquidity = uint128(bound(liquidity, 1e12, 1e24));
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, liquidity);
        uint128 units = _receive(M1, alice, key);
        _wash(stableKey, bound(wash, 0, 1e12));
        _swapV4To(stableKey, ClPriceMath.sqrtRatioAtTick(int24(bound(endTick, -150, 150))));
        _removeAndCheck(M1, stableKey, key, units, M1_LOWER, M1_UPPER, share);
    }

    // TEST-334 verifies: REQ-AMM-V4-004, SPEC-AMM-V4-003, REQ-AMM-CORE-010
    function testFuzz_TEST_334_nativeEthRemovalPaysThePoolManagersCredit(
        uint128 liquidity,
        uint256 wash,
        int256 endTick,
        uint256 share
    ) public {
        liquidity = uint128(bound(liquidity, 1e15, 1e21));
        bytes32 key = _mintFor(alice, ethKey, M2_LOWER, M2_UPPER, liquidity);
        uint128 units = _receive(M2, alice, key);
        _wash(ethKey, bound(wash, 0, 1e15));
        _swapV4To(ethKey, ClPriceMath.sqrtRatioAtTick(int24(bound(endTick, -208_000, -193_000))));
        _removeAndCheck(M2, ethKey, key, units, M2_LOWER, M2_UPPER, share);
        assertEq(address(vault).balance, 0, "no ETH held");
        assertEq(recipient.balance, 0, "ETH wrapped for the recipient");
    }

    // TEST-334 verifies: REQ-AMM-V4-004, REQ-AMM-CORE-007
    function testFuzz_TEST_334_minimumsHoldAtTheExactAmounts(
        uint128 liquidity,
        int256 endTick,
        bool second
    ) public {
        liquidity = uint128(bound(liquidity, 1e12, 1e24));
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, liquidity);
        uint128 units = _receive(M1, alice, key);
        _swapV4To(stableKey, ClPriceMath.sqrtRatioAtTick(int24(bound(endTick, -150, 150))));
        uint256 snap = vm.snapshotState();
        uint256[] memory exact = _unwind(key, units, _zeros(), recipient);
        vm.revertToState(snap);
        uint256 i = second ? 1 : 0;
        uint256[] memory above = _vec(exact[0], exact[1]);
        above[i] += 1;
        _lock();
        vm.prank(coll);
        vm.expectRevert(abi.encodeWithSelector(BelowMinimum.selector, i, exact[i], exact[i] + 1));
        vault.unwind(key, units, above, recipient);
        _unlock();
        uint256[] memory paid = _unwind(key, units, exact, recipient);
        assertEq(paid[0], exact[0], "token0 at its minimum");
        assertEq(paid[1], exact[1], "token1 at its minimum");
    }

    // TEST-334 verifies: REQ-AMM-V4-010, REQ-VAULT-064
    function testFuzz_TEST_334_wrappedFeeGrowthReadsWhatThePoolManagerPays(
        uint256 below0,
        uint256 below1,
        uint256 wash,
        int256 endTick
    ) public {
        // Global fee growth starts up to 1e30 below 2^256, so the swaps below wrap it.
        bytes32 state = UniswapV4State.poolStateSlot(_poolId(stableKey));
        vm.store(address(pm), bytes32(uint256(state) + 1), bytes32(type(uint256).max - bound(below0, 0, 1e30)));
        vm.store(address(pm), bytes32(uint256(state) + 2), bytes32(type(uint256).max - bound(below1, 0, 1e30)));
        bytes32 key = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        _receive(M1, alice, key);
        _washV4(stableKey, bound(wash, 1e9, 1e14));
        _swapV4To(stableKey, ClPriceMath.sqrtRatioAtTick(int24(bound(endTick, -150, 150))));
        (uint256 f0, uint256 f1) = _feesNow(stableKey, key, M1_LOWER, M1_UPPER);
        (uint256 a0, uint256 a1) = _balances(M1, alice);
        _lock();
        vm.prank(coll);
        uint256[] memory fees = vault.collectFees(key, alice);
        _unlock();
        (uint256 b0, uint256 b1) = _balances(M1, alice);
        assertEq(b0 - a0, f0, "token0 fee read = PoolManager payment");
        assertEq(b1 - a1, f1, "token1 fee read = PoolManager payment");
        assertEq(fees[0], f0, "returned token0 fees");
        assertEq(fees[1], f1, "returned token1 fees");
        (uint256 g0, uint256 g1) = _feesNow(stableKey, key, M1_LOWER, M1_UPPER);
        assertEq(g0 + g1, 0, "nothing owed after the collection");
    }

    // ─── Helpers ───

    /// @dev Removes a fuzzed share of `units` to the recipient and checks the principal against the PoolManager's
    /// credit and the fee step against the fees read before.
    function _removeAndCheck(
        uint256 marketId,
        PoolKey memory k,
        bytes32 key,
        uint128 units,
        int24 lower,
        int24 upper,
        uint256 share
    ) internal {
        uint128 part = uint128(bound(share, 1, units));
        uint256[4] memory before; // fee0, fee1 owed, then the depositor's two balances
        (before[0], before[1]) = _feesNow(k, key, lower, upper);
        (before[2], before[3]) = _balances(marketId, alice);
        uint256[] memory amounts = _unwind(key, part, _zeros(), recipient);
        _assertPaid(marketId, recipient, amounts[0], amounts[1], "principal = PoolManager credit");
        (uint256 b0, uint256 b1) = _balances(marketId, alice);
        assertEq(b0 - before[2], before[0], "token0 fees to the depositor");
        assertEq(b1 - before[3], before[1], "token1 fees to the depositor");
        assertEq(vault.unitsOf(key), units - part, "units left");
    }

    function _assertPaid(
        uint256 marketId,
        address who,
        uint256 e0,
        uint256 e1,
        string memory what
    ) internal view {
        (uint256 r0, uint256 r1) = _balances(marketId, who);
        assertEq(r0, e0, what);
        assertEq(r1, e1, what);
    }

    /// @dev A wash of `amount` each way; none for zero, which the PoolManager refuses (`SwapAmountCannotBeZero`).
    function _wash(
        PoolKey memory k,
        uint256 amount
    ) internal {
        if (amount > 0) _washV4(k, amount);
    }

    /// @dev The fees the PoolManager would credit a PositionManager position now (`Position.update`).
    function _feesNow(
        PoolKey memory k,
        bytes32 positionKey,
        int24 lower,
        int24 upper
    ) internal view returns (uint256 f0, uint256 f1) {
        IUniswapV4PoolManager m = IUniswapV4PoolManager(address(pm));
        bytes32 id = _poolId(k);
        UniswapV4State.PositionState memory p =
            UniswapV4State.position(m, id, UniswapV4State.positionId(address(posm), lower, upper, positionKey));
        (uint256 in0, uint256 in1) = UniswapV4State.feeGrowthInside(m, id, lower, upper);
        (f0, f1) = UniswapV4State.feesOwed(p, in0, in1);
    }
}
