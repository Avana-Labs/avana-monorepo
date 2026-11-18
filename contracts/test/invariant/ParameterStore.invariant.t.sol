// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {ILPOracle} from "../../src/oracle/ILPOracle.sol";
import {FeedDef, MarketParams} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {ParameterStoreHandler} from "./handlers/ParameterStoreHandler.sol";

/// @title ParameterStoreInvariantTest
/// @notice TEST-225 governance drift on the real ParameterStore: random tightenings (timelock and Joint Configuration
/// Safe), loosenings, structural changes, stranger calls and time steps against an Active market with an enabled GHO
/// reserve. After every call: every value is inside its hard and liveness bounds; the liquidation inequality of the market still holds; no call moved a value the wrong way, past its step
/// or inside its spacing; and no account outside its role wrote anything.
contract ParameterStoreInvariantTest is ParameterStoreFixture, HandlerReach {
    ParameterStoreHandler internal handler;
    address internal safe = makeAddr("jointConfigurationSafe");

    function setUp() public {
        _deployStore();
        _listMarket();
        _activate();
        vm.prank(aaveGovernanceExecutor);
        accessManager.grantRole(AvanaRoles.TIGHTEN_ROLE, safe, 0);
        handler = new ParameterStoreHandler(store, governor, safe, address(hub), usdc, usdt, address(fUsdc), M);
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
        uint256[] memory floors = new uint256[](19);
        bool[] memory check = new bool[](19);
        floors[0] = 35; // loosenMarketCap
        floors[1] = 80; // loosenPledge
        floors[2] = 30; // loosenSlice
        floors[3] = 25; // loosenSlippage
        floors[4] = 30; // loosenTokenCap
        floors[5] = 75; // setBorrowAge
        floors[6] = 55; // setFlashFee
        floors[7] = 35; // setSlippageFloor
        floors[8] = 40; // shortfall
        floors[9] = 80; // stewardLoosens
        check[9] = true; // stewardLoosens
        floors[10] = 80; // strangerCalls
        check[10] = true; // strangerCalls
        floors[11] = 70; // tightenBorrowAge
        floors[12] = 55; // tightenFlashFee
        floors[13] = 80; // tightenMarketCap
        floors[14] = 80; // tightenPledge
        floors[15] = 80; // tightenSlice
        floors[16] = 40; // tightenSlippage
        floors[17] = 80; // tightenTokenCap
        floors[18] = 80; // warp
        check[18] = true; // warp
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
        (actions, names, kinds) = (new bytes4[](19), new string[](19), new int16[][](19));
        (actions[0], names[0]) = (ParameterStoreHandler.loosenMarketCap.selector, "loosenMarketCap");
        kinds[0] = new int16[](1);
        kinds[0][0] = 256;
        (actions[1], names[1]) = (ParameterStoreHandler.loosenPledge.selector, "loosenPledge");
        kinds[1] = new int16[](1);
        kinds[1][0] = 256;
        (actions[2], names[2]) = (ParameterStoreHandler.loosenSlice.selector, "loosenSlice");
        kinds[2] = new int16[](1);
        kinds[2][0] = 256;
        (actions[3], names[3]) = (ParameterStoreHandler.loosenSlippage.selector, "loosenSlippage");
        kinds[3] = new int16[](1);
        kinds[3][0] = 16;
        (actions[4], names[4]) = (ParameterStoreHandler.loosenTokenCap.selector, "loosenTokenCap");
        kinds[4] = new int16[](1);
        kinds[4][0] = 256;
        (actions[5], names[5]) = (ParameterStoreHandler.setBorrowAge.selector, "setBorrowAge");
        kinds[5] = new int16[](1);
        kinds[5][0] = 32;
        (actions[6], names[6]) = (ParameterStoreHandler.setFlashFee.selector, "setFlashFee");
        kinds[6] = new int16[](1);
        kinds[6][0] = 16;
        (actions[7], names[7]) = (ParameterStoreHandler.setSlippageFloor.selector, "setSlippageFloor");
        kinds[7] = new int16[](1);
        kinds[7][0] = 16;
        (actions[8], names[8]) = (ParameterStoreHandler.shortfall.selector, "shortfall");
        kinds[8] = new int16[](3);
        kinds[8][0] = 16;
        kinds[8][1] = 1;
        kinds[8][2] = 1;
        (actions[9], names[9]) = (ParameterStoreHandler.stewardLoosens.selector, "stewardLoosens");
        kinds[9] = new int16[](2);
        kinds[9][0] = 256;
        kinds[9][1] = 8;
        (actions[10], names[10]) = (ParameterStoreHandler.strangerCalls.selector, "strangerCalls");
        kinds[10] = new int16[](2);
        kinds[10][0] = 256;
        kinds[10][1] = 256;
        (actions[11], names[11]) = (ParameterStoreHandler.tightenBorrowAge.selector, "tightenBorrowAge");
        kinds[11] = new int16[](2);
        kinds[11][0] = 32;
        kinds[11][1] = 1;
        (actions[12], names[12]) = (ParameterStoreHandler.tightenFlashFee.selector, "tightenFlashFee");
        kinds[12] = new int16[](2);
        kinds[12][0] = 16;
        kinds[12][1] = 1;
        (actions[13], names[13]) = (ParameterStoreHandler.tightenMarketCap.selector, "tightenMarketCap");
        kinds[13] = new int16[](2);
        kinds[13][0] = 256;
        kinds[13][1] = 1;
        (actions[14], names[14]) = (ParameterStoreHandler.tightenPledge.selector, "tightenPledge");
        kinds[14] = new int16[](2);
        kinds[14][0] = 256;
        kinds[14][1] = 1;
        (actions[15], names[15]) = (ParameterStoreHandler.tightenSlice.selector, "tightenSlice");
        kinds[15] = new int16[](2);
        kinds[15][0] = 256;
        kinds[15][1] = 1;
        (actions[16], names[16]) = (ParameterStoreHandler.tightenSlippage.selector, "tightenSlippage");
        kinds[16] = new int16[](2);
        kinds[16][0] = 16;
        kinds[16][1] = 1;
        (actions[17], names[17]) = (ParameterStoreHandler.tightenTokenCap.selector, "tightenTokenCap");
        kinds[17] = new int16[](2);
        kinds[17][0] = 256;
        kinds[17][1] = 1;
        (actions[18], names[18]) = (ParameterStoreHandler.warp.selector, "warp");
        kinds[18] = new int16[](1);
        kinds[18][0] = 256;
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

    // TEST-225 verifies: REQ-CONFIG-050, REQ-CONFIG-052, REQ-PSTORE-031, REQ-PSTORE-005, REQ-RISK-044, INV-047
    function invariant_TEST_225_marketValuesInBounds() public view {
        MarketParams memory p = store.getMarketParams(M);
        assertGe(p.slippageAllowanceBps, p.slippageAllowanceMinBps, "slippage below its floor");
        assertLt(p.slippageAllowanceBps, 10_000);
        assertGt(p.poolRiskFactor, 0);
        assertLe(p.poolRiskFactor, 9000);
        assertLe(p.minPledgeUsd, 100_000e8);
        // Market and token caps may be tightened to 0, and the market cap below the slice (REQ-RISK-042).
        assertLe(store.marketUsdCap(M), type(uint128).max);
        assertLe(store.topUpSliceUsd(M), type(uint128).max);
        assertLe(store.tokenUsdCap(address(hub), usdc), type(uint128).max);
    }

    // TEST-225 verifies: REQ-CONFIG-050, REQ-CONFIG-052, REQ-PSTORE-024, REQ-PSTORE-030, REQ-PSTORE-018, REQ-RISK-042
    function invariant_TEST_225_chainValuesInBounds() public view {
        assertLe(store.maxFlashFeeBps(), 100);
        assertLe(store.maxShortfallBps(), 5000);
        assertLe(store.avanaFeeShareBps(), 5000);
    }

    // TEST-225 verifies: REQ-CONFIG-023, REQ-CONFIG-052
    function invariant_TEST_225_feedAgesKeepTheirBounds() public view {
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
