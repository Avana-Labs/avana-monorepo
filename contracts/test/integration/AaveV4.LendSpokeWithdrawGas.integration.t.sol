// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {
    CollHubSpokeConfig,
    CollInterestRateData,
    CollPriceSource,
    CollSpokeDynamicReserveConfig,
    CollSpokeReserveConfig,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "../utils/fixtures/CollateralizationFixture.sol";
import {AaveV4Fixture} from "../utils/fixtures/AaveV4Fixture.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";

/// @title AaveV4LendSpokeWithdrawGasIntegrationTest
/// @notice Lend Spoke `withdraw(amount)` right after `supply(amount)` on the pinned Aave V4 release (local rehearsal
/// finding 15). A withdraw executed in the same second as the supply costs less gas than the same withdraw one second
/// later, because the Hub's asset accrual runs and writes its timestamp only when time has passed. A gas limit
/// estimated against the supply's block therefore runs out of gas when the withdraw is mined in a later block. The
/// withdraw itself succeeds with enough gas, for the whole amount: there is no share-rounding loss on a fresh supply.
/// forge-config: default.isolate = false
contract AaveV4LendSpokeWithdrawGasIntegrationTest is AaveV4Fixture {
    PayoutToken internal usdc;
    uint256 internal assetId;
    uint256 internal reserveId;
    address internal lender = makeAddr("lender");
    uint256 internal constant AMOUNT = 1_000_000e6;

    function setUp() public {
        _deployAaveV4();
        usdc = new PayoutToken("USDC", 6);
        CollPriceSource price = new CollPriceSource(1e8);
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        vm.startPrank(aaveDao);
        assetId = ICollHubConfigurator(aave.hubConfigurator).addAssetWithDecimals(
            aave.hub, address(usdc), 6, aave.treasurySpoke, 0, aave.irStrategy, abi.encode(CollInterestRateData(9000, 0, 400, 6000))
        );
        ICollHubConfigurator(aave.hubConfigurator).addSpoke(
            aave.hub,
            aave.lendSpoke,
            assetId,
            CollHubSpokeConfig(hubView.MAX_ALLOWED_SPOKE_CAP(), 0, hubView.MAX_RISK_PREMIUM_THRESHOLD(), true, false)
        );
        reserveId = ICollSpokeConfigurator(aave.spokeConfigurator).addReserve(
            aave.lendSpoke,
            aave.hub,
            assetId,
            address(price),
            CollSpokeReserveConfig(0, false, false, true, false),
            CollSpokeDynamicReserveConfig(0, 10_000, 0)
        );
        vm.stopPrank();
        usdc.mint(lender, 2 * AMOUNT);
        vm.prank(lender);
        usdc.approve(aave.lendSpoke, type(uint256).max);
    }

    /// @notice Same second: the withdraw returns the whole amount; one second later it costs more gas.
    function test_withdrawAfterSupplyGasDependsOnElapsedTime() public {
        vm.prank(lender);
        IAaveV4Spoke(aave.lendSpoke).supply(reserveId, AMOUNT, lender);
        uint256 snap = vm.snapshotState();

        vm.prank(lender);
        uint256 g0 = gasleft();
        IAaveV4Spoke(aave.lendSpoke).withdraw(reserveId, AMOUNT, lender);
        uint256 sameSecond = g0 - gasleft();
        assertEq(usdc.balanceOf(lender), 2 * AMOUNT, "whole amount back in the same second");

        vm.revertToState(snap);
        vm.warp(block.timestamp + 1);
        vm.prank(lender);
        g0 = gasleft();
        IAaveV4Spoke(aave.lendSpoke).withdraw(reserveId, AMOUNT, lender);
        uint256 nextSecond = g0 - gasleft();
        assertEq(usdc.balanceOf(lender), 2 * AMOUNT, "whole amount back one second later");

        emit log_named_uint("withdraw gas, same second", sameSecond);
        emit log_named_uint("withdraw gas, one second later", nextSecond);
        assertGt(nextSecond, sameSecond, "accrual after elapsed time costs extra gas");
    }

    /// @notice A gas limit taken from the same-second execution is not enough one second later.
    function test_sameSecondGasLimitRunsOutOfGasLater() public {
        vm.prank(lender);
        IAaveV4Spoke(aave.lendSpoke).supply(reserveId, AMOUNT, lender);
        uint256 snap = vm.snapshotState();
        vm.prank(lender);
        uint256 g0 = gasleft();
        IAaveV4Spoke(aave.lendSpoke).withdraw(reserveId, AMOUNT, lender);
        uint256 sameSecond = g0 - gasleft();
        vm.revertToState(snap);

        vm.warp(block.timestamp + 1);
        vm.prank(lender);
        (bool ok,) = aave.lendSpoke.call{gas: sameSecond}(
            abi.encodeCall(IAaveV4Spoke.withdraw, (reserveId, AMOUNT, lender))
        );
        assertFalse(ok, "the same-second gas limit runs out after time has passed");
    }
}
