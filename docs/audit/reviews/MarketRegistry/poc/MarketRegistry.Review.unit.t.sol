// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryCreditLines} from "../../src/policy/market-registry/IMarketRegistryCreditLines.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {AaveV4Fixture} from "../utils/fixtures/AaveV4Fixture.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryFlashSourceMock, RegistryLPVaultMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {Vm} from "forge-std/Vm.sol";

interface ISpokeBatch {
    function getReport() external view returns (address spoke, address implementation, address oracle);
}

/// @notice Review PoCs (not part of the repo).
contract MarketRegistryReviewPoC is MarketRegistryFixture {
    function setUp() public {
        _setUpWorld();
    }

    /// Aave raises the GHO draw cap above the line while the Coverage Spoke is short: the raise cannot be recorded,
    /// so drawCapSum stays below the line and any `sum <= line` gate stays open.
    function test_PoC_syncDrawCapRaiseHiddenWhenCoverageShort() public {
        hub.setSpokeConfig(GHO_ASSET, address(spoke), 0, 30_000_000);
        ghoCoverage.setFunded(3.9e24, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CoverageBelowRatio.selector, address(hub), address(gho), 4e24, 3.9e24
            )
        );
        registry.syncDrawCap(address(spoke), GHO_RESERVE);
        (uint256 line, uint256 sum) = registry.creditLine(address(hub), address(gho));
        assertEq(line, 20_000_000);
        assertEq(sum, 1_000_000, "recorded sum understates the live 30M draw cap");
        // With coverage healthy the same raise is recorded above the line.
        ghoCoverage.setFunded(4e24, false);
        registry.syncDrawCap(address(spoke), GHO_RESERVE);
        (, sum) = registry.creditLine(address(hub), address(gho));
        assertEq(sum, 30_000_000);
    }

    /// closeMarket has no notice period: a debt-free market goes Active -> Offboarding -> Closed in one block.
    function test_PoC_closeMarketSameBlockAsOffboarding() public {
        (uint256 id,,) = _activeMarket();
        vm.prank(address(timelock));
        registry.setMarketOffboarding(id);
        registry.closeMarket(id);
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Closed));
    }

    /// Hour buckets: one caller freezes 40 addresses within 23 h 00 min 01 s.
    function test_PoC_freeze40In23Hours() public {
        uint256 h = 1_000_000;
        vm.warp(h * 3600 + 3599);
        for (uint256 i = 0; i < 20; ++i) {
            vm.prank(emergencyGuardian);
            registry.freezeAddress(address(uint160(0xA000 + i)));
        }
        vm.warp((h + 24) * 3600);
        for (uint256 i = 0; i < 20; ++i) {
            vm.prank(emergencyGuardian);
            registry.freezeAddress(address(uint160(0xB000 + i)));
        }
        assertEq(registry.freezesInWindow(emergencyGuardian), 20);
    }

    /// The DAO's immediate cancel has no lockout: the guardian re-applies the switch in the same block.
    function test_PoC_guardianReswitchesAfterDaoCancel() public {
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(address(usdc), RouteSlot.Primary);
        vm.prank(aaveGovernanceExecutor);
        registry.cancelStandbySwitch(address(usdc));
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(address(usdc), RouteSlot.Primary);
        (,, RouteSlot replaced) = registry.activePriceRoutes(address(usdc));
        assertEq(uint8(replaced), uint8(RouteSlot.Primary));
        assertEq(registry.priceRouteVersion(address(usdc)), 3);
    }

    /// REQ-MREG-006 requires tokens[asset].listed for every debt reserve; a fixed-price asset skips it.
    function test_PoC_fixedPriceDebtAssetEnabledUnlisted() public view {
        assertFalse(registry.getToken(address(gho)).listed);
        assertTrue(registry.isApprovedDebtReserve(address(spoke), GHO_RESERVE));
    }

    /// setFlashSource changes the lender of every liquidation and emits nothing.
    function test_PoC_setFlashSourceEmitsNoEvent() public {
        RegistryFlashSourceMock f2 = new RegistryFlashSourceMock(makeAddr("otherLender"), address(lpVaultSwap));
        vm.recordLogs();
        vm.prank(address(timelock));
        registry.setFlashSource(address(f2));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Only the timelock-free direct call: no registry log at all.
        uint256 n = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(registry)) ++n;
        }
        assertEq(n, 0);
        assertEq(registry.flashSource(), address(f2));
    }
}

/// @notice A second CDP Spoke built from the same audited SpokeInstance code with its own AaveOracle has another
/// code hash (ORACLE and MAX_USER_RESERVES_LIMIT are immutables), so `deployCdpSpoke` refuses it.
contract MarketRegistryReviewSpokePoC is MarketRegistryFixture, AaveV4Fixture {
    function setUp() public {
        _deployAaveV4();
        _deployRegistryWith(aave.cdpSpokeImplementation);
        lpVault = new RegistryLPVaultMock(V3, address(collat), lockAddr);
        lpVault.setRegistry(address(registry));
        vm.prank(address(timelock));
        factory.registerIntegration(V3, address(lpVault));
        vm.startPrank(address(timelock));
        registry.recordHub(aave.hub, RiskTier.Stable);
        registry.registerIntegration(V3, address(lpVault), makeAddr("clPricing"));
        vm.stopPrank();
    }

    function test_PoC_secondCdpSpokeRefusedByCodehash() public {
        bytes memory spokeCode = _linkedSpokeInstanceCode(aave.liquidationLogic);
        address batch = deployCode(
            "out-aave/AaveV4SpokeInstanceBatch.sol/AaveV4SpokeInstanceBatch.json",
            abi.encode(
                aaveDao,
                aave.accessManager,
                spokeCode,
                ORACLE_DECIMALS,
                CDP_SPOKE_USER_RESERVES_LIMIT,
                _childSalt(aave.salt, "spoke", "slipstream-stable")
            )
        );
        (address spoke2, address impl2, address oracle2) = ISpokeBatch(batch).getReport();
        assertTrue(impl2.codehash != aave.cdpSpokeImplementation.codehash, "same code, same limit, other oracle");
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, spoke2));
        registry.deployCdpSpoke(SpokeDef(false, aave.hub, V3, RiskTier.Stable, impl2, oracle2));
    }
}
