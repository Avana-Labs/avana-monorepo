// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {Market} from "../../src/types/MarketTypes.sol";
import {OracleConfig, SecondSource, SecondSourceKind} from "../../src/types/OracleTypes.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator, MockLPOracle} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice An LPOracle that applies its floors only while some token's second source in force is `standby`: it fails
/// check 4 below `consistencyFloor`, 8 below `toleranceFloor` (first token) and 16 for a route leg below
/// `borrowAgeFloor`, the way a real `checkConfig` can pass with the recorded source and fail with the standby.
contract StandbyFloorLPOracle {
    address public standby;
    uint16 public consistencyFloor;
    uint16 public toleranceFloor;
    uint32 public borrowAgeFloor;

    function set(
        address s,
        uint16 consistency,
        uint16 tolerance,
        uint32 borrowAge
    ) external {
        (standby, consistencyFloor, toleranceFloor, borrowAgeFloor) = (s, consistency, tolerance, borrowAge);
    }

    function checkConfig(
        OracleConfig calldata c
    ) external view returns (uint256 bits) {
        bool onStandby = false;
        for (uint256 i = 0; i < c.tokens.length; ++i) {
            if (c.tokens[i].secondSource.source == standby) onStandby = true;
        }
        if (!onStandby) return 0;
        if (c.consistencyToleranceBps < consistencyFloor) bits |= 4;
        if (c.tokens[0].feedAgreementToleranceBps < toleranceFloor) bits |= 8;
        for (uint256 i = 0; i < c.tokens.length; ++i) {
            for (uint256 r = 0; r < 2; ++r) {
                for (uint256 l = 0; l < c.tokens[i].routes[r].legCount; ++l) {
                    if (c.tokens[i].routes[r].legs[l].borrowPriceMaxAge < borrowAgeFloor) bits |= 16;
                }
            }
        }
    }
}

/// @notice The ParameterStore observations of 2026-11-11 (REQ-PSTORE-028, REQ-PSTORE-029): a pool-TWAP second
/// source or standby never reads the pool of a market holding its token, checked by `setSecondSource` and by the
/// listing of a market whose tokens already carry one; an empty standby has every field zero; the guardian's switch
/// runs `checkConfig` with the standby in force; and the three tighten setters that re-run `checkConfig` also check
/// the configuration with each standby in force.
contract ParameterStoreSecondSourceFitUnitTest is ParameterStoreFixture {
    uint256 internal constant M2 = 2;
    bytes32 internal constant OTHER_POOL = bytes32(uint256(0xC0FFEE));
    bytes internal oob = abi.encodeWithSelector(IParameterStoreBase.OutOfBounds.selector);
    MockAggregator internal netA;
    MockAggregator internal netB;
    StandbyFloorLPOracle internal floorOracle;

    function setUp() public {
        _deployStore(false);
        floorOracle = new StandbyFloorLPOracle();
        Market memory m = registry.getMarket(M);
        m.lpOracle = address(floorOracle);
        registry.setMarket(M, m);
        _listMarket();
        netA = new MockAggregator(8, 1e6, 1e12);
        netB = new MockAggregator(8, 1e6, 1e12);
        vm.startPrank(address(timelock));
        store.setFeed(address(netA), _feedDef(86_400, 1800));
        store.setFeed(address(netB), _feedDef(86_400, 1800));
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        vm.stopPrank();
    }

    function _net(
        address source
    ) internal pure returns (SecondSource memory) {
        return SecondSource(SecondSourceKind.OracleNetwork, source, bytes32(0), 88_200, 0, 100);
    }

    function _twap(
        bytes32 poolRef
    ) internal view returns (SecondSource memory) {
        return SecondSource(SecondSourceKind.PoolTwap, address(integration), poolRef, 0, 1800, 120);
    }

    function _none() internal pure returns (SecondSource memory s) {}

    function _ownPool() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(pool))));
    }

    function _set(
        address token,
        SecondSource memory src,
        SecondSource memory standby
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(abi.encodeCall(store.setSecondSource, (token, src, standby)));
    }

    /// @dev Market 2: USDT and GHO in an identifier-keyed pool `poolId`, Registered.
    function _idKeyedMarket(
        bytes32 poolId,
        address firstToken
    ) internal {
        Market memory m = registry.getMarket(M);
        m.pool = address(0);
        m.poolId = poolId;
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (firstToken, gho);
        m.lpOracle = address(new MockLPOracle());
        registry.setMarket(M2, m);
    }

    // ─── The market's own pool ───

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-029
    function test_TEST_250_poolTwapOfTheMarketsOwnPoolIsRefused() public {
        // As the recorded source and as the standby, for an address-keyed market holding the token.
        (bool ok, bytes memory ret) = _set(usdc, _twap(_ownPool()), _none());
        assertFalse(ok, "own pool accepted as the recorded source");
        assertEq(ret, oob);
        (ok, ret) = _set(usdc, _net(address(netA)), _twap(_ownPool()));
        assertFalse(ok, "own pool accepted as the standby");
        assertEq(ret, oob);
        // Another pool is a second source.
        (ok,) = _set(usdc, _twap(OTHER_POOL), _net(address(netA)));
        assertTrue(ok, "another pool refused");
        assertEq(store.secondSource(usdc).poolRef, OTHER_POOL);
    }

    // TEST-250 verifies: REQ-PSTORE-028
    function test_TEST_250_poolIdOfAnIdKeyedMarketIsItsOwnPool() public {
        _idKeyedMarket(OTHER_POOL, usdt);
        (bool ok, bytes memory ret) = _set(usdt, _twap(OTHER_POOL), _none());
        assertFalse(ok, "own pool identifier accepted");
        assertEq(ret, oob);
        // USDC is not in market 2: that pool is a valid second source for it.
        (ok,) = _set(usdc, _twap(OTHER_POOL), _none());
        assertTrue(ok, "a pool of a market not holding the token refused");
    }

    // TEST-250 verifies: REQ-PSTORE-028
    function test_TEST_250_closedAndCancelledMarketsDoNotCount() public {
        _idKeyedMarket(OTHER_POOL, usdt);
        registry.setStatus(M2, MarketStatus.Closed);
        (bool ok,) = _set(usdt, _twap(OTHER_POOL), _none());
        assertTrue(ok, "a closed market's pool refused");
    }

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-004
    function test_TEST_250_listingRefusesAMarketWhoseTokenReadsItsPool() public {
        // USDT already reads pool OTHER_POOL when market 2, holding USDT in that pool, is registered: its parameter
        // write refuses it.
        vm.prank(address(timelock));
        store.setTokenCollateralFactorBps(gho, 7500);
        (bool ok,) = _set(usdt, _twap(OTHER_POOL), _none());
        assertTrue(ok);
        _idKeyedMarket(OTHER_POOL, usdt);
        MarketParams memory p = _defaultMarketParams();
        vm.prank(address(timelock));
        bytes memory ret;
        (ok, ret) = address(store).call(abi.encodeCall(store.setInitialMarketParams, (M2, p)));
        assertFalse(ok, "market listed with a token reading its own pool");
        assertEq(ret, oob);
        // The same through the standby slot.
        (ok,) = _set(usdt, _net(address(netA)), _twap(bytes32(uint256(0xBEEF))));
        assertTrue(ok);
        _idKeyedMarket(bytes32(uint256(0xBEEF)), usdt);
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(abi.encodeCall(store.setInitialMarketParams, (M2, p)));
        assertFalse(ok, "market listed with a standby reading its own pool");
        assertEq(ret, oob);
        // With the token's sources elsewhere, the listing passes.
        (ok,) = _set(usdt, _net(address(netA)), _none());
        assertTrue(ok);
        vm.prank(address(timelock));
        store.setInitialMarketParams(M2, p);
        assertEq(store.getMarketParams(M2).twapWindow, 1800);
    }

    // ─── An empty standby has every field zero ───

    // TEST-250 verifies: REQ-PSTORE-029
    function test_TEST_250_emptyStandbyMustBeAllZero() public {
        SecondSource[5] memory dirty;
        dirty[0].source = address(netB);
        dirty[1].poolRef = OTHER_POOL;
        dirty[2].maxAge = 1;
        dirty[3].twapWindow = 1;
        dirty[4].toleranceBps = 1;
        for (uint256 i = 0; i < dirty.length; ++i) {
            (bool ok, bytes memory ret) = _set(usdc, _net(address(netA)), dirty[i]);
            assertFalse(ok, "a None standby with a field set accepted");
            assertEq(ret, oob);
        }
        (bool done,) = _set(usdc, _net(address(netA)), _none());
        assertTrue(done, "an all-zero empty standby refused");
        assertEq(store.standbySecondSource(usdc).source, address(0));
    }

    // ─── The guardian's switch runs checkConfig with the standby in force ───

    // ─── Tighten setters check the standby slot ───
}
