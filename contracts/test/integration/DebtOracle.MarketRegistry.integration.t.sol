// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {IDebtOracleErrors} from "../../src/oracle/debt-oracle/IDebtOracleErrors.sol";
import {IDebtOracleEvents} from "../../src/oracle/debt-oracle/IDebtOracleEvents.sol";
import {DebtOracleInitParams} from "../../src/oracle/debt-oracle/types/DebtOracleInitParams.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {TokenDef} from "../../src/policy/market-registry/types/TokenDef.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {DebtStoreMock} from "../utils/mocks/DebtOracleConfigMocks.sol";
import {RegistryFeedMock, RegistryTokenMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DebtOracleMarketRegistryIntegrationTest
/// @notice A USDC DebtOracle reading the real MarketRegistry (proxy, router and logic contracts): the routes in force,
/// the route version, the token record, and the guardian's standby switch, its cancellation by the Aave governance
/// executor and the timelock's restore, each seen by the DebtOracle in the same block.
contract DebtOracleMarketRegistryIntegrationTest is MarketRegistryFixture {
    DebtStoreMock internal dstore;
    IDebtOracle internal oracle;
    TokenDef internal def;
    address internal impl;

    function setUp() public {
        _setUpWorld();
        vm.warp(1_762_650_000);
        def = registry.getToken(address(usdc));
        dstore = new DebtStoreMock();
        _defineFeeds(def.primaryRoute);
        _defineFeeds(def.alternateRoute);
        _defineFeeds(def.standbyRoute);
        dstore.setTolerance(address(usdc), 100);
        dstore.setStressRise(address(usdc), 500);
        MockAggregator second = new MockAggregator(8, 1e8, block.timestamp);
        dstore.setFeed(address(second), 8, 0, 1e12, 86_400, 1800);
        dstore.setSecondSource(
            address(usdc),
            SecondSource({
                kind: SecondSourceKind.OracleNetwork,
                source: address(second),
                poolRef: bytes32(0),
                maxAge: 88_200,
                twapWindow: 0,
                toleranceBps: 100
            })
        );
        impl = deployCode("DebtOracle.sol:DebtOracle", abi.encode(address(timelock)));
        oracle = IDebtOracle(
            address(new ERC1967Proxy(impl, abi.encodeCall(IDebtOracle.initialize, (_params(address(usdc))))))
        );
    }

    function _defineFeeds(
        address[] memory feeds
    ) internal {
        for (uint256 i = 0; i < feeds.length; ++i) {
            dstore.setFeed(feeds[i], 8, 0, 1e12, 86_400, 1800);
        }
    }

    function _params(
        address asset
    ) internal view returns (DebtOracleInitParams memory) {
        return DebtOracleInitParams({
            timelock: address(timelock),
            asset: asset,
            marketRegistry: address(registry),
            parameterStore: address(dstore),
            description: "USDC / USD",
            pokeMinGas: 600_000
        });
    }

    // TEST-231 verifies: REQ-ORACLE-091, REQ-ORACLE-094, REQ-ORACLE-095, REQ-ORACLE-092, REQ-MREG-028, SPEC-ORC-012, ATTACK-140, Q-248
    // Sources: 5.1 TEST-231 (the DebtOracle can be switched to its standby by the guardian, the switch cancellable only
    // by the Aave governance executor)
    function test_TEST_231_standbySwitchReachesTheDebtOracleAtOnce() public {
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(uint256(v.answer), 1e8);
        assertEq(v.legFeeds[0], def.primaryRoute[0]);
        assertTrue(v.borrowAllowed);

        RegistryFeedMock(def.standbyRoute[0]).setAnswer(95_000_000);
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(address(usdc), RouteSlot.Primary);
        v = oracle.getPriceState();
        assertEq(uint8(v.replaced), uint8(RouteSlot.Primary));
        assertEq(v.primaryValue, 95_000_000, "the standby is read in the primary slot");
        // The served 1.00 is the alternate's value, so the reported legs are the alternate's (SPEC-ORC-012).
        assertEq(v.legFeeds[0], def.alternateRoute[0]);
        assertTrue(v.reasons & (1 << 16) != 0);
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "the standby is held to the agreement check");
        assertEq(uint256(v.answer), 1e8, "max(primary, alternate, accepted)");
        vm.expectEmit(true, true, true, true, address(oracle));
        emit IDebtOracleEvents.DebtRouteVersionObserved(0, 1);
        oracle.poke();
        assertEq(oracle.getPriceState().disagreeSince, uint64(1_762_650_000));

        vm.prank(aaveGovernanceExecutor);
        registry.cancelStandbySwitch(address(usdc));
        v = oracle.getPriceState();
        assertEq(uint8(v.replaced), uint8(RouteSlot.None));
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(v.disagreeSince, 0, "a version change restarts the disagreement window");
        vm.expectEmit(true, true, true, true, address(oracle));
        emit IDebtOracleEvents.DebtRouteVersionObserved(1, 2);
        oracle.poke();
        assertEq(oracle.getPriceState().routeVersion, 2);
    }

    // TEST-231 verifies: REQ-ORACLE-092, REQ-ORACLE-005, REQ-ORACLE-006, REQ-ORACLE-094
    function test_TEST_231_failoverOnRealRoutes() public {
        RegistryFeedMock(def.primaryRoute[0]).setAnswer(0);
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Alternate));
        assertEq(v.legFeeds[0], def.alternateRoute[0]);
        assertEq(v.legFeeds[1], def.alternateRoute[1]);
        // The timelock switches the alternate slot and restores it.
        vm.prank(address(timelock));
        registry.useStandbyRoute(address(usdc), RouteSlot.Alternate);
        assertEq(oracle.getPriceState().legFeeds[0], def.standbyRoute[0]);
        vm.prank(address(timelock));
        registry.restorePriceRoute(address(usdc));
        assertEq(oracle.getPriceState().legFeeds[1], def.alternateRoute[1]);
    }

    // TEST-231 verifies: REQ-ORACLE-091
    function test_TEST_231_unlistedAssetHasNoDebtOracle() public {
        // GHO is listed (every debt asset is, REQ-MREG-006); a token never listed has no DebtOracle.
        address unlisted = address(new RegistryTokenMock(18));
        DebtOracleInitParams memory p = _params(unlisted);
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.NotDebtAsset.selector, unlisted));
        new ERC1967Proxy(impl, abi.encodeCall(IDebtOracle.initialize, (p)));
    }
}
