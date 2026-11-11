// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";
import {ParameterStoreHandler} from "./handlers/ParameterStoreHandler.sol";

/// @title ParameterStoreInvariantTest
/// @notice TEST-225 governance drift on the real ParameterStore: random tightenings (timelock and Joint Configuration
/// Safe), loosenings, structural changes, guardian standby switches, stranger calls and time steps against an Active
/// market with an enabled GHO reserve and an LPOracle that enforces its own floors. After every call: the
/// configuration the store serves passes the LPOracle's `checkConfig`; every value is inside its hard and liveness
/// bounds; the liquidation inequality of the market still holds; no call moved a value the wrong way, past its step
/// or inside its spacing; and no account outside its role wrote anything.
contract ParameterStoreInvariantTest is ParameterStoreFixture {
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
        assertLe(p.poolRiskFactor, 4000);
        assertLe(p.minPledgeUsd, 100_000e8);
        assertTrue(p.hardHealthFloor == 0 || (p.hardHealthFloor >= 1e18 && p.hardHealthFloor <= 1.25e18), "floor");
        uint256 cap = store.marketUsdCap(M);
        assertGt(cap, 0);
        assertLe(cap, type(uint128).max);
        assertLe(store.topUpSliceUsd(M), cap, "slice above cap");
        assertGt(store.tokenUsdCap(address(hub), usdc), 0);
        assertGt(store.depositorUsdCap(address(hub)), 0);
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
