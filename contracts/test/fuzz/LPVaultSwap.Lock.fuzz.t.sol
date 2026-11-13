// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapLiquidation} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {DeleverageRequest} from "../../src/liquidation/lp-vault-swap/types/DeleverageRequest.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapLockFuzzTest
/// @notice LPVaultSwap's Lock rules fuzzed (2.11 REQ-SWAP-002, REQ-SWAP-106; 2.16 REQ-LOCK-005, REQ-LOCK-007,
/// REQ-LOCK-023, REQ-LOCK-030): while the AaveAdapter holds the Lock, `liquidate` with any parameters and
/// `settlePending` of any market revert `LockHeld(adapter)` and change nothing; `deleverage` from any caller other than
/// the AaveAdapter, or from the AaveAdapter without the Lock, reverts `NotAdapter`; after any of these refusals the
/// Lock is free and a normal liquidation settles.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapLockFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;
    bytes32 internal key;

    function setUp() public override {
        super.setUp();
        (proxy, key) = _bobAccount();
    }

    /// @notice Any liquidation parameters under the AaveAdapter's Lock: `LockHeld(adapter)`.
    // TEST-060 verifies: REQ-SWAP-002, REQ-LOCK-005, REQ-LOCK-023
    function testFuzz_TEST_060_liquidateUnderAdapterLock(
        uint256 debtToCover,
        uint256 marketId
    ) public {
        debtToCover = bound(debtToCover, 1, 10_000e6);
        marketId = bound(marketId, MARKET_ID, MARKET_ID + 1);
        bytes memory call =
            abi.encodeCall(ILPVaultSwapLiquidation.liquidate, (_withMarket(_params(proxy, debtToCover), marketId)));
        uint256 debt = _debtOf(proxy, usdcReserveId);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.LockHeld.selector, address(adapter)));
        adapter.callUnderLock(call);
        assertEq(_debtOf(proxy, usdcReserveId), debt, "nothing repaid");
        assertFalse(lock.isLocked(), "Lock free after the refusal");
        assertGt(_liquidateAs(keeper, _params(proxy, 1950e6)).unitsSeized, 0, "a normal liquidation settles after");
    }

    /// @notice `settlePending` of a market with a pending balance under the AaveAdapter's Lock: `LockHeld(adapter)`,
    /// read before the Lock is taken (REQ-LOCK-007), the pending balance unchanged.
    // TEST-060 verifies: REQ-SWAP-066, REQ-LOCK-007, REQ-LOCK-030
    function testFuzz_TEST_060_settlePendingUnderAdapterLock(
        uint256 kept
    ) public {
        kept = bound(kept, 100e6, 2000e6);
        _seizeAndKeep(proxy, kept);
        _liquidateAs(keeper, _params(proxy, 100e6));
        uint256 pending = coll.getPending(address(vt)).units;
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.LockHeld.selector, address(adapter)));
        adapter.callUnderLock(abi.encodeCall(ILPVaultSwapLiquidation.settlePending, (MARKET_ID, usdcReserveId)));
        assertEq(coll.getPending(address(vt)).units, pending, "pending unchanged");
        assertFalse(lock.isLocked(), "Lock free");
    }

    /// @notice `deleverage` from any address other than the AaveAdapter, or from the AaveAdapter without the Lock:
    /// `NotAdapter`.
    // TEST-060 verifies: REQ-SWAP-106, REQ-LOCK-023, PROP-037
    function testFuzz_TEST_060_deleverageOnlyFromAdapterUnderLock(
        address caller,
        uint128 units
    ) public {
        vm.assume(caller != address(adapter));
        DeleverageRequest memory r = DeleverageRequest({
            proxy: proxy,
            wallet: bob,
            spoke: aave.cdpSpoke,
            marketId: MARKET_ID,
            vaultToken: address(vt),
            position: _position(key),
            units: units,
            debtReserveId: usdcReserveId,
            minAmounts: new uint256[](0),
            minDebtRepaid: 0
        });
        vm.prank(caller);
        vm.expectRevert(ILPVaultSwapErrors.NotAdapter.selector);
        lvs.deleverage(r);
        vm.expectRevert(ILPVaultSwapErrors.NotAdapter.selector);
        adapter.deleverageUnlocked(r);
        assertFalse(lock.isLocked(), "Lock free");
    }

    function _withMarket(
        LiquidationParams memory p,
        uint256 marketId
    ) internal pure returns (LiquidationParams memory) {
        p.marketId = marketId;
        return p;
    }
}
