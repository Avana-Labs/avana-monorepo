// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {FeedDef, MarketParams} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {ParameterStoreHandler} from "./handlers/ParameterStoreHandler.sol";

/// @title ParameterStoreInvariantTest
/// @notice TEST-225 governance drift on the real ParameterStore: random tightenings (timelock and Joint Configuration
/// Safe), loosenings, structural changes, guardian standby switches, stranger calls and time steps against an Active
/// market with an enabled GHO reserve and an LPOracle that enforces its own floors. After every call: the
/// configuration the store serves passes the LPOracle's `checkConfig`; every value is inside its hard and liveness
/// bounds; the liquidation inequality of the market still holds; no call moved a value the wrong way, past its step
/// or inside its spacing; and no account outside its role wrote anything.
contract ParameterStoreInvariantTest is ParameterStoreFixture, HandlerReach {
    ParameterStoreHandler internal handler;
    address internal safe = makeAddr("jointConfigurationSafe");

    function setUp() public {
        _deployStore(false);
        _listMarket();
        _activate();
        MockAggregator a = new MockAggregator(8, 1e6, 1e12);
        MockAggregator b = new MockAggregator(8, 1e6, 1e12);
        vm.startPrank(address(timelock));
        store.grantRole(AvanaRoles.APPLICATION_RISK_STEWARD, safe);
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        store.setFeed(address(a), _feedDef(86_400, 1800));
        store.setFeed(address(b), _feedDef(86_400, 1800));
        store.setSecondSource(
            usdc,
            SecondSource(SecondSourceKind.OracleNetwork, address(a), bytes32(0), 88_200, 0, 100),
            SecondSource(SecondSourceKind.OracleNetwork, address(b), bytes32(0), 88_200, 0, 100)
        );
        vm.stopPrank();
        // The LPOracle refuses a consistency tolerance below 15, a USDC tolerance below 110 and a borrow age below
        // 2,000 s: tightenings that would cross them must be refused by the store's re-check.
        lpOracle.setFloors(15, 110, 2000);
        handler = new ParameterStoreHandler(
            store, address(timelock), safe, emergencyGuardian, address(hub), usdc, usdt, address(fUsdc), M
        );
        targetContract(address(handler));
    }

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r = _replayLanded(address(handler), actions, bytes4(0), 32, 50, 0, own, true);
        // Floors: 80 % of the landed share measured with these seeds, rounded down to 5 %; a check's normal return lands.
        uint256[] memory floors = new uint256[](31);
        bool[] memory check = new bool[](31);
        floors[0] = 35; // gateRecovery
        floors[1] = 20; // loosenHardFloor
        floors[2] = 35; // loosenMarketCap
        floors[3] = 80; // loosenPledge
        floors[4] = 50; // loosenSlice
        floors[5] = 40; // loosenSlippage
        floors[6] = 40; // loosenTokenCap
        floors[7] = 30; // poolShare
        floors[8] = 25; // restoreSource
        floors[9] = 75; // setBorrowAge
        floors[10] = 75; // setConsistency
        floors[11] = 55; // setFlashFee
        floors[12] = 75; // setGrace
        floors[13] = 20; // setMargin
        floors[14] = 35; // setSlippageFloor
        floors[15] = 65; // setTolerance
        floors[16] = 40; // shortfall
        floors[17] = 80; // stewardLoosens
        check[17] = true; // stewardLoosens
        floors[18] = 80; // strangerCalls
        check[18] = true; // strangerCalls
        floors[19] = 50; // switchToStandby
        floors[20] = 70; // tightenBorrowAge
        floors[21] = 55; // tightenConsistency
        floors[22] = 55; // tightenFlashFee
        floors[23] = 60; // tightenHardFloor
        floors[24] = 80; // tightenMarketCap
        floors[25] = 80; // tightenPledge
        floors[26] = 80; // tightenSlice
        floors[27] = 40; // tightenSlippage
        floors[28] = 80; // tightenTokenCap
        floors[29] = 50; // tightenTolerance
        floors[30] = 80; // warp
        check[30] = true; // warp
        _check(r, names, new string[](0), floors, new uint256[](0), check);
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions()
        internal
        pure
        returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds)
    {
        (actions, names, kinds) = (new bytes4[](31), new string[](31), new int16[][](31));
        (actions[0], names[0]) = (ParameterStoreHandler.gateRecovery.selector, "gateRecovery");
        kinds[0] = new int16[](3);
        kinds[0][0] = 64;
        kinds[0][1] = 1;
        kinds[0][2] = 1;
        (actions[1], names[1]) = (ParameterStoreHandler.loosenHardFloor.selector, "loosenHardFloor");
        kinds[1] = new int16[](1);
        kinds[1][0] = 256;
        (actions[2], names[2]) = (ParameterStoreHandler.loosenMarketCap.selector, "loosenMarketCap");
        kinds[2] = new int16[](1);
        kinds[2][0] = 256;
        (actions[3], names[3]) = (ParameterStoreHandler.loosenPledge.selector, "loosenPledge");
        kinds[3] = new int16[](1);
        kinds[3][0] = 256;
        (actions[4], names[4]) = (ParameterStoreHandler.loosenSlice.selector, "loosenSlice");
        kinds[4] = new int16[](1);
        kinds[4][0] = 256;
        (actions[5], names[5]) = (ParameterStoreHandler.loosenSlippage.selector, "loosenSlippage");
        kinds[5] = new int16[](1);
        kinds[5][0] = 16;
        (actions[6], names[6]) = (ParameterStoreHandler.loosenTokenCap.selector, "loosenTokenCap");
        kinds[6] = new int16[](1);
        kinds[6][0] = 256;
        (actions[7], names[7]) = (ParameterStoreHandler.poolShare.selector, "poolShare");
        kinds[7] = new int16[](3);
        kinds[7][0] = 16;
        kinds[7][1] = 1;
        kinds[7][2] = 1;
        (actions[8], names[8]) = (ParameterStoreHandler.restoreSource.selector, "restoreSource");
        kinds[8] = new int16[](0);
        (actions[9], names[9]) = (ParameterStoreHandler.setBorrowAge.selector, "setBorrowAge");
        kinds[9] = new int16[](1);
        kinds[9][0] = 32;
        (actions[10], names[10]) = (ParameterStoreHandler.setConsistency.selector, "setConsistency");
        kinds[10] = new int16[](1);
        kinds[10][0] = 16;
        (actions[11], names[11]) = (ParameterStoreHandler.setFlashFee.selector, "setFlashFee");
        kinds[11] = new int16[](1);
        kinds[11][0] = 16;
        (actions[12], names[12]) = (ParameterStoreHandler.setGrace.selector, "setGrace");
        kinds[12] = new int16[](2);
        kinds[12][0] = 256;
        kinds[12][1] = 32;
        (actions[13], names[13]) = (ParameterStoreHandler.setMargin.selector, "setMargin");
        kinds[13] = new int16[](1);
        kinds[13][0] = 16;
        (actions[14], names[14]) = (ParameterStoreHandler.setSlippageFloor.selector, "setSlippageFloor");
        kinds[14] = new int16[](1);
        kinds[14][0] = 16;
        (actions[15], names[15]) = (ParameterStoreHandler.setTolerance.selector, "setTolerance");
        kinds[15] = new int16[](2);
        kinds[15][0] = 16;
        kinds[15][1] = 1;
        (actions[16], names[16]) = (ParameterStoreHandler.shortfall.selector, "shortfall");
        kinds[16] = new int16[](3);
        kinds[16][0] = 16;
        kinds[16][1] = 1;
        kinds[16][2] = 1;
        (actions[17], names[17]) = (ParameterStoreHandler.stewardLoosens.selector, "stewardLoosens");
        kinds[17] = new int16[](2);
        kinds[17][0] = 256;
        kinds[17][1] = 8;
        (actions[18], names[18]) = (ParameterStoreHandler.strangerCalls.selector, "strangerCalls");
        kinds[18] = new int16[](2);
        kinds[18][0] = 256;
        kinds[18][1] = 256;
        (actions[19], names[19]) = (ParameterStoreHandler.switchToStandby.selector, "switchToStandby");
        kinds[19] = new int16[](0);
        (actions[20], names[20]) = (ParameterStoreHandler.tightenBorrowAge.selector, "tightenBorrowAge");
        kinds[20] = new int16[](2);
        kinds[20][0] = 32;
        kinds[20][1] = 1;
        (actions[21], names[21]) = (ParameterStoreHandler.tightenConsistency.selector, "tightenConsistency");
        kinds[21] = new int16[](2);
        kinds[21][0] = 16;
        kinds[21][1] = 1;
        (actions[22], names[22]) = (ParameterStoreHandler.tightenFlashFee.selector, "tightenFlashFee");
        kinds[22] = new int16[](2);
        kinds[22][0] = 16;
        kinds[22][1] = 1;
        (actions[23], names[23]) = (ParameterStoreHandler.tightenHardFloor.selector, "tightenHardFloor");
        kinds[23] = new int16[](2);
        kinds[23][0] = 256;
        kinds[23][1] = 1;
        (actions[24], names[24]) = (ParameterStoreHandler.tightenMarketCap.selector, "tightenMarketCap");
        kinds[24] = new int16[](2);
        kinds[24][0] = 256;
        kinds[24][1] = 1;
        (actions[25], names[25]) = (ParameterStoreHandler.tightenPledge.selector, "tightenPledge");
        kinds[25] = new int16[](2);
        kinds[25][0] = 256;
        kinds[25][1] = 1;
        (actions[26], names[26]) = (ParameterStoreHandler.tightenSlice.selector, "tightenSlice");
        kinds[26] = new int16[](2);
        kinds[26][0] = 256;
        kinds[26][1] = 1;
        (actions[27], names[27]) = (ParameterStoreHandler.tightenSlippage.selector, "tightenSlippage");
        kinds[27] = new int16[](2);
        kinds[27][0] = 16;
        kinds[27][1] = 1;
        (actions[28], names[28]) = (ParameterStoreHandler.tightenTokenCap.selector, "tightenTokenCap");
        kinds[28] = new int16[](2);
        kinds[28][0] = 256;
        kinds[28][1] = 1;
        (actions[29], names[29]) = (ParameterStoreHandler.tightenTolerance.selector, "tightenTolerance");
        kinds[29] = new int16[](3);
        kinds[29][0] = 16;
        kinds[29][1] = 1;
        kinds[29][2] = 1;
        (actions[30], names[30]) = (ParameterStoreHandler.warp.selector, "warp");
        kinds[30] = new int16[](1);
        kinds[30][0] = 256;
    }

    function _calldata(
        bytes4 selector,
        uint256 seed
    ) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
    }

    // TEST-225 verifies: REQ-PSTORE-009, REQ-PSTORE-013, REQ-CONFIG-051, INV-047
    function invariant_TEST_225_servedConfigPassesCheckConfig() public view {
        (bool ok, bytes memory config) =
            address(store).staticcall(abi.encodeCall(store.getOracleConfig, (address(lpOracle))));
        assertTrue(ok, "getOracleConfig reverted");
        (bool done, bytes memory ret) =
            address(lpOracle).staticcall(bytes.concat(ILPOracle.checkConfig.selector, config));
        assertTrue(done, "checkConfig reverted");
        assertEq(abi.decode(ret, (uint256)), 0, "served configuration fails checkConfig");
    }

    // TEST-225 verifies: REQ-CONFIG-050, REQ-CONFIG-052, REQ-PSTORE-031, REQ-PSTORE-005, REQ-RISK-044, INV-047
    function invariant_TEST_225_marketValuesInBounds() public view {
        MarketParams memory p = store.getMarketParams(M);
        assertGe(p.slippageAllowanceBps, p.slippageAllowanceMinBps, "slippage below its floor");
        assertLt(p.slippageAllowanceBps, 10_000);
        assertGe(p.consistencyToleranceBps, 10);
        assertLe(p.consistencyToleranceBps, 10_000);
        assertGt(p.poolRiskFactor, 0);
        assertLe(p.poolRiskFactor, 9000);
        assertLe(p.minPledgeUsd, 100_000e8);
        assertTrue(p.hardHealthFloor == 0 || (p.hardHealthFloor >= 1e18 && p.hardHealthFloor <= 1.25e18), "floor");
        // Market and token caps may be tightened to 0, and the market cap below the slice (REQ-RISK-042).
        assertLe(store.marketUsdCap(M), type(uint128).max);
        assertLe(store.topUpSliceUsd(M), type(uint128).max);
        assertLe(store.tokenUsdCap(address(hub), usdc), type(uint128).max);
    }

    // TEST-225 verifies: REQ-CONFIG-050, REQ-CONFIG-052, REQ-PSTORE-024, REQ-PSTORE-030, REQ-PSTORE-018, REQ-RISK-042
    function invariant_TEST_225_chainValuesInBounds() public view {
        assertLe(store.maxFlashFeeBps(), 100);
        assertGe(store.gateRecoverySeconds(), 600);
        assertLe(store.gateRecoverySeconds(), 7200);
        assertLe(store.maxShortfallBps(), 5000);
        assertGe(store.graceHealthFactor(), 0.9e18);
        assertLt(store.graceHealthFactor(), 1e18);
        assertLe(store.graceDuration(), 7200);
        assertLe(store.feedAgreementMarginBps(), 10_000);
        uint16 share = store.poolShareMaxBps();
        assertGt(share, 0);
        assertLe(share, 10_000);
        bytes32 key = keccak256(abi.encode(uint32(1), address(pool), bytes32(0)));
        assertLe(store.poolShareMaxBpsOf(key), share, "pool above the chain default");
        assertGt(store.poolShareMaxBpsOf(key), 0);
    }

    // TEST-225 verifies: REQ-CONFIG-024, REQ-CONFIG-023, REQ-CONFIG-052
    function invariant_TEST_225_tolerancesAndAgesKeepTheirBounds() public view {
        assertGe(store.feedAgreementToleranceBps(usdc), store.feedAgreementToleranceMinBps(usdc), "USDC tolerance");
        assertGe(store.feedAgreementToleranceBps(usdt), store.feedAgreementToleranceMinBps(usdt), "USDT tolerance");
        FeedDef memory d = store.getFeed(address(fUsdc));
        assertGt(d.borrowPriceMaxAge, 0);
        assertLe(d.borrowPriceMaxAge, d.liquidationPriceMaxAge, "borrow age above liquidation age");
        assertEq(d.liquidationPriceMaxAge, uint256(d.feedHeartbeat) + d.heartbeatMargin);
    }

    // TEST-225 verifies: REQ-PSTORE-021, REQ-PSTORE-015, REQ-PSTORE-024, INV-047
    function invariant_TEST_225_liquidationInequalityHolds() public view {
        assertTrue(store.liquidationLivenessHolds(address(spoke), M, 1), "liveness broken");
    }

    // TEST-225 verifies: REQ-CONFIG-051, REQ-PSTORE-017, REQ-PSTORE-002, REQ-CONFIG-058
    function invariant_TEST_225_noCallBrokeItsRule() public view {
        assertEq(handler.wrongDirection(), 0, "a setter moved a value the wrong way");
        assertEq(handler.stepEscaped(), 0, "a loosening exceeded its step");
        assertEq(handler.spacingEscaped(), 0, "a loosening came inside its spacing");
        assertEq(handler.strangerWrites(), 0, "a stranger wrote a value");
        assertEq(handler.stewardLoosened(), 0, "the steward loosened a value");
    }
}
