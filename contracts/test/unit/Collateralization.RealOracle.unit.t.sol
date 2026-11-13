// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "../../src/custody/collateralization/ICollateralizationAdapter.sol";
import {ICollateralizationUser} from "../../src/custody/collateralization/ICollateralizationUser.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {VaultToken} from "../../src/vault-token/vault-token/VaultToken.sol";
import {AccessTrace} from "../utils/AccessTrace.sol";
import {
    CollHubSpokeConfig,
    CollInterestRateData,
    CollPriceSource,
    CollSpokeDynamicReserveConfig,
    CollSpokeReserveConfig,
    CollateralizationFixture,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "../utils/fixtures/CollateralizationFixture.sol";
import {RealClMarketBuilder} from "../utils/fixtures/RealOracleBuilders.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title CollateralizationRealOracleUnitTest
/// @notice Collateralization with a market whose vault token names the real concentrated-liquidity `LPOracleCL`
/// (market 5, USDC/USDT, on the real local Aave V4, with the real Lock, VaultTokenFactory and vault token): a pledge
/// pokes that oracle before `RiskModule.checkPledge`, and fee collection and debt-free withdrawal never read it
/// (REQ-ORACLE-108).
/// forge-config: default.isolate = false
contract CollateralizationRealOracleUnitTest is CollateralizationFixture {
    using AccessTrace for Vm.AccountAccess[];

    uint256 internal constant MARKET_B = 5;

    RealClMarketBuilder internal cl;
    LPOracleCL internal clOracle;
    address internal poolB = makeAddr("usdcUsdtPoolB");
    VaultToken internal tokenB;
    uint256 internal reserveB;
    address internal proxyB = makeAddr("proxyB");

    function setUp() public {
        cl = new RealClMarketBuilder();
        clOracle = cl.build();
        _deployCollateralization();
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdc), address(usdt));
        uint256[] memory rates = new uint256[](2);
        (rates[0], rates[1]) = (800_000, 1_250_000);
        lpVault.bind(MARKET_B, poolB, tokens, rates);
        vm.prank(timelock);
        tokenB = VaultToken(
            factory.deployVaultToken(
                INTEGRATION,
                poolB,
                bytes32(0),
                PositionShape(ShapeKind.TickRange, -50, 50),
                aave.hub,
                aave.cdpSpoke,
                MARKET_B,
                address(clOracle),
                VT_DECIMALS,
                "Avana USDC/USDT B",
                "avUSDC-USDT-B"
            )
        );
        _listTokenB();
        cl.refresh();
        clOracle.poke{gas: 5_000_000}();
    }

    function _listTokenB() internal {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        bytes memory irData = abi.encode(CollInterestRateData(9000, 0, 400, 6000));
        CollPriceSource price = new CollPriceSource(2e8);
        vm.startPrank(aaveDao);
        uint256 assetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(
                aave.hub, address(tokenB), VT_DECIMALS, aave.treasurySpoke, 0, aave.irStrategy, irData
            );
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(
                aave.hub,
                aave.cdpSpoke,
                assetId,
                CollHubSpokeConfig(5_500_000, 0, hubView.MAX_RISK_PREMIUM_THRESHOLD(), true, false)
            );
        reserveB = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.cdpSpoke,
                aave.hub,
                assetId,
                address(price),
                CollSpokeReserveConfig(0, false, false, false, false),
                CollSpokeDynamicReserveConfig(8000, 10_500, 0)
            );
        vm.stopPrank();
    }

    /// @dev The Adapter's pledge into market B: custody, credit, mint and supply, in one Lock session.
    function _pledgeB(
        address depositor,
        bytes32 key,
        uint128 units
    ) internal {
        lpVault.mintPosition(key, depositor, MARKET_B, units);
        vm.startPrank(adapter);
        lock.acquire();
        if (!tokenB.isValidProxy(proxyB)) tokenB.addValidProxy(proxyB);
        (, uint128 credited) = coll.pledge(depositor, proxyB, address(tokenB), key, false);
        tokenB.mint(proxyB, credited);
        vm.stopPrank();
        vm.startPrank(proxyB);
        tokenB.approve(aave.cdpSpoke, credited);
        IAaveV4Spoke(aave.cdpSpoke).supply(reserveB, credited, proxyB);
        vm.stopPrank();
        vm.prank(adapter);
        lock.release();
    }

    /// @notice A pledge pokes the market's real LPOracle before `RiskModule.checkPledge` reads it, and the poke writes
    /// the oracle's storage before that check.
    // TEST-010 verifies: REQ-ORACLE-108, REQ-VAULT-014
    function test_TEST_010_pledgePokesTheRealLPOracleBeforeCheckPledge() public {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 60);
        cl.refresh();
        vm.startStateDiffRecording();
        _pledgeB(alice, bytes32(uint256(42)), 5_000_000_000);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        (bool poked, uint256 iPoke) = acc.firstCall(address(clOracle), ILPOracle.poke.selector, address(coll), 0);
        (bool checked, uint256 iCheck) =
            acc.firstCall(address(riskModule), IRiskModuleChecks.checkPledge.selector, address(coll), 0);
        assertTrue(poked, "Collateralization poked the market's LPOracle");
        assertTrue(checked, "checkPledge ran");
        assertLt(iPoke, iCheck, "poke before checkPledge");
        assertTrue(acc.wroteStorage(address(clOracle), iPoke, iCheck), "the poke stored state before the check");
        assertEq(coll.getAccountCredited(proxyB, address(tokenB)), 5_000_000_000, "pledged");
    }

    /// @notice Fee collection and debt-free withdrawal through Collateralization never touch the LPOracle: they make no
    /// access to it, and with every oracle call reverting they still complete.
    // TEST-010 verifies: REQ-ORACLE-108, REQ-VAULT-064
    function test_TEST_010_feesAndDebtFreeWithdrawalNeverReadTheLPOracle() public {
        bytes32 key = bytes32(uint256(42));
        _pledgeB(alice, key, 5_000_000_000);
        lpVault.accrueFees(key, 7777);
        vm.mockCallRevert(address(clOracle), bytes(""), "oracle down");
        vm.startStateDiffRecording();
        vm.startPrank(adapter);
        lock.acquire();
        uint256[] memory fees = ICollateralizationUser(address(coll)).collectFees(alice, address(tokenB), key);
        lock.release();
        vm.stopPrank();
        vm.prank(adapter);
        lock.acquire();
        vm.prank(proxyB);
        IAaveV4Spoke(aave.cdpSpoke).withdraw(reserveB, 5_000_000_000, proxyB);
        vm.startPrank(adapter);
        tokenB.burn(proxyB, 5_000_000_000);
        ICollateralizationAdapter(address(coll)).release(proxyB, address(tokenB), key, 5_000_000_000);
        lock.release();
        vm.stopPrank();
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        assertEq(fees[0], 7777, "fees collected");
        assertEq(acc.touches(address(clOracle)), 0, "the LPOracle is never accessed");
        assertEq(coll.getAccountCredited(proxyB, address(tokenB)), 0, "withdrawn");
        assertEq(lpVault.ownerOf(key), alice, "position returned");
    }
}
