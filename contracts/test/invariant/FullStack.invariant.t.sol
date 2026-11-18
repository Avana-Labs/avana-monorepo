// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AaveAdapter} from "../../src/policy/aave-adapter/AaveAdapter.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {FullStackMarkets} from "../utils/fixtures/FullStackMarkets.sol";
import {OracleFeedMock} from "../utils/mocks/LPOracleMocks.sol";
import {FullStackHandler, FullStackWorld} from "./handlers/FullStackHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FullStackInvariantTest
/// @notice Invariants of the whole chain stack as one deployment runs it (`FullStackMarkets`: the real
/// MarketRegistry, ParameterStore, RiskModule, AaveAdapter, Collateralization, AvanaTimelock, LPOracles and USDC
/// DebtOracle on the real local Aave V4) under random sequences of pledges, borrows of GHO and USDC, repays by owners
/// and third parties, debt-free withdrawals, liquidations, price moves, draw-cap cuts, timelock tightenings, an
/// AaveAdapter upgrade to a second reviewed implementation, and time.
/// @dev Each handler call is one transaction.
/// forge-config: default.isolate = false
/// forge-config: default.invariant.runs = 16
/// forge-config: default.invariant.depth = 24
/// forge-config: invariant.invariant.runs = 1000
/// forge-config: invariant.invariant.depth = 400
contract FullStackInvariantTest is FullStackMarkets, HandlerReach {
    FullStackHandler internal handler;
    uint256 internal mA;
    uint256 internal mB;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        mB = _addMarket(poolB);
        address second = address(new AaveAdapter(adapterIm, _adapterLogics(adapterIm)));
        FullStackWorld memory world;
        world.adapter = adapterC;
        world.registry = registry;
        world.store = store;
        world.timelock = timelock;
        world.coll = coll;
        world.lpVault = lpVault;
        world.swap = swap;
        world.spoke = IAaveV4Spoke(aave.cdpSpoke);
        world.hub = aave.hub;
        world.hubConfigurator = aave.hubConfigurator;
        world.aaveDao = aaveDao;
        world.guardian = emergencyGuardian;
        world.governance = governanceMultisig;
        world.markets = [mA, mB];
        world.vaultTokens = [mkt[mA].vaultToken, mkt[mB].vaultToken];
        world.vtReserves = [mkt[mA].reserveId, mkt[mB].reserveId];
        world.debtAssets = [gho, usdc];
        world.debtReserves = [ghoReserveId, usdcReserveId];
        world.debtAssetIds = [ghoAssetId, usdcAssetId];
        world.secondImplementation = second;
        world.integrationId = V3;
        OracleFeedMock[] memory list = new OracleFeedMock[](8);
        for (uint256 i = 0; i < 4; ++i) {
            list[i] = feedsOf[address(usdc)][i];
            list[4 + i] = feedsOf[address(usdt)][i];
        }
        handler = new FullStackHandler(world, [alice, bob, carol], makeAddr("thirdPartyPayer"), list);
        handler.seedAccounts();
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _actions()}));
    }

    /// @dev The fuzzed actions (`seedAccounts` is set-up only).
    function _actions() internal pure returns (bytes4[] memory a) {
        a = new bytes4[](10);
        (a[0], a[1], a[2], a[3], a[4]) =
        (
            FullStackHandler.pledge.selector,
            FullStackHandler.borrow.selector,
            FullStackHandler.repay.selector,
            FullStackHandler.withdraw.selector,
            FullStackHandler.liquidate.selector
        );
        (a[5], a[6], a[7], a[8], a[9]) =
        (
            FullStackHandler.setPrice.selector,
            FullStackHandler.warp.selector,
            FullStackHandler.cutDrawCap.selector,
            FullStackHandler.tightenSlice.selector,
            FullStackHandler.upgradeAdapter.selector
        );
    }

    // TEST-082 verifies: TEST-007
    /// @notice The handler does real work: over 16 fixed-seed runs of 24 calls from this suite's set-up state, the
    /// actions succeed in at least 20 % of their calls (borrow 10 %: it is refused beyond the account's room, and the
    /// set-up's accounts are near it; `upgradeAdapter` runs once) and a liquidation, a
    /// repay and a debt-free withdrawal are each reached in at least 75 % of the runs.
    function test_TEST_082_handlerReach() public {
        string[] memory names = new string[](10);
        (names[0], names[1], names[2], names[3], names[4]) = ("pledge", "borrow", "repay", "withdraw", "liquidate");
        (names[5], names[6], names[7], names[8], names[9]) =
        ("setPrice", "warp", "cutDrawCap", "tightenSlice", "upgradeAdapter");
        string[] memory targets = new string[](3);
        (targets[0], targets[1], targets[2]) = ("liquidation", "repay", "debt-free withdrawal");
        uint256[] memory minOk = _floors(10, 20);
        minOk[1] = 10;
        minOk[9] = 0;
        Reach memory r = _replay(address(handler), _actions(), FullStackHandler.Skipped.selector, 16, 24, 3);
        _check(r, names, targets, minOk, _floors(3, 75));
    }

    function _reached() internal view override returns (bool[] memory hit) {
        hit = new bool[](3);
        hit[0] = handler.liquidations() != 0;
        hit[1] = handler.repays() != 0;
        hit[2] = handler.withdrawals() != 0;
    }

    // TEST-215 verifies: REQ-ACCESS-148, INV-075
    /// @notice Every handler action reaches its entry point and completes in a plain sequence, so the random campaign
    /// exercises real calls: pledges in both markets, borrows of GHO and USDC, a repay by a third party, a cap
    /// tightening and the AaveAdapter upgrade through the timelock, a price fall and a liquidation, a draw-cap cut, and
    /// a debt-free withdrawal.
    function test_TEST_215_handlerActionsComplete() public {
        // Counts from here on; the set-up seeded 3 pledges and 6 borrows.
        uint256[4] memory base = [handler.pledges(), handler.borrows(), handler.liquidations(), handler.withdrawals()];
        // Alice: $20,000 more in market A ($6,000 more borrowing power), $5,900 more borrowed; Bob: debt-free in
        // market B.
        handler.pledge(0, 0, 10_000e6);
        handler.pledge(1, 1, 10_000e6);
        handler.borrow(0, 0, 0, 3000);
        handler.borrow(0, 0, 0, 2700);
        handler.borrow(0, 0, 1, 200);
        assertEq(handler.borrows() - base[1], 3, "borrows");
        handler.repay(0, 0, 0, 1);
        handler.tightenSlice(0);
        assertEq(store.topUpSliceUsd(mA), 100_000e8 - 1e8, "slice tightened through the timelock");
        handler.upgradeAdapter();
        assertEq(handler.upgrades(), 1, "Adapter upgraded through the timelock");
        handler.setPrice(93_000_000);
        handler.liquidate(0);
        assertEq(handler.liquidations() - base[2], 1, "liquidation");
        handler.cutDrawCap(0, 1);
        handler.withdraw(1, 1);
        assertEq(handler.withdrawals() - base[3], 1, "debt-free withdrawal");
        assertEq(handler.pledges() - base[0], 2, "pledges");
        assertGe(handler.repays(), 1, "repay");
        assertEq(handler.exitBlocked() + handler.earlyExecutions(), 0, "no violation");
    }

    // ─── TEST-193: exits and liquidation never stopped by a breaker ───

    // TEST-193 verifies: REQ-MREG-002, REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-ACCESS-068, INV-067, ATTACK-035
    /// @notice No repay, debt-free withdrawal or liquidation reverted for a market or debt breaker.
    function invariant_TEST_193_exitsNeverStoppedByABreaker() public view {
        assertEq(handler.exitBlocked(), 0, "an exit stopped by a breaker");
    }

    // ─── TEST-211: proxies, backing and the debt set ───

    // TEST-211 verifies: REQ-ADAPTER-066, REQ-PROXY-049, REQ-PROXY-053, INV-063, INV-064, INV-071
    /// @notice After every call, across the AaveAdapter upgrade: each proxy sits at the ProxyManager's prediction for
    /// its wallet, Spoke and market with its binding and code unchanged; each vault token's supply equals
    /// Collateralization's credited plus pending units; the MarketRegistry's debt set of the CDP Spoke equals the
    /// Spoke's borrowable reserves; no vault-token reserve is borrowable, takes received shares or a liquidation fee.
    function invariant_TEST_211_proxiesBackingAndDebtSet() public view {
        for (uint256 i = 0; i < handler.proxyCount(); ++i) {
            address p = handler.proxies(i);
            address wallet = handler.proxyWallet(p);
            uint256 market = handler.proxyMarket(p);
            assertEq(proxyManager.predictProxy(wallet, aave.cdpSpoke, market), p, "predicted address");
            assertEq(adapterC.proxyOf(wallet, market), p, "one proxy per wallet and market");
            assertEq(IPositionProxy(p).WALLET(), wallet, "wallet fixed");
            assertEq(IPositionProxy(p).SPOKE(), aave.cdpSpoke, "Spoke fixed");
            assertEq(IPositionProxy(p).MARKET_ID(), market, "market fixed");
            assertEq(p.codehash, handler.proxyCodeHash(p), "code fixed");
        }
        uint256[2] memory ids = [mA, mB];
        for (uint256 i = 0; i < 2; ++i) {
            address vt = mkt[ids[i]].vaultToken;
            assertEq(
                IERC20(vt).totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "supply = backing"
            );
        }
        IAaveV4Spoke s = IAaveV4Spoke(aave.cdpSpoke);
        for (uint256 r = 0; r < s.getReserveCount(); ++r) {
            assertEq(s.getReserveConfig(r).borrowable, registry.isApprovedDebtReserve(aave.cdpSpoke, r), "debt set");
        }
        for (uint256 i = 0; i < 2; ++i) {
            uint256 r = mkt[ids[i]].reserveId;
            IAaveV4Spoke.ReserveConfig memory c = s.getReserveConfig(r);
            assertFalse(c.borrowable || c.receiveSharesEnabled, "vault-token reserve flags");
            uint32 key = s.getReserve(r).dynamicConfigKey;
            assertEq(s.getDynamicReserveConfig(r, key).liquidationFee, 0, "no liquidation fee");
        }
    }

    // ─── TEST-215: multi-actor suite ───

    // TEST-215 verifies: INV-028, INV-055, INV-075, REQ-ACCESS-148
    /// @notice With borrowers, a third-party payer, LPVaultSwap, the Emergency Guardian, the Aave DAO and the timelock
    /// acting in any order: the Adapter holds no token and the Lock is free between transactions; each market's
    /// regular and slice budgets stay within the ParameterStore's caps; no timelock operation executed before its
    /// required delay; and a pledge never completed below `minPledgeUsd` at the served price.
    function invariant_TEST_215_allInvariantsAfterEveryStep() public view {
        uint256[2] memory ids = [mA, mB];
        for (uint256 i = 0; i < 2; ++i) {
            address vt = mkt[ids[i]].vaultToken;
            assertEq(IERC20(vt).balanceOf(adapter), 0, "no vault token in the Adapter");
        }
        assertEq(gho.balanceOf(adapter) + usdc.balanceOf(adapter), 0, "no debt asset in the Adapter");
        assertFalse(lock.isLocked(), "Lock free between transactions");
        assertEq(handler.earlyExecutions(), 0, "an operation executed before its delay");
        assertEq(handler.minPledgeViolations(), 0, "a pledge below the minimum");
        assertEq(handler.capViolations(), 0, "a pledge above a cap");
    }

    // ─── TEST-097: caps and booking ───

    // TEST-097 verifies: REQ-COLL-003, REQ-VAULT-128, INV-027, INV-028, INV-069
    /// @notice Collateralization's counters never exceed the ParameterStore's caps (regular budget within
    /// `marketUsdCap`, slice within `topUpSliceUsd`), and every completed pledge was worth at least `minPledgeUsd` at
    /// the served LPOracle price.
    function invariant_TEST_097_countersWithinTheStoreCaps() public view {
        assertEq(handler.capViolations(), 0, "a pledge left a counter above its cap");
        assertEq(handler.minPledgeViolations(), 0, "a pledge below the minimum");
    }

    // ─── TEST-274: draw gate ───

    // TEST-274 verifies: INV-057, INV-094
    /// @notice No borrow completed that left the CDP Spoke's owed amount of the asset above its draw cap, whatever the
    /// Aave DAO's cuts.
    function invariant_TEST_274_drawGate() public view {
        assertEq(handler.drawCapViolations(), 0, "a borrow above the draw cap");
    }

    // TEST-274 verifies: INV-057, INV-094
    /// @notice The campaign's shrunk sequence for seed 0x6afae3b8: three full repays leave the CDP Spoke owing no GHO,
    /// the Aave DAO cuts its GHO draw cap to 160, time passes and Carol borrows exactly 160 GHO. The Hub admits it
    /// (owed 0 + 160e18 + deficit 0 <= 160e18) and its rounded-up share conversions then read 160e18 + 1 owed: the
    /// draw gate held, with no draw past the cap beyond the conversions' rounding.
    function test_TEST_274_borrowAfterADrawCapCut() public {
        handler.repay(6251, 50_000, 28_784, 250_000_000_000_000);
        handler.cutDrawCap(22_356, 160);
        handler.repay(20_862, 1_152_921_504_606_846_975, 711_630_742, 75_000_000_000);
        handler.warp(661_429_411);
        handler.repay(
            20_049_984_438_372_941_852_658_673_219_896_926_510_856_028_572_430_283_221_720_904_586_814_916_919_295,
            2_199_023_255_552,
            604_800,
            100_000_000_000_000_000_000_000_000_000_000_000_000_000_000
        );
        uint256 before = handler.borrows();
        handler.borrow(19_603, 12_035, 7412, 21_160);
        assertEq(handler.borrows(), before + 1, "the borrow of the room left completed");
        assertEq(IAaveV4Hub(aave.hub).getSpokeTotalOwed(ghoAssetId, aave.cdpSpoke), 160e18 + 1, "owed after the draw");
        invariant_TEST_274_drawGate();
    }
}
