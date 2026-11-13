// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {IAaveAdapterCollateral} from "../../src/policy/aave-adapter/IAaveAdapterCollateral.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryRoutes} from "../../src/policy/market-registry/IMarketRegistryRoutes.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {FullStackMarkets} from "../utils/fixtures/FullStackMarkets.sol";
import {RegistryRouteMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FullStackPolicyIntegrationTest
/// @notice The ParameterStore's values as the RiskModule, the LPOracle, the MarketRegistry and Collateralization read
/// them, on the full real stack (`FullStackMarkets`), every change made through the real AvanaTimelock at the delay it
/// requires: exposure caps and their booking, price states under a tolerance tightened at the short delay, the route
/// slots and their delays, the Hub add-cap fit, re-credit, and the oracle pokes of the borrow checks.
/// @dev Market A (pool 0.01 %), USDC/USDT at $2.00 per vault token. Alice holds GHO and USDC debt; Bob is debt-free.
/// forge-config: default.isolate = false
contract FullStackPolicyIntegrationTest is FullStackMarkets {
    uint256 internal mA;
    bytes32 internal kA;
    bytes32 internal kB;
    address internal pA;
    address internal pB;
    address internal vtA;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        vtA = mkt[mA].vaultToken;
        (kA, pA) = _pledgeAs(alice, mA, UNITS);
        _borrowAs(alice, mA, ghoReserveId, 2000e18);
        _borrowAs(alice, mA, usdcReserveId, 500e6);
        (kB, pB) = _pledgeAs(bob, mA, UNITS);
        gho.mint(alice, 1e30);
        vm.prank(alice);
        gho.approve(adapter, type(uint256).max);
    }

    function _record(
        bytes32 key
    ) internal view returns (BackingRecord memory) {
        return coll.getRecord(coll.recordIdOf(V3, key));
    }

    /// @dev Pledges `units` for `wallet` and returns the revert data (empty on success).
    function _tryPledge(
        address wallet,
        uint128 units
    ) internal returns (bool ok, bytes memory ret, bytes32 key) {
        key = _newKey();
        lpVault.mintPosition(key, wallet, mA, units);
        vm.prank(wallet);
        (ok, ret) = adapter.call(abi.encodeWithSelector(adapterC.pledge.selector, mA, _ref(key), _deadline()));
    }

    /// @dev The charge of `units` at the market's served price, rounded up (above the $1.00 stress floor here).
    function _charge(
        uint256 units
    ) internal view returns (uint256) {
        uint256 price = uint256(mkt[mA].oracle.latestAnswer());
        return (units * price + 1e6 - 1) / 1e6;
    }

    function _sliceTo(
        uint256 value
    ) internal view returns (bytes memory) {
        return abi.encodeCall(IParameterStoreTighten.tightenTopUpSliceUsd, (mA, value));
    }

    function _capError(
        bytes32 kind
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, kind);
    }

    // ─── TEST-013: exposure caps read from the ParameterStore ───

    /// @notice Each pledge is charged at the LPOracle price (at least `stressFloorUsd`), rounded up, and Collateralization
    /// books exactly the charge in its counters; each cap the RiskModule reads from the ParameterStore (market, token,
    /// depositor, pool share), tightened through the timelock at the short delay, refuses the next pledge it would
    /// break with `CapExceeded`, and a refused pledge leaves every counter as it was.
    // TEST-013 verifies: REQ-RISK-021, REQ-RISK-022, REQ-RISK-024, REQ-RISK-051, SPEC-CAP-002, SPEC-CAP-003, INV-028
    function test_TEST_013_capsReadFromTheParameterStore() public {
        PledgeCounters memory k = coll.getCounters(vtA, bob);
        uint256 charged = uint256(_record(kA).currentUsdCharge) + _record(kB).currentUsdCharge;
        assertEq(k.regularUsed, charged, "regular budget = the charges booked");
        // About $20,000 each at the LPOracle's $2.00 per vault token (10,000 whole tokens), rounded up.
        assertEq(_record(kB).currentUsdCharge, _charge(UNITS), "charged at the LPOracle price");
        assertEq(k.depositorUsed, _record(kB).currentUsdCharge, "Bob's depositor budget");
        uint256 used = k.regularUsed;
        assertEq(
            _requiredDelay(address(store), abi.encodeCall(IParameterStoreTighten.tightenMarketUsdCap, (mA, used))),
            SHORT_DELAY,
            "a cap tightening is short-delay"
        );
        bytes[4] memory tighten = [
            abi.encodeCall(IParameterStoreTighten.tightenMarketUsdCap, (mA, used + 10_000e8)),
            abi.encodeCall(IParameterStoreTighten.tightenTokenUsdCap, (aave.hub, address(usdt), 20_000e8)),
            abi.encodeCall(IParameterStoreTighten.tightenDepositorUsdCap, (aave.hub, 25_000e8)),
            abi.encodeCall(IParameterStoreTighten.tightenPoolShareMaxBps, (uint16(1)))
        ];
        bytes32[4] memory kinds = [bytes32("MARKET"), bytes32("TOKEN"), bytes32("DEPOSITOR"), bytes32(0)];
        for (uint256 i = 0; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            // `marketUsdCap` never goes below `topUpSliceUsd`: the slice is tightened first.
            if (i == 0) _govern(address(store), _sliceTo(1e8));
            _govern(address(store), tighten[i]);
            if (i == 3) lpVault.setMarketDepth(mA, 100_000e6);
            PledgeCounters memory before = coll.getCounters(vtA, bob);
            (bool ok, bytes memory ret,) = _tryPledge(bob, UNITS);
            assertFalse(ok, string.concat("the tightened cap refuses the pledge ", vm.toString(i)));
            if (i < 3) assertEq(ret, _capError(kinds[i]), "CapExceeded of that cap");
            else assertEq(bytes4(ret), IRiskModuleErrors.PoolShareExceeded.selector, "pool share above the cap");
            PledgeCounters memory afterK = coll.getCounters(vtA, bob);
            assertEq(afterK.regularUsed, before.regularUsed, "regular budget unchanged");
            assertEq(afterK.sliceUsed, before.sliceUsed, "slice unchanged");
            assertEq(afterK.depositorUsed, before.depositorUsed, "depositor budget unchanged");
            vm.revertToState(snap);
        }
    }

    // ─── TEST-039: price states with the tolerance from the ParameterStore ───

    /// @notice USDT's alternate route 1.3 % above its primary agrees within the listed 150 bps and the market stays
    /// Live; a tightening to 120 bps executed through the timelock at the short delay applies on the next read, and the
    /// market is Drifting with no override; with both routes stale the first failed read starts Cached, and after
    /// `cachedWindow` the market is Expired, whatever the disagreement.
    // TEST-039 verifies: REQ-ORACLE-016, REQ-ORACLE-018
    function test_TEST_039_toleranceTighteningAppliesOnTheNextRead() public {
        ILPOracle o = ILPOracle(address(mkt[mA].oracle));
        feedsOf[address(usdt)][1].push(101_300_000, block.timestamp);
        o.poke();
        assertEq(uint8(o.getPriceState().state), uint8(PriceState.Live), "within 150 bps");
        bytes memory call =
            abi.encodeCall(IParameterStoreTighten.tightenFeedAgreementToleranceBps, (address(usdt), 120));
        uint256 delay = _govern(address(store), call);
        assertEq(delay, SHORT_DELAY, "short delay");
        assertEq(store.feedAgreementToleranceBps(address(usdt)), 120, "tightened");
        // `_govern` republished every feed at its answer, the alternate's 1.3 % included.
        assertEq(uint8(o.getPriceState().state), uint8(PriceState.Drifting), "beyond 120 bps on the next read");
        o.poke();
        assertEq(uint8(o.getPriceState().state), uint8(PriceState.Drifting), "still Drifting after a poke");
        vm.warp(block.timestamp + FEED_AGE + 1);
        o.poke();
        assertEq(uint8(o.getPriceState().state), uint8(PriceState.Cached), "first failed read: Cached");
        vm.warp(block.timestamp + store.cachedWindow() + 1);
        assertEq(uint8(o.getPriceState().state), uint8(PriceState.Expired), "after cachedWindow: Expired");
    }

    // ─── TEST-054: route slots through the timelock ───

    /// @notice `setRoute` takes the normal delay and `disableRoute` and `restoreRoute` the short one; a disabled slot
    /// is not usable until restored, a route never approved for the slot is refused (`NotPreviouslyApproved`), a
    /// route through the pool being unwound or from a pool token into itself is refused, and the slot's depth threshold
    /// is a ParameterStore value the timelock tightens at the short delay.
    // TEST-054 verifies: REQ-CONFIG-059, REQ-CONFIG-061, REQ-CONFIG-062, REQ-CONFIG-070, REQ-ROUTE-017, Q-379
    function test_TEST_054_routeSlotsAndTheirDelays() public {
        (address route, bool usable) = registry.getRoute(mA, address(usdt), address(gho), 0);
        assertTrue(usable, "listed primary route usable");
        address fresh =
            address(new RegistryRouteMock(address(usdt), address(gho), address(swap), _list(makeAddr("dex 9"))));
        assertEq(
            _requiredDelay(
                address(registry),
                abi.encodeCall(IMarketRegistryRoutes.setRoute, (mA, address(usdt), address(gho), 0, fresh))
            ),
            NORMAL_DELAY,
            "setRoute: normal delay"
        );
        uint256 d = _govern(
            address(registry), abi.encodeCall(IMarketRegistryRoutes.disableRoute, (mA, address(usdt), address(gho), 0))
        );
        assertEq(d, SHORT_DELAY, "disableRoute: short delay");
        (, usable) = registry.getRoute(mA, address(usdt), address(gho), 0);
        assertFalse(usable, "disabled");
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.NotPreviouslyApproved.selector);
        registry.restoreRoute(mA, address(usdt), address(gho), 0, fresh);
        d = _govern(
            address(registry),
            abi.encodeCall(IMarketRegistryRoutes.restoreRoute, (mA, address(usdt), address(gho), 0, route))
        );
        assertEq(d, SHORT_DELAY, "restoreRoute: short delay");
        (, usable) = registry.getRoute(mA, address(usdt), address(gho), 0);
        assertTrue(usable, "restored");
        address throughPool =
            address(new RegistryRouteMock(address(usdt), address(gho), address(swap), _list(address(poolA))));
        vm.prank(address(timelock));
        vm.expectRevert();
        registry.setRoute(mA, address(usdt), address(gho), 1, throughPool);
        address intoItself =
            address(new RegistryRouteMock(address(usdc), address(usdc), address(swap), _list(makeAddr("dex 8"))));
        vm.prank(address(timelock));
        vm.expectRevert();
        registry.setRoute(mA, address(usdc), address(usdc), 0, intoItself);
        d = _govern(
            address(store),
            abi.encodeCall(
                IParameterStoreTighten.tightenRouteDepthThreshold, (mA, address(usdt), address(gho), 0, 50_000e18)
            )
        );
        assertEq(d, SHORT_DELAY, "depth threshold tightening: short delay");
        assertEq(store.routeDepthThreshold(mA, address(usdt), address(gho), 0), 50_000e18, "threshold in force");
    }

    // ─── TEST-125: the Hub add cap holds every budget ───

    /// @notice Pledges that fit the USD budgets also fit under the Hub `addCap` sized at `stressFloorUsd` (Q-175:
    /// `addCap × floor ≥ marketUsdCap + topUpSliceUsd`): filling the market budget at $2.00, then after a fall to $1.90
    /// and a debt-free exit, every refusal is the RiskModule's `CapExceeded(MARKET)`, never an Aave add-cap revert, and
    /// the Hub's added vault tokens stay within the add cap.
    // TEST-125 verifies: SPEC-CAP-006, MATH-UO-03, MATH-UO-28
    function test_TEST_125_budgetsFitUnderTheHubAddCap() public {
        uint256 assetId = mkt[mA].assetId;
        uint256 addCapUnits = uint256(IAaveV4Hub(aave.hub).getSpokeConfig(assetId, aave.cdpSpoke).addCap) * 1e6;
        assertGe(uint256(VT_ADD_CAP) * 1e8, 1_000_000e8 + 100_000e8, "Q-175 sizing at a $1.00 floor");
        address[4] memory depositors = [carol, makeAddr("dan"), makeAddr("erin"), makeAddr("frank")];
        uint128 chunk = 100_000e6;
        bool refused = false;
        for (uint256 round = 0; round < 2; ++round) {
            for (uint256 i = 0; i < 12; ++i) {
                (bool ok, bytes memory ret,) = _tryPledge(depositors[i % 4], chunk);
                assertLe(IAaveV4Hub(aave.hub).getAddedAssets(assetId), addCapUnits, "within the add cap");
                if (!ok) {
                    assertEq(ret, _capError("MARKET"), "the market budget refuses first");
                    refused = true;
                    break;
                }
            }
            if (round == 0) {
                _publish(address(usdc), 95_000_000);
                _publish(address(usdt), 95_000_000);
                mkt[mA].oracle.poke();
                uint128 credited = _record(kB).credited;
                vm.prank(bob);
                adapterC.withdraw(mA, _ref(kB), credited, _deadline(), 0);
            }
        }
        assertTrue(refused, "the budget was reached");
    }

    // ─── TEST-238: re-credit ───

    /// @notice After a third party adds liquidity to Bob's custodied position, only Bob can re-credit it; the added
    /// units are credited and minted to his proxy's supply, booked against the caps at the LPOracle price; nothing left
    /// to add reverts `NothingToRecredit`; and once the market cap (tightened through the timelock) has no room, a
    /// re-credit reverts `CapExceeded(MARKET)`.
    // TEST-238 verifies: REQ-COLL-015, REQ-COLL-016, SPEC-BACK-013, REQ-VAULT-015, Q-254
    function test_TEST_238_recreditThroughTheRealRiskModule() public {
        uint128 added = 1000e6;
        lpVault.addUnits(kB, added);
        vm.prank(carol);
        vm.expectRevert();
        IAaveAdapterCollateral(adapter).recredit(mA, _ref(kB), "", _deadline());
        uint256 supply = ERC20(vtA).totalSupply();
        uint256 shares = _sharesOf(pB, mkt[mA].reserveId);
        uint256 usedBefore = coll.getCounters(vtA, bob).regularUsed;
        vm.prank(bob);
        uint128 got = IAaveAdapterCollateral(adapter).recredit(mA, _ref(kB), "", _deadline());
        assertEq(got, added, "the added liquidity is credited");
        assertEq(ERC20(vtA).totalSupply(), supply + added, "and minted");
        assertGt(_sharesOf(pB, mkt[mA].reserveId), shares, "and supplied for Bob's proxy");
        assertEq(coll.getCounters(vtA, bob).regularUsed - usedBefore, _charge(added), "charged at the LPOracle price");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.NothingToRecredit.selector, kB));
        IAaveAdapterCollateral(adapter).recredit(mA, _ref(kB), "", _deadline());
        uint256 used = coll.getCounters(vtA, bob).regularUsed;
        _govern(address(store), _sliceTo(1e8));
        _govern(address(store), abi.encodeCall(IParameterStoreTighten.tightenMarketUsdCap, (mA, used)));
        lpVault.addUnits(kB, added);
        vm.prank(bob);
        vm.expectRevert(_capError("MARKET"));
        IAaveAdapterCollateral(adapter).recredit(mA, _ref(kB), "", _deadline());
    }

    // ─── TEST-163: the borrow checks poke the real oracles ───

    /// @notice A borrow pokes the market's LPOracle and the DebtOracle of the USDC reserve the account holds (the GHO
    /// reserve has a fixed price and no DebtOracle) before the RiskModule reads them.
    // TEST-163 verifies: REQ-ORACLE-036, REQ-ORACLE-096, REQ-RISK-056
    function test_TEST_163_borrowPokesTheRealOracles() public {
        vm.expectCall(address(mkt[mA].oracle), abi.encodeWithSelector(ILPOracle.poke.selector));
        vm.expectCall(address(usdcOracle), abi.encodeWithSelector(IDebtOracle.poke.selector));
        _borrowAs(alice, mA, ghoReserveId, 100e18);
    }

    /// @notice A repay and a debt-free withdrawal poke neither oracle.
    // TEST-163 verifies: REQ-ORACLE-036, REQ-ORACLE-096
    function test_TEST_163_repayAndDebtFreeExitPokeNoOracle() public {
        vm.expectCall(address(mkt[mA].oracle), abi.encodeWithSelector(ILPOracle.poke.selector), 0);
        vm.expectCall(address(usdcOracle), abi.encodeWithSelector(IDebtOracle.poke.selector), 0);
        vm.prank(alice);
        adapterC.repay(alice, mA, ghoReserveId, 50e18, false, _deadline());
        uint128 credited = _record(kB).credited;
        vm.prank(bob);
        adapterC.withdraw(mA, _ref(kB), credited, _deadline(), 0);
    }
}
