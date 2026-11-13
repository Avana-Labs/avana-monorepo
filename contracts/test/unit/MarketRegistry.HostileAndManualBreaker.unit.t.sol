// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice A MarketRegistry implementation that remaps every market to attacker addresses and tries to mint vault
/// tokens from the registry's own address.
contract HostileMarketRegistry {
    address public immutable ATTACKER;

    constructor(
        address attacker
    ) {
        ATTACKER = attacker;
    }

    function proxiableUUID() external pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }

    function mintTo(
        address vaultToken,
        address to,
        uint256 amount
    ) external {
        IVaultToken(vaultToken).mint(to, amount);
    }

    fallback(
        bytes calldata
    ) external returns (bytes memory) {
        return abi.encode(ATTACKER, ATTACKER, ATTACKER, ATTACKER, ATTACKER, ATTACKER, ATTACKER, ATTACKER);
    }
}

/// @title MarketRegistryHostileAndManualBreakerUnitTest
/// @notice The real MarketRegistry proxy upgraded through the timelock to a hostile implementation changes no binding
/// that matters to custody; and route failures open no settlement mode: only the guardian's manual breaker, read by
/// the reviewed RiskModule, stops new borrowing.
contract MarketRegistryHostileAndManualBreakerUnitTest is RiskModuleFixture {
    function setUp() public {
        _deployRiskWorld();
    }

    // TEST-133 verifies: REQ-VTOKEN-012, Q-226, Q-229
    // Sources: 5.1 TEST-133 (hostile MarketRegistry: remapping changes no vault-token binding and mints nothing)
    /// @notice After the registry proxy is upgraded through the timelock to an implementation that maps every market
    /// to attacker addresses, the market's vault token keeps its Hub, Spoke, market, LPOracle, Adapter, LPVaultSwap and
    /// Collateralization; the account's proxy keeps its Spoke and market; a mint from the registry's address reverts;
    /// and the registry holds no vault token or ETH.
    function test_TEST_133_hostileRegistryChangesNoBindingAndMintsNothing() public {
        IVaultToken vtk = IVaultToken(vaultToken);
        address[7] memory before = [
            vtk.hub(),
            vtk.spoke(),
            vtk.lpOracle(),
            vtk.adapter(),
            vtk.lpVaultSwap(),
            vtk.collateralization(),
            vtk.integration()
        ];
        uint256 marketBefore = vtk.marketId();
        address proxySpoke = proxy.SPOKE();
        uint256 proxyMarket = proxy.MARKET_ID();
        uint256 supply = vtk.totalSupply();

        address attacker = makeAddr("attacker");
        HostileMarketRegistry hostile = new HostileMarketRegistry(attacker);
        vm.prank(address(timelock));
        UUPSUpgradeable(address(registry)).upgradeToAndCall(address(hostile), "");
        assertEq(
            HostileMarketRegistry(address(registry)).ATTACKER(), attacker, "the hostile implementation is in force"
        );

        address[7] memory afterwards = [
            vtk.hub(),
            vtk.spoke(),
            vtk.lpOracle(),
            vtk.adapter(),
            vtk.lpVaultSwap(),
            vtk.collateralization(),
            vtk.integration()
        ];
        for (uint256 i = 0; i < 7; ++i) {
            assertEq(afterwards[i], before[i], "vault-token binding unchanged");
            assertTrue(afterwards[i] != attacker, "never the attacker");
        }
        assertEq(vtk.marketId(), marketBefore, "market unchanged");
        assertEq(proxy.SPOKE(), proxySpoke, "proxy Spoke unchanged");
        assertEq(proxy.MARKET_ID(), proxyMarket, "proxy market unchanged");
        vm.expectRevert();
        HostileMarketRegistry(address(registry)).mintTo(vaultToken, attacker, 1e18);
        assertEq(vtk.totalSupply(), supply, "nothing minted");
        assertEq(vtk.balanceOf(address(registry)), 0, "the registry holds no vault token");
        assertEq(address(registry).balance, 0, "the registry holds no ETH");
    }

    // TEST-234 verifies: REQ-MREG-025, Q-251, Q-399, Q-401
    // Sources: 5.1 TEST-234 (no automatic in-kind; the guardian's freeze is the manual breaker)
    /// @notice The registry has no selector that records a route failure or opens another settlement mode; an hour
    /// with three failed liquidation attempts records nothing, so borrowing stays open and no breaker latches. The
    /// Emergency Guardian's `tripMarketBreaker` then makes the reviewed RiskModule refuse a new borrow with
    /// `BreakerTripped(market, MANUAL)`.
    function test_TEST_234_routeFailuresOpenNothingUntilTheGuardianTrips() public {
        string[6] memory absent = [
            "reportRouteFailure(uint256,address,address)",
            "recordRouteFailure(uint256,address)",
            "enableInKind(uint256)",
            "setSettlementMode(uint256,uint8)",
            "settlementMode(uint256)",
            "routeFailureCount(uint256)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok,) = address(registry).call(abi.encodeWithSignature(absent[i], mid, address(tUsdc), address(tGho)));
            assertFalse(ok, absent[i]);
        }
        _debt(1.5e18, 1000);
        for (uint256 i = 0; i < 3; ++i) {
            vm.warp(block.timestamp + 20 minutes);
            riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
            (uint32 latched,) = registry.marketBreaker(mid);
            assertEq(latched, 0, "nothing latched by time or failures");
        }
        vm.prank(emergencyGuardian);
        registry.tripMarketBreaker(mid);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.MANUAL));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }
}
