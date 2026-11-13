// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {IAaveAdapterCollateral} from "../../src/policy/aave-adapter/IAaveAdapterCollateral.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterUser} from "../../src/policy/aave-adapter/IAaveAdapterUser.sol";
import {IMarketRegistryPause} from "../../src/policy/market-registry/IMarketRegistryPause.sol";
import {IMarketRegistryRouteViews} from "../../src/policy/market-registry/IMarketRegistryRouteViews.sol";
import {IMarketRegistryViews} from "../../src/policy/market-registry/IMarketRegistryViews.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {Market} from "../../src/types/Market.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {FullStackMarkets} from "../utils/fixtures/FullStackMarkets.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FullStackMarketRegistryIntegrationTest
/// @notice The MarketRegistry's reads in the borrower flows, on the full real stack (`FullStackMarkets`): the real
/// MarketRegistry, ParameterStore, RiskModule, AaveAdapter, Collateralization, AvanaTimelock, the markets' real
/// LPOracles and the USDC DebtOracle on the real local Aave V4. The pause matrix runs on the registry's own guardian
/// calls; a faulty registry is the real one with one view answered by `vm.mockCall`.
/// @dev Markets A (pool 0.01 %) and B (pool 0.05 %), both USDC/USDT at $2.00 per vault token. Alice holds GHO and USDC
/// debt in market A; Bob is debt-free in market A.
/// forge-config: default.isolate = false
contract FullStackMarketRegistryIntegrationTest is FullStackMarkets {
    uint256 internal mA;
    uint256 internal mB;
    bytes32 internal kA;
    bytes32 internal kB;
    bytes32 internal kA2;
    address internal pA;
    address internal pB;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        mB = _addMarket(poolB);
        (kA, pA) = _pledgeAs(alice, mA, UNITS);
        _borrowAs(alice, mA, ghoReserveId, 2000e18);
        _borrowAs(alice, mA, usdcReserveId, 500e6);
        (kA2,) = _pledgeAs(alice, mA, UNITS / 4);
        (kB, pB) = _pledgeAs(bob, mA, UNITS);
        address[2] memory payers = [alice, carol];
        for (uint256 i = 0; i < 2; ++i) {
            gho.mint(payers[i], 1e30);
            usdc.mint(payers[i], 1e18);
            vm.startPrank(payers[i]);
            gho.approve(adapter, type(uint256).max);
            usdc.approve(adapter, type(uint256).max);
            vm.stopPrank();
        }
    }

    function _credited(
        bytes32 key
    ) internal view returns (uint128) {
        return coll.getRecord(coll.recordIdOf(V3, key)).credited;
    }

    // ─── Market identity (TEST-171, TEST-030) ───

    /// @dev Bob tops up market A with the MarketRegistry answering `marketOfVaultToken(vtA)` with `answer`.
    function _pledgeUnderAWrongMarketId(
        uint256 answer
    ) internal {
        address vtA = mkt[mA].vaultToken;
        vm.mockCall(
            address(registry), abi.encodeCall(IMarketRegistryViews.marketOfVaultToken, (vtA)), abi.encode(answer)
        );
        bytes32 key = _newKey();
        lpVault.mintPosition(key, bob, mA, UNITS / 4);
        uint256 supplyBefore = ERC20(vtA).totalSupply();
        vm.expectCall(address(mkt[mA].oracle), abi.encodeWithSelector(ILPOracle.poke.selector), 1);
        vm.expectCall(address(mkt[mB].oracle), abi.encodeWithSelector(ILPOracle.poke.selector), 0);
        vm.expectCall(
            address(riskModule),
            bytes.concat(IRiskModuleChecks.checkPledge.selector, abi.encode(bob, pB, mA, V3, key, UNITS / 4))
        );
        vm.prank(bob);
        (address proxy, uint256 recordId, uint128 credited) = adapterC.pledge(mA, _ref(key), _deadline());
        assertEq(proxy, pB, "the market A proxy");
        assertEq(coll.getRecord(recordId).marketId, mA, "record in the vault token's market");
        assertEq(ERC20(vtA).totalSupply(), supplyBefore + credited, "market A units minted");
        assertEq(ERC20(mkt[mB].vaultToken).totalSupply(), 0, "nothing in market B");
    }

    /// @notice With the MarketRegistry answering `marketOfVaultToken` with another market's ID, a pledge still pokes
    /// the vault token's own LPOracle and never the other market's, passes the vault token's own market ID to
    /// `RiskModule.checkPledge`, and books and mints in market A; a position bound to market A pledged under market B
    /// is refused.
    // TEST-171 verifies: REQ-COLL-002, REQ-COLL-003, REQ-VAULT-014, INV-017, ATTACK-005, ATTACK-033, Q-126, Q-224, Q-240
    function test_TEST_171_pledgeIgnoresAnotherMarketsId() public {
        _pledgeUnderAWrongMarketId(mB);
        bytes32 wrong = _newKey();
        lpVault.mintPosition(wrong, bob, mA, UNITS / 4);
        vm.prank(bob);
        vm.expectRevert();
        adapterC.pledge(mB, _ref(wrong), _deadline());
    }

    /// @notice The same with the MarketRegistry answering that the vault token has no market.
    // TEST-171 verifies: REQ-COLL-002, REQ-VAULT-014, Q-126, Q-240
    function test_TEST_171_pledgeIgnoresAMissingMarketId() public {
        _pledgeUnderAWrongMarketId(0);
    }

    /// @notice The Adapter's mint and supply targets do not follow the MarketRegistry: the vault-token reserve is the
    /// one the Spoke derives from the Hub asset; with `getMarket` reporting a stale reserve ID, or naming an attacker
    /// Spoke, a pledge reverts and nothing is minted, supplied or taken into custody; a reserve the registry calls a
    /// debt reserve but the Spoke does not lend is never borrowed.
    // TEST-030 verifies: REQ-ADAPTER-065, REQ-ADAPTER-067, REQ-PROXY-062, INV-017, INV-073, Q-281
    function test_TEST_030_targetsDerivedAtCallTime() public {
        Market memory m = registry.getMarket(mA);
        uint256 assetId = IAaveV4Hub(aave.hub).getAssetId(m.vaultToken);
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getReserveId(aave.hub, assetId), mkt[mA].reserveId, "derived reserve");
        Market memory stale = m;
        stale.reserveId = mkt[mB].reserveId;
        Market memory hostile = m;
        hostile.spoke = makeAddr("attackerSpoke");
        Market[2] memory lies = [stale, hostile];
        for (uint256 i = 0; i < 2; ++i) {
            vm.mockCall(address(registry), abi.encodeCall(IMarketRegistryViews.getMarket, (mA)), abi.encode(lies[i]));
            bytes32 key = _newKey();
            lpVault.mintPosition(key, bob, mA, UNITS / 4);
            uint256 supply = ERC20(m.vaultToken).totalSupply();
            uint256 sharesA = _sharesOf(pB, mkt[mA].reserveId);
            vm.prank(bob);
            vm.expectRevert();
            adapterC.pledge(mA, _ref(key), _deadline());
            assertEq(ERC20(m.vaultToken).totalSupply(), supply, "no mint");
            assertEq(_sharesOf(pB, mkt[mA].reserveId), sharesA, "no supply");
            assertEq(_sharesOf(pB, mkt[mB].reserveId), 0, "nothing on the stale reserve");
            assertEq(lpVault.ownerOf(key), bob, "position not taken");
            vm.clearMockedCalls();
        }
        (bytes32 k2,) = _pledgeAs(bob, mA, UNITS / 4);
        assertEq(lpVault.depositorOf(k2), bob, "with the true record the pledge goes through");
        // The vault-token reserve of market B listed as a debt reserve by the registry: the Spoke does not lend it.
        vm.mockCall(
            address(registry),
            abi.encodeCall(IMarketRegistryRouteViews.isApprovedDebtReserve, (aave.cdpSpoke, mkt[mB].reserveId)),
            abi.encode(true)
        );
        uint256 n = adapterC.borrowNonce(pA);
        vm.prank(alice);
        vm.expectRevert();
        adapterC.borrow(mA, mkt[mB].reserveId, 1, alice, _deadline(), 0, n);
        assertEq(_debtOf(pA, mkt[mB].reserveId), 0, "no borrow of a reserve outside the Spoke's set");
    }

    // ─── Pause readers and pause matrix (TEST-162, TEST-192) ───

    /// @notice With the MarketRegistry reverting on `pauseState` and `pauseReason`, every path that must not read them
    /// still succeeds (repay by the owner and by a third party, debt-free withdrawal and partial removal, fee
    /// collection, `repayAllAndWithdraw`, a liquidation by LPVaultSwap), while the paths that gate on them (`pledge`,
    /// `borrow`) fail closed.
    // TEST-162 verifies: REQ-ADAPTER-044, REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-ACCESS-082
    function test_TEST_162_exitsNeverReadThePauseState() public {
        vm.mockCallRevert(
            address(registry), abi.encodeWithSelector(IMarketRegistryPause.pauseState.selector), "registry down"
        );
        vm.mockCallRevert(
            address(registry), abi.encodeWithSelector(IMarketRegistryPause.pauseReason.selector), "registry down"
        );
        vm.prank(alice);
        adapterC.repay(alice, mA, ghoReserveId, 100e18, false, _deadline());
        vm.prank(carol);
        adapterC.repay(alice, mA, ghoReserveId, 100e18, false, _deadline());
        lpVault.accrueFees(kB, 1000);
        vm.prank(bob);
        adapterC.collectFees(mA, _ref(kB), _deadline());
        vm.prank(bob);
        IAaveAdapterCollateral(adapter).removeLiquidity(mA, _ref(kB), UNITS / 10, _mins(), _deadline(), 0);
        uint128 creditedB = _credited(kB);
        vm.prank(bob);
        adapterC.withdraw(mA, _ref(kB), creditedB, _deadline(), 0);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (ghoReserveId, usdcReserveId);
        uint256[] memory spends = new uint256[](2);
        (spends[0], spends[1]) = (1e24, 1e12);
        uint128 creditedA = _credited(kA);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(mA, _ref(kA), creditedA, ids, spends, _deadline());
        assertEq(_debtOf(pA, ghoReserveId) + _debtOf(pA, usdcReserveId), 0, "debt repaid while the registry is down");
        bytes32 key = _newKey();
        lpVault.mintPosition(key, carol, mA, UNITS);
        vm.prank(carol);
        vm.expectRevert();
        adapterC.pledge(mA, _ref(key), _deadline());
        vm.clearMockedCalls();
        (, address pC) = _pledgeAs(carol, mA, UNITS);
        _borrowAs(carol, mA, ghoReserveId, 1000e18);
        vm.mockCallRevert(
            address(registry), abi.encodeWithSelector(IMarketRegistryPause.pauseState.selector), "registry down"
        );
        uint256 nonce = adapterC.borrowNonce(pC);
        vm.prank(carol);
        vm.expectRevert();
        adapterC.borrow(mA, ghoReserveId, 1e18, carol, _deadline(), 0, nonce);
    }

    /// @dev One action of the matrix from the current state; returns the revert data (empty on success).
    function _act(
        uint8 a
    ) internal returns (bool ok, bytes memory ret) {
        uint256 d = _deadline();
        if (a == 0 || a == 1) {
            address who = a == 0 ? carol : alice;
            bytes32 key = _newKey();
            lpVault.mintPosition(key, who, mA, UNITS / 4);
            vm.prank(who);
            return adapter.call(abi.encodeCall(IAaveAdapterUser.pledge, (mA, _ref(key), d)));
        }
        if (a == 2) {
            uint256 n = adapterC.borrowNonce(pA);
            vm.prank(alice);
            return adapter.call(abi.encodeCall(IAaveAdapterUser.borrow, (mA, ghoReserveId, 1e18, alice, d, 0, n)));
        }
        if (a == 3) {
            vm.prank(carol);
            return adapter.call(abi.encodeCall(IAaveAdapterUser.repay, (alice, mA, ghoReserveId, 100e18, false, d)));
        }
        if (a == 4) {
            uint128 units = _credited(kB);
            vm.prank(bob);
            return adapter.call(abi.encodeCall(IAaveAdapterUser.withdraw, (mA, _ref(kB), units, d, 0)));
        }
        if (a == 5) {
            uint128 units = _credited(kA2);
            vm.prank(alice);
            return adapter.call(abi.encodeCall(IAaveAdapterUser.withdraw, (mA, _ref(kA2), units, d, 0)));
        }
        lpVault.accrueFees(kB, 1000);
        vm.prank(bob);
        return adapter.call(abi.encodeCall(IAaveAdapterUser.collectFees, (mA, _ref(kB), d)));
    }

    /// @notice The pause matrix on the real MarketRegistry, each state set by the Emergency Guardian: None allows every
    /// action; Frozen reverts `ApplicationFrozen` for a pledge by an account with no debt and for `borrow` and allows
    /// an indebted account's top-up, third-party repay, debt-free withdrawal, withdraw-with-debt and fee collection;
    /// Paused(General) reverts `ApplicationPaused` for `borrow` and withdraw-with-debt, refuses a top-up that is not a
    /// rescue (`NotRescueTopUp` from the RiskModule) and allows repay, debt-free withdrawal and fee collection;
    /// Paused(MintPathSuspect) reverts `ApplicationPaused` for every pledge.
    // TEST-192 verifies: REQ-MREG-002, REQ-ADAPTER-080, REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-ADAPTER-082, REQ-ADAPTER-086, Q-356
    function test_TEST_192_pauseMatrixOnTheRealRegistry() public {
        bytes memory frozen = abi.encodeWithSelector(IAaveAdapterErrors.ApplicationFrozen.selector);
        bytes memory paused = abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector);
        // Actions: 0 new-account pledge, 1 indebted top-up, 2 borrow, 3 third-party repay, 4 debt-free withdrawal,
        // 5 withdraw with debt, 6 fee collection.
        for (uint8 s = 0; s < 4; ++s) {
            uint256 snap = vm.snapshotState();
            if (s == 1) _pause(PauseState.Frozen, PauseReason.None);
            if (s == 2) _pause(PauseState.Paused, PauseReason.General);
            if (s == 3) _pause(PauseState.Paused, PauseReason.MintPathSuspect);
            for (uint8 a = 0; a < 7; ++a) {
                uint256 inner = vm.snapshotState();
                (bool ok, bytes memory ret) = _act(a);
                string memory cell = string.concat("state ", vm.toString(s), " action ", vm.toString(a));
                if (s == 0) {
                    assertTrue(ok, cell);
                } else if (s == 1) {
                    if (a == 0 || a == 2) assertEq(ret, frozen, "Frozen: no-debt pledge and borrow");
                    else assertTrue(ok, cell);
                } else if (a == 2 || a == 5) {
                    assertEq(ret, paused, "Paused: borrow and withdraw-with-debt");
                } else if (a == 0 || a == 1) {
                    if (s == 3) {
                        assertEq(ret, paused, "MintPathSuspect: every pledge");
                    } else {
                        assertFalse(ok, "General: only a rescue top-up");
                        assertEq(bytes4(ret), IRiskModuleErrors.NotRescueTopUp.selector, "not a rescue top-up");
                    }
                } else {
                    assertTrue(ok, cell);
                }
                vm.revertToState(inner);
            }
            assertEq(uint8(registry.pauseState(aave.hub)), s == 0 ? 0 : s == 1 ? 1 : 2, "registry state");
            vm.revertToState(snap);
        }
    }
}
