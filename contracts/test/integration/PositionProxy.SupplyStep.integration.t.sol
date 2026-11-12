// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {VaultTokenAaveV4Base} from "./VaultToken.AaveV4.integration.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @title PositionProxySupplyStepIntegrationTest
/// @notice The collateral supply step run through a real PositionProxy on the standard CDP Spoke of the real local
/// Aave V4: a top-up of an indebted account below health factor 1 supplies through `execute` with no check of its own,
/// and every call the proxy makes in the step goes to the target the Adapter named (the vault token and the Spoke),
/// so no LPOracle, RiskModule, MarketRegistry or other state source is reached from the proxy.
/// @dev The AaveAdapter is a pranked address (its contract comes later); the Adapter's own checks around the step
/// (`ZeroAmount`, `BalanceDeltaMismatch`, `CollateralNotEnabled`) join this step with the AaveAdapter.
contract PositionProxySupplyStepIntegrationTest is VaultTokenAaveV4Base {
    uint256 internal constant TOP_UP = 1_000_000_000; // 1,000 whole tokens

    PositionProxy internal account;

    function setUp() public override {
        super.setUp();
        account = new PositionProxy(adapter, makeAddr("Carol"), aave.cdpSpoke, 1);
        vm.prank(adapter);
        token.addValidProxy(address(account));
    }

    /// @dev The Adapter's supply step through the proxy: exact approval, `Spoke.supply`, approval back to 0.
    function _supplyStep(
        uint256 units
    ) internal {
        vm.startPrank(adapter);
        account.execute(address(token), abi.encodeCall(IERC20.approve, (aave.cdpSpoke, units)));
        account.execute(aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.supply, (vtReserveId, units, address(account))));
        account.execute(address(token), abi.encodeCall(IERC20.approve, (aave.cdpSpoke, 0)));
        vm.stopPrank();
    }

    /// @dev Pledge, enable as collateral and borrow through the proxy, then drop the vault-token price so the account
    /// is below health factor 1 (about 0.86, as in `_pledgeAndBorrowUnderwater`).
    function _openUnderwater() internal {
        vm.prank(adapter);
        token.mint(address(account), UNITS);
        _supplyStep(UNITS);
        vm.startPrank(adapter);
        account.execute(
            aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.setUsingAsCollateral, (vtReserveId, true, address(account)))
        );
        account.execute(aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.borrow, (debtReserveId, BORROWED, address(account))));
        vm.stopPrank();
        vtPrice.set(1.5e8);
    }

    /// @notice A top-up of an indebted account below health factor 1 supplies through the proxy: the step checks no
    /// health factor, price state or pause state, the supplied shares rise by the units, and the proxy keeps no units
    /// and no allowance. Every call the proxy makes in the step is to the vault token or the Spoke the Adapter named;
    /// the proxy calls no LPOracle (no `poke()`), no RiskModule and no MarketRegistry.
    /// @dev Kills: a health-factor, price or registry check added to `execute`, or any call from the proxy to a
    /// contract other than its `target` (the account-access check fails).
    // TEST-032 verifies: REQ-PROXY-010, REQ-PROXY-011, REQ-PROXY-045, REQ-PROXY-078, INV-016
    function test_TEST_032_supplyStepChecksNothingAndCallsOnlyTargets() public {
        _openUnderwater();
        IAaveV4Spoke spoke = IAaveV4Spoke(aave.cdpSpoke);
        assertLt(spoke.getUserAccountData(address(account)).healthFactor, 1e18, "account below HF 1");
        uint256 sharesBefore = spoke.getUserSuppliedShares(vtReserveId, address(account));

        vm.prank(adapter);
        token.mint(address(account), TOP_UP);
        vm.startStateDiffRecording();
        _supplyStep(TOP_UP);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 proxyCalls;
        for (uint256 i = 0; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            if (a.accessor != address(account) || a.kind != VmSafe.AccountAccessKind.Call) continue;
            ++proxyCalls;
            assertTrue(a.account == address(token) || a.account == aave.cdpSpoke, "proxy called another contract");
            assertEq(a.value, 0, "proxy sent ETH");
        }
        assertEq(proxyCalls, 3, "approve, supply, approve 0");
        assertEq(spoke.getUserSuppliedShares(vtReserveId, address(account)) - sharesBefore, TOP_UP, "shares rose");
        assertEq(token.balanceOf(address(account)), 0, "proxy keeps units");
        assertEq(token.allowance(address(account), aave.cdpSpoke), 0, "allowance left");
    }
}
