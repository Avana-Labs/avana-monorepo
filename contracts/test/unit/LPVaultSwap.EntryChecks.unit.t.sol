// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapLiquidation} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {Market} from "../../src/types/Market.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title LPVaultSwapEntryChecksUnitTest
/// @notice The entry checks of `liquidate` (2.11 REQ-SWAP-004 to REQ-SWAP-007, REQ-SWAP-074, REQ-SWAP-087, REQ-SWAP-105):
/// the deadline as the first check, the caller freeze, the Lock, the amounts, the market and its vault token's
/// immutables, the proxy, the debt reserve, the health factor and the Hub share check, each with its error and each
/// leaving no state change.
/// forge-config: default.isolate = false
contract LPVaultSwapEntryChecksUnitTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @notice `DeadlineExpired(deadline)` is the first check: a frozen caller, a held Lock and a zero amount all
    /// lose to it, and nothing is read or moved.
    // TEST-176 verifies: REQ-SWAP-074, REQ-SWAP-078, Q-216
    function test_TEST_176_deadlineFirstCheck() public {
        LiquidationParams memory p = _params(proxy, 0);
        p.deadline = block.timestamp - 1;
        registry.setFrozen(keeper, true);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DeadlineExpired.selector, p.deadline));
        lvs.liquidate(p);
        // The last valid second is the deadline itself.
        registry.setFrozen(keeper, false);
        p = _params(proxy, 1950e6);
        p.deadline = block.timestamp;
        _fund(usdc, keeper, 1950e6);
        vm.prank(keeper);
        lvs.liquidate(p);
        assertFalse(ILock(address(lock)).isLocked(), "lock released");
    }

    /// @notice `AddressIsFrozen(msg.sender)` right after the deadline; the proxy and the borrower's wallet are never
    /// checked, so a frozen borrower is liquidated like any other.
    // TEST-229 verifies: REQ-SWAP-105, REQ-SWAP-109, Q-242
    function test_TEST_229_frozenCallerRefusedFrozenBorrowerLiquidated() public {
        registry.setFrozen(keeper, true);
        _expectLiquidateRevert(
            keeper, _params(proxy, 1950e6), abi.encodeWithSelector(ILPVaultSwapErrors.AddressIsFrozen.selector, keeper)
        );
        registry.setFrozen(bob, true);
        registry.setFrozen(proxy, true);
        _liquidateAs(carol, _params(proxy, 1950e6));
        assertLt(_debtOf(proxy, usdcReserveId), 18_000e6, "frozen borrower liquidated");
    }

    /// @notice REQ-SWAP-005: `InvalidAmount` for `debtToCover == 0`, `debtToCover` or `maxShortfall` above
    /// `type(uint128).max`, and a `minAmounts` neither empty nor of length n; `type(uint128).max` itself passes the
    /// amount check.
    // TEST-055 verifies: REQ-SWAP-005, REQ-SWAP-041
    function test_TEST_055_invalidAmounts() public {
        bytes memory err = _err(ILPVaultSwapErrors.InvalidAmount.selector);
        LiquidationParams memory p = _params(proxy, 0);
        vm.prank(keeper);
        vm.expectRevert(err);
        lvs.liquidate(p);
        p.debtToCover = uint256(type(uint128).max) + 1;
        vm.prank(keeper);
        vm.expectRevert(err);
        lvs.liquidate(p);
        p.debtToCover = 1950e6;
        p.maxShortfall = uint256(type(uint128).max) + 1;
        vm.prank(keeper);
        vm.expectRevert(err);
        lvs.liquidate(p);
        p.maxShortfall = 0;
        p.minAmounts = new uint256[](1);
        vm.prank(keeper);
        vm.expectRevert(err);
        lvs.liquidate(p);
        p.minAmounts = new uint256[](3);
        vm.prank(keeper);
        vm.expectRevert(err);
        lvs.liquidate(p);
        // A two-entry minimum is accepted and passed to Collateralization.
        p.minAmounts = new uint256[](2);
        p.minAmounts[1] = 1;
        _liquidateAs(keeper, p);
    }

    /// @notice A `minAmounts` above what the unwind returns reverts in Collateralization: the caller's bound can only
    /// make the call revert.
    // TEST-055 verifies: REQ-SWAP-020, REQ-SWAP-046, REQ-SWAP-057
    function test_TEST_055_minAmountsOnlyRevert() public {
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.minAmounts = new uint256[](2);
        (uint256 a0,) = _released(975e6);
        p.minAmounts[0] = a0 + 1;
        _fund(usdc, keeper, 1950e6);
        vm.prank(keeper);
        vm.expectRevert();
        lvs.liquidate(p);
        p.minAmounts[0] = a0;
        vm.prank(keeper);
        lvs.liquidate(p);
    }

    /// @notice `UnknownMarket` for an unlisted market ID and for a record whose vault token reports another Hub, Spoke
    /// or market ID; Registered and Offboarding markets stay liquidatable.
    // TEST-055 verifies: REQ-SWAP-004
    function test_TEST_055_unknownMarket() public {
        bytes memory err = _err(ILPVaultSwapErrors.UnknownMarket.selector);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.marketId = 99;
        _expectLiquidateRevert(keeper, p, err);
        Market memory bad = registry.getMarket(MARKET_ID);
        bad.hub = makeAddr("otherHub");
        registry.setMarket(MARKET_ID, bad);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), err);
        bad = registry.getMarket(MARKET_ID);
        bad.hub = aave.hub;
        bad.spoke = aave.lendSpoke;
        registry.setMarket(MARKET_ID, bad);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), err);
        Market memory m = registry.getMarket(MARKET_ID);
        m.spoke = aave.cdpSpoke;
        registry.setMarket(5, m); // the same record under another ID: the vault token's marketId() differs
        p.marketId = 5;
        _expectLiquidateRevert(keeper, p, err);
        m.status = MarketStatus.Offboarding;
        registry.setMarket(MARKET_ID, m);
        _liquidateAs(keeper, _params(proxy, 1950e6));
    }

    /// @notice `UnknownProxy` unless the market's vault token registered the proxy.
    // TEST-055 verifies: REQ-SWAP-004
    function test_TEST_055_unknownProxy() public {
        address stranger = adapter.createProxy(carol, aave.cdpSpoke, MARKET_ID, vtReserveId);
        _expectLiquidateRevert(keeper, _params(stranger, 1950e6), _err(ILPVaultSwapErrors.UnknownProxy.selector));
        _expectLiquidateRevert(keeper, _params(carol, 1950e6), _err(ILPVaultSwapErrors.UnknownProxy.selector));
    }

    /// @notice `UnknownDebtReserve(r)` for a reserve the MarketRegistry has not enabled for the Spoke and for an enabled
    /// record with no asset; a reserve the Spoke reports not borrowable is still liquidated.
    // TEST-055 verifies: REQ-SWAP-087, REQ-SWAP-095
    function test_TEST_055_unknownDebtReserve() public {
        LiquidationParams memory p = _params(proxy, 1950e6);
        DebtReserveDef memory d = registry.getDebtReserve(aave.cdpSpoke, usdcReserveId);
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, d, false);
        _expectLiquidateRevert(
            keeper, p, abi.encodeWithSelector(ILPVaultSwapErrors.UnknownDebtReserve.selector, usdcReserveId)
        );
        DebtReserveDef memory empty;
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, empty, true);
        _expectLiquidateRevert(
            keeper, p, abi.encodeWithSelector(ILPVaultSwapErrors.UnknownDebtReserve.selector, usdcReserveId)
        );
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, d, true);
        IAaveV4Spoke.ReserveConfig memory cfg = IAaveV4Spoke(aave.cdpSpoke).getReserveConfig(usdcReserveId);
        cfg.borrowable = false;
        vm.mockCall(aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.getReserveConfig, (usdcReserveId)), abi.encode(cfg));
        // An approved reserve Aave reports not borrowable is still liquidated (REQ-SWAP-087, ATTACK-200).
        LiquidationResult memory r = _liquidateAs(keeper, p);
        assertGt(r.unitsSeized, 0, "borrowing off: liquidated");
        vm.clearMockedCalls();
    }

    /// @notice `NotLiquidatable` at `HF ≥ 1`; LPVaultSwap never recomputes the health factor.
    // TEST-055 verifies: REQ-SWAP-006
    function test_TEST_055_healthyAccountRefused() public {
        lpOracle.setAnswer(250_000_000);
        assertGe(_hf(proxy), 1e18, "healthy");
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.NotLiquidatable.selector));
        IAaveV4Spoke.UserAccountData memory data = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(proxy);
        data.healthFactor = 1e18;
        vm.mockCall(aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.getUserAccountData, (proxy)), abi.encode(data));
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.NotLiquidatable.selector));
    }

    /// @notice `SharesNotEqualAssets` unless the vault-token asset's added shares equal its added assets on the Hub.
    // TEST-055 verifies: REQ-SWAP-007, REQ-SWAP-052
    function test_TEST_055_sharesNotEqualAssets() public {
        uint256 assets = IAaveV4Hub(aave.hub).getAddedAssets(vtAssetId);
        vm.mockCall(aave.hub, abi.encodeCall(IAaveV4Hub.getAddedAssets, (vtAssetId)), abi.encode(assets + 1));
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.SharesNotEqualAssets.selector));
    }

    /// @notice `LockHeld(holder)` while the AaveAdapter holds the Lock: nothing is pulled from the caller.
    // TEST-060 verifies: REQ-SWAP-002, REQ-LOCK-005
    function test_TEST_060_lockHeldByAdapter() public {
        _fund(usdc, address(adapter), 1950e6);
        bytes memory call = abi.encodeCall(ILPVaultSwapLiquidation.liquidate, (_params(proxy, 1950e6)));
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.LockHeld.selector, address(adapter)));
        adapter.callUnderLock(call);
        assertEq(usdc.balanceOf(address(adapter)), 1950e6, "nothing pulled");
    }

    /// @notice Check order where several errors apply: amounts before the market, the market before the proxy, the
    /// proxy before the debt reserve, the debt reserve before the health factor.
    // TEST-055 verifies: REQ-SWAP-004, REQ-SWAP-005, REQ-SWAP-006, REQ-SWAP-087
    function test_TEST_055_checkOrder() public {
        LiquidationParams memory p = _params(attacker, 0);
        p.marketId = 99;
        p.debtReserveId = 77;
        _expectLiquidateRevert(keeper, p, _err(ILPVaultSwapErrors.InvalidAmount.selector));
        p.debtToCover = 1;
        _expectLiquidateRevert(keeper, p, _err(ILPVaultSwapErrors.UnknownMarket.selector));
        p.marketId = MARKET_ID;
        _expectLiquidateRevert(keeper, p, _err(ILPVaultSwapErrors.UnknownProxy.selector));
        p.proxy = proxy;
        _expectLiquidateRevert(keeper, p, abi.encodeWithSelector(ILPVaultSwapErrors.UnknownDebtReserve.selector, 77));
        p.debtReserveId = usdcReserveId;
        lpOracle.setAnswer(250_000_000);
        _expectLiquidateRevert(keeper, p, _err(ILPVaultSwapErrors.NotLiquidatable.selector));
    }

    /// @notice A refused call changes nothing: no Lock left held, no funds pulled, no debt or collateral moved.
    // TEST-055 verifies: REQ-SWAP-002, REQ-SWAP-042
    function test_TEST_055_refusalChangesNothing() public {
        lpOracle.setAnswer(250_000_000);
        uint256 debt = _debtOf(proxy, usdcReserveId);
        uint256 units = _suppliedUnits(proxy);
        Snap memory s0 = _snap(keeper);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.NotLiquidatable.selector));
        assertEq(_debtOf(proxy, usdcReserveId), debt, "debt");
        assertEq(_suppliedUnits(proxy), units, "collateral");
        assertEq(usdc.balanceOf(keeper), s0.callerUsdc + 1950e6, "funding never pulled");
        assertFalse(ILock(address(lock)).isLocked(), "lock free");
        _assertNeutral(s0);
    }
}
