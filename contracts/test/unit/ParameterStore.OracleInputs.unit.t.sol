// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {OracleInputsLayout} from "../../src/policy/parameter-store/types/OracleInputsLayout.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice `getOracleInputs`, the one configuration read of an LPOracle evaluation: every word equals the stored
/// value or the MarketRegistry's answer it stands for, in the layout of `OracleInputsLayout`.
contract ParameterStoreOracleInputsUnitTest is ParameterStoreFixture {
    MockAggregator internal ssUsdc;
    MockAggregator internal ssUsdt;
    address[] internal list;

    uint256 internal constant H = OracleInputsLayout.HEAD_WORDS;
    uint256 internal constant T = OracleInputsLayout.TOKEN_WORDS;
    uint256 internal constant S = OracleInputsLayout.SECOND_WORDS;
    uint256 internal constant L = OracleInputsLayout.LEG_WORDS;

    function setUp() public {
        _deployStore(false);
        _listMarket();
        ssUsdc = new MockAggregator(8, 1e6, 1e12);
        ssUsdt = new MockAggregator(8, 1e6, 1e12);
        vm.startPrank(address(timelock));
        store.setFeed(address(ssUsdc), _feedDef(86_400, 1800));
        store.setFeed(address(ssUsdt), _feedDef(86_400, 1800));
        SecondSource memory standby =
            SecondSource(SecondSourceKind.PoolTwap, address(integration), bytes32(uint256(7)), 0, 1800, 120);
        store.setSecondSource(usdc, _second(address(ssUsdc)), standby);
        SecondSource memory none;
        store.setSecondSource(usdt, _second(address(ssUsdt)), none);
        vm.stopPrank();
        list.push(usdc);
        list.push(usdt);
    }

    function _second(
        address source
    ) internal pure returns (SecondSource memory) {
        return SecondSource(SecondSourceKind.OracleNetwork, source, bytes32(0), 88_200, 0, 100);
    }

    function _assertLeg(
        uint256[] memory w,
        uint256 k,
        address feed
    ) internal view {
        FeedDef memory d = store.getFeed(feed);
        assertEq(w[k], uint160(feed), "aggregator");
        assertEq(w[k + 1], d.decimals, "decimals");
        assertEq(int256(w[k + 2]), d.minAnswer, "minAnswer");
        assertEq(int256(w[k + 3]), d.maxAnswer, "maxAnswer");
        assertEq(w[k + 4], d.feedHeartbeat, "heartbeat");
        assertEq(w[k + 5], d.heartbeatMargin, "margin");
        assertEq(w[k + 6], d.borrowPriceMaxAge, "borrow age");
        assertEq(w[k + 7], d.liquidationPriceMaxAge, "liquidation age");
    }

    // TEST-250 verifies: REQ-PSTORE-033, REQ-PSTORE-011, REQ-CONFIG-072, REQ-ORACLE-094, REQ-ORACLE-017
    function test_TEST_250_oracleInputsMatchTheConfiguration() public view {
        uint256[] memory w = store.getOracleInputs(address(lpOracle), list, true);
        assertEq(w.length, H + 2 * (T + S), "length");
        MarketParams memory p = store.getMarketParams(M);
        (address seqFeed, uint32 seqGrace) = store.sequencer();
        assertEq(w[0], M, "marketId");
        assertEq(w[1], p.twapWindow, "twapWindow");
        assertEq(w[2], p.consistencyToleranceBps, "consistencyToleranceBps");
        assertEq(w[3], store.usdBandLow(), "usdBandLow");
        assertEq(w[4], store.usdBandHigh(), "usdBandHigh");
        assertEq(w[5], store.cachedWindow(), "cachedWindow");
        assertEq(w[6], store.disagreementPauseMax(), "disagreementPauseMax");
        assertEq(w[7], store.graceDuration(), "graceDuration");
        assertEq(w[8], uint160(seqFeed), "sequencer feed");
        assertEq(w[9], seqGrace, "sequencer grace");
        address[2] memory primary = [address(fUsdc), address(fUsdt)];
        address[2] memory alternate = [address(fUsdcAlt), address(fUsdtAlt)];
        MockAggregator[2] memory second = [ssUsdc, ssUsdt];
        for (uint256 i = 0; i < 2; ++i) {
            uint256 k = H + i * (T + S);
            assertEq(w[k], store.feedAgreementToleranceBps(list[i]), "tolerance");
            assertEq(w[k + 1], registry.priceRouteVersion(list[i]), "route version");
            assertEq(w[k + 2], 0, "replaced slot");
            assertEq(w[k + 3], 1, "primary legs");
            assertEq(w[k + 4], 1, "alternate legs");
            _assertLeg(w, k + 5, primary[i]);
            _assertLeg(w, k + 5 + 2 * L, alternate[i]);
            for (uint256 j = k + 5 + L; j < k + 5 + 2 * L; ++j) {
                assertEq(w[j], 0, "unused primary leg");
            }
            SecondSource memory s = store.secondSource(list[i]);
            k += T;
            assertEq(w[k], uint8(s.kind), "kind");
            assertEq(w[k + 1], uint160(address(second[i])), "source");
            assertEq(w[k + 2], uint256(s.poolRef), "poolRef");
            assertEq(w[k + 3], s.maxAge, "maxAge");
            assertEq(w[k + 4], s.twapWindow, "twapWindow");
            assertEq(w[k + 5], s.toleranceBps, "toleranceBps");
            FeedDef memory d = store.getFeed(address(second[i]));
            assertEq(w[k + 6], d.decimals, "source decimals");
            assertEq(int256(w[k + 7]), d.minAnswer, "source minAnswer");
            assertEq(int256(w[k + 8]), d.maxAnswer, "source maxAnswer");
        }
        // Without second sources the per-token stride drops them and every other word is the same.
        uint256[] memory v = store.getOracleInputs(address(lpOracle), list, false);
        assertEq(v.length, H + 2 * T, "length without second sources");
        for (uint256 i = 0; i < H + T; ++i) {
            assertEq(v[i], w[i], "same head and first token");
        }
        for (uint256 i = 0; i < T; ++i) {
            assertEq(v[H + T + i], w[H + T + S + i], "same second token");
        }
    }

    // TEST-250 verifies: REQ-PSTORE-033, REQ-PSTORE-011, REQ-PSTORE-029, REQ-ORACLE-017, REQ-ORACLE-100
    function test_TEST_250_oracleInputsFollowTheStoreAndRegistry() public {
        // A feed that is no market's LPOracle reads market 0 and zero words: the LPOracle fails closed.
        uint256[] memory w = store.getOracleInputs(alice, list, true);
        assertEq(w.length, H + 2 * (T + S));
        for (uint256 i = 0; i < w.length; ++i) {
            assertEq(w[i], 0, "unknown feed");
        }
        // A guardian's switch to the standby second source shows in the next read.
        vm.prank(address(timelock));
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        vm.prank(emergencyGuardian);
        store.useStandbySecondSource(usdc);
        w = store.getOracleInputs(address(lpOracle), list, true);
        uint256 k = H + T;
        assertEq(w[k], uint8(SecondSourceKind.PoolTwap), "standby kind");
        assertEq(w[k + 1], uint160(address(integration)), "standby source");
        assertEq(w[k + 2], 7, "standby pool");
        assertEq(w[k + 4], 1800, "standby window");
        assertEq(w[k + 6] + w[k + 7] + w[k + 8], 0, "no feed definition for a pool source");
        // A route of more than two legs is passed with its count and no legs, which the LPOracle refuses.
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (address(fUsdc), address(fUsdcAlt), address(fUsdt));
        registry.setActiveRoutes(usdc, three, _one(address(fUsdcAlt)));
        w = store.getOracleInputs(address(lpOracle), list, false);
        assertEq(w[H + 3], 3, "leg count");
        for (uint256 j = H + 5; j < H + 5 + 2 * L; ++j) {
            assertEq(w[j], 0, "no legs");
        }
        // A tightened tolerance is read in the same block.
        vm.prank(address(timelock));
        store.setFeedAgreementToleranceBps(usdt, 200);
        w = store.getOracleInputs(address(lpOracle), list, false);
        assertEq(w[H + T], 200, "tolerance");
    }

    /// @notice `getOracleConfig` is the one view built in a logic contract: the implementation runs it by delegatecall
    /// and ends the call with the logic's return data, or with its revert data unchanged when a read inside it fails.
    // TEST-250 verifies: REQ-CONFIG-072
    function test_TEST_250_oracleConfigEndsWithTheLogicResult() public {
        bytes memory call = abi.encodeCall(store.getOracleConfig, (address(lpOracle)));
        (bool ok, bytes memory ret) = address(store).staticcall(call);
        assertTrue(ok, "listed market");
        (uint256 head, uint256 marketId) = abi.decode(ret, (uint256, uint256));
        assertEq(head, 0x20);
        assertEq(marketId, M, "the logic's configuration");
        bytes memory failure = abi.encodeWithSignature("Error(string)", "registry read failed");
        vm.mockCallRevert(address(registry), abi.encodeWithSelector(registry.getMarket.selector), failure);
        (ok, ret) = address(store).staticcall(call);
        assertFalse(ok, "a failed registry read inside the logic reverts the view");
        assertEq(ret, failure, "the logic's revert data, unchanged");
    }
}
