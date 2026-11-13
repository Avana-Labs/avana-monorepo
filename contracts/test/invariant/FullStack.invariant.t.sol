// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AaveAdapter} from "../../src/policy/aave-adapter/AaveAdapter.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {FullStackMarkets} from "../utils/fixtures/FullStackMarkets.sol";
import {OracleFeedMock} from "../utils/mocks/LPOracleMocks.sol";
import {FullStackHandler, FullStackWorld} from "./handlers/FullStackHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FullStackInvariantTest
/// @notice Invariants of the whole chain stack as one deployment runs it (`FullStackMarkets`: the real
/// MarketRegistry, ParameterStore, RiskModule, AaveAdapter, Collateralization, AvanaTimelock, LPOracles and USDC
/// DebtOracle on the real local Aave V4) under random sequences of pledges, borrows of GHO and USDC, repays by owners
/// and third parties, debt-free withdrawals, liquidations, pause-state changes, price moves, draw-cap cuts, timelock
/// tightenings, an AaveAdapter upgrade to a second reviewed implementation, and time.
/// @dev Each handler call is one transaction.
/// forge-config: default.isolate = false
/// forge-config: default.invariant.runs = 16
/// forge-config: default.invariant.depth = 24
contract FullStackInvariantTest is FullStackMarkets {
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
        targetContract(address(handler));
    }

    // TEST-215 verifies: REQ-ACCESS-148, INV-075
    /// @notice Every handler action reaches its entry point and completes in a plain sequence, so the random campaign
    /// exercises real calls: pledges in both markets, borrows of GHO and USDC, a repay by a third party, a cap tightening
    /// and the AaveAdapter upgrade through the timelock, a pause and its lifting, a price fall and a liquidation, a
    /// draw-cap cut, and a debt-free withdrawal.
    function test_TEST_215_handlerActionsComplete() public {
        // Alice: $20,000 in market A ($6,000 of borrowing power), $5,900 borrowed; Bob: debt-free in market B.
        handler.pledge(0, 0, 10_000e6);
        handler.pledge(1, 1, 10_000e6);
        handler.borrow(0, 0, 0, 3000);
        handler.borrow(0, 0, 0, 2700);
        handler.borrow(0, 0, 1, 200);
        assertEq(handler.borrows(), 3, "borrows");
        handler.repay(0, 0, 0, 1);
        handler.tightenSlice(0);
        assertEq(store.topUpSliceUsd(mA), 100_000e8 - 1e8, "slice tightened through the timelock");
        handler.upgradeAdapter();
        assertEq(handler.upgrades(), 1, "Adapter upgraded through the timelock");
        handler.setPause(2);
        handler.setPause(0);
        handler.setPrice(93_000_000);
        handler.liquidate(0);
        assertEq(handler.liquidations(), 1, "liquidation");
        handler.cutDrawCap(0, 1);
        handler.withdraw(1, 1);
        assertEq(handler.withdrawals(), 1, "debt-free withdrawal");
        assertEq(handler.pledges(), 2, "pledges");
        assertGe(handler.repays(), 1, "repay");
        assertEq(handler.exitBlocked() + handler.gateViolations() + handler.earlyExecutions(), 0, "no violation");
    }

    // ─── TEST-193: exits and liquidation under every pause state ───

    // TEST-193 verifies: REQ-MREG-002, REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-ACCESS-068, INV-067, ATTACK-035
    /// @notice Whatever the Hub's state on the real MarketRegistry, no repay, debt-free withdrawal or liquidation
    /// reverted for a pause, a freeze or a breaker; no borrow and no pledge of a debt-free account completed while
    /// Frozen, no borrow while Paused, and no pledge while Paused(MintPathSuspect).
    function invariant_TEST_193_exitsLiveUnderEveryPauseState() public view {
        assertEq(handler.exitBlocked(), 0, "an exit stopped by a pause");
        assertEq(handler.gateViolations(), 0, "a gated action completed");
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
    /// `marketUsdCap`, slice within `topUpSliceUsd`, each depositor within `depositorUsdCap`), and every completed
    /// pledge was worth at least `minPledgeUsd` at the served LPOracle price.
    function invariant_TEST_097_countersWithinTheStoreCaps() public view {
        assertEq(handler.capViolations(), 0, "a pledge left a counter above its cap");
        assertEq(handler.minPledgeViolations(), 0, "a pledge below the minimum");
    }

    // ─── TEST-274: draw gate ───

    // TEST-274 verifies: INV-057, INV-094
    /// @notice No borrow completed that left the CDP Spoke's owed amount of the asset above its draw cap, whatever the
    /// Aave DAO's cuts; the MarketRegistry's recorded draw-cap sum of each credit line never exceeds the line.
    function invariant_TEST_274_drawGateAndCapSum() public view {
        assertEq(handler.drawCapViolations(), 0, "a borrow above the draw cap");
        address[2] memory assets = [address(gho), address(usdc)];
        for (uint256 i = 0; i < 2; ++i) {
            (uint256 line, uint256 sum) = registry.creditLine(aave.hub, assets[i]);
            assertLe(sum, line, "cap sum within the line");
        }
    }
}
