// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapterCollateral} from "../../src/policy/aave-adapter/IAaveAdapterCollateral.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterUser} from "../../src/policy/aave-adapter/IAaveAdapterUser.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {CollRiskModuleMock} from "../utils/mocks/CollateralizationMocks.sol";
import {LPVaultSwapMock} from "../utils/mocks/LPVaultSwapMock.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title AaveAdapterPauseMatrixUnitTest
/// @notice The pause matrix of 2.6 and 2.15 on the real Aave V4 Spoke and Collateralization: every Adapter action in
/// each pause state of the market's Hub (None, Frozen, Paused(General), Paused(MintPathSuspect)), with the exact
/// outcome of each cell; the exits again with a MarketRegistry and a RiskModule that revert on every call; a frozen
/// wallet; and a pause of another Hub, which changes nothing.
/// @dev The RiskModule stand-in behind Collateralization refuses a pledge that must be a rescue top-up
/// (`RescueRequired`, standing in for the RiskModule's `NotRescueTopUp`), so a cell under `Paused(General)` shows the
/// `requireRescue` the Adapter passed. Each cell runs from the same state (`vm.snapshotState`).
/// forge-config: default.isolate = false
contract AaveAdapterPauseMatrixUnitTest is AaveAdapterFixture {
    enum Action {
        NewAccountPledge,
        IndebtedTopUp,
        DebtFreeTopUp,
        RecreditDebtFree,
        RecreditIndebted,
        Borrow,
        RepayPartial,
        RepayAll,
        ThirdPartyRepay,
        WithdrawDebtFree,
        WithdrawWithDebt,
        RemoveDebtFree,
        RemoveWithDebt,
        RepayAllAndWithdraw,
        RepayWithCollateral,
        CollectFees,
        ReleaseZeroCredit,
        RefreshDebtMark,
        Liquidation
    }

    uint256 internal constant ACTIONS = 19;

    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve");
    bytes32 internal kA1;
    bytes32 internal kA2;
    bytes32 internal kB1;
    bytes32 internal kB2;
    bytes32 internal kZero;
    address internal pA;
    address internal pB;
    address internal pDave;
    address internal pEve;

    function setUp() public override {
        super.setUp();
        riskModule.setEnforceRescue(true);
        // Alice: indebted account in market 4 with two records.
        (kA1, pA) = _pledgeAs(alice, MARKET_ID, UNITS);
        (kA2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
        _borrowAs(alice, MARKET_ID, debtReserveId, 5000e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 500e6);
        // Bob: debt-free account in market 4.
        (kB1, pB) = _pledgeAs(bob, MARKET_ID, UNITS);
        (kB2,) = _pledgeAs(bob, MARKET_ID, UNITS / 2);
        // Dave: liquidated in market B down to a record at zero credit.
        (bytes32 d1, address dp) = _pledgeAs(dave, MARKET_B, UNITS);
        (bytes32 d2,) = _pledgeAs(dave, MARKET_B, UNITS / 2);
        pDave = dp;
        _borrowAs(dave, MARKET_B, debtReserveId, 20_000e18);
        vtPrice.set(1.2e8);
        swap.liquidate(aave.cdpSpoke, MARKET_B, vtB, vtReserveIdB, debtReserveId, pDave, 20_000e18, 2);
        vtPrice.set(2e8);
        kZero = coll.getRecord(coll.recordIdOf(INTEGRATION, d1)).credited == 0 ? d1 : d2;
        require(coll.getRecord(coll.recordIdOf(INTEGRATION, kZero)).credited == 0, "zero-credit record");
        // Eve: a liquidatable account in market B once the price falls.
        (, pEve) = _pledgeAs(eve, MARKET_B, UNITS);
        _borrowAs(eve, MARKET_B, debtReserveId, 15_000e18);
        // Units added to the custodied positions, fees earned, funds and approvals for every payer.
        lpVault.addUnits(kA1, 1_000_000_000);
        lpVault.addUnits(kB1, 1_000_000_000);
        lpVault.accrueFees(kA1, 1000);
        address[2] memory payers = [alice, carol];
        for (uint256 i = 0; i < payers.length; ++i) {
            debt.mint(payers[i], 1e30);
            usdcDebt.mint(payers[i], 1e18);
            vm.startPrank(payers[i]);
            ERC20(address(debt)).approve(adapter, type(uint256).max);
            ERC20(address(usdcDebt)).approve(adapter, type(uint256).max);
            vm.stopPrank();
        }
        swap.setDeleverage(1000e18, 2e12, 0);
    }

    // ─── One cell ───

    /// @dev Runs `a` from the current state and returns its revert data (empty on success).
    function _run(
        Action a
    ) internal returns (bool ok, bytes memory ret) {
        uint256 d = _deadline();
        if (a == Action.NewAccountPledge || a == Action.IndebtedTopUp || a == Action.DebtFreeTopUp) {
            address who = a == Action.NewAccountPledge ? carol : a == Action.IndebtedTopUp ? alice : bob;
            bytes32 key = _newKey();
            lpVault.mintPosition(key, who, MARKET_ID, UNITS);
            return _as(who, abi.encodeCall(IAaveAdapterUser.pledge, (MARKET_ID, _ref(key), d)));
        }
        if (a == Action.RecreditDebtFree) {
            return _as(bob, abi.encodeCall(IAaveAdapterCollateral.recredit, (MARKET_ID, _ref(kB1), "", d)));
        }
        if (a == Action.RecreditIndebted) {
            return _as(alice, abi.encodeCall(IAaveAdapterCollateral.recredit, (MARKET_ID, _ref(kA1), "", d)));
        }
        if (a == Action.Borrow) {
            uint256 n = adapterC.borrowNonce(pA);
            return _as(alice, abi.encodeCall(IAaveAdapterUser.borrow, (MARKET_ID, debtReserveId, 1e18, alice, d, 0, n)));
        }
        if (a == Action.RepayPartial) {
            return
                _as(alice, abi.encodeCall(IAaveAdapterUser.repay, (alice, MARKET_ID, debtReserveId, 100e18, false, d)));
        }
        if (a == Action.RepayAll) {
            return _as(alice, abi.encodeCall(IAaveAdapterUser.repay, (alice, MARKET_ID, usdcReserveId, 1e12, true, d)));
        }
        if (a == Action.ThirdPartyRepay) {
            return
                _as(carol, abi.encodeCall(IAaveAdapterUser.repay, (alice, MARKET_ID, debtReserveId, 100e18, false, d)));
        }
        if (a == Action.WithdrawDebtFree) {
            return _as(bob, abi.encodeCall(IAaveAdapterUser.withdraw, (MARKET_ID, _ref(kB2), UNITS / 2, d, 0)));
        }
        if (a == Action.WithdrawWithDebt) {
            return _as(alice, abi.encodeCall(IAaveAdapterUser.withdraw, (MARKET_ID, _ref(kA2), UNITS / 2, d, 0)));
        }
        if (a == Action.RemoveDebtFree || a == Action.RemoveWithDebt) {
            (address who, bytes32 key) = a == Action.RemoveDebtFree ? (bob, kB2) : (alice, kA2);
            return _as(
                who,
                abi.encodeCall(
                    IAaveAdapterCollateral.removeLiquidity, (MARKET_ID, _ref(key), 1_000_000_000, _mins(), d, 0)
                )
            );
        }
        if (a == Action.RepayAllAndWithdraw) {
            uint256[] memory ids = new uint256[](2);
            (ids[0], ids[1]) = (debtReserveId, usdcReserveId);
            uint256[] memory caps = new uint256[](2);
            (caps[0], caps[1]) = (1e27, 1e12);
            return _as(
                alice,
                abi.encodeCall(IAaveAdapterUser.repayAllAndWithdraw, (MARKET_ID, _ref(kA2), UNITS / 2, ids, caps, d))
            );
        }
        if (a == Action.RepayWithCollateral) {
            return _as(
                alice,
                abi.encodeCall(
                    IAaveAdapterCollateral.repayWithCollateral, (_rwc(MARKET_ID, kA1, 500_000_000, debtReserveId))
                )
            );
        }
        if (a == Action.CollectFees) {
            return _as(alice, abi.encodeCall(IAaveAdapterUser.collectFees, (MARKET_ID, _ref(kA1), d)));
        }
        if (a == Action.ReleaseZeroCredit) {
            return _as(dave, abi.encodeCall(IAaveAdapterUser.releaseZeroCredit, (MARKET_B, _ref(kZero), d)));
        }
        if (a == Action.RefreshDebtMark) {
            return _as(attacker, abi.encodeCall(IAaveAdapterUser.refreshDebtMark, (pDave)));
        }
        vtPrice.set(1.5e8);
        (ok, ret) = address(swap)
            .call(
                abi.encodeCall(
                    LPVaultSwapMock.liquidate,
                    (aave.cdpSpoke, MARKET_B, vtB, vtReserveIdB, debtReserveId, pEve, 2000e18, 2)
                )
            );
    }

    function _as(
        address who,
        bytes memory data
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = adapter.call(data);
    }

    // ─── Expected outcomes (REQ-ADAPTER-045, 046, 072, 073, 083) ───

    bytes internal constant OK = "";

    /// @dev The exact revert data of `a` in state `s` (0 None, 1 Frozen, 2 Paused(General), 3 Paused(MintPathSuspect)),
    /// empty for success.
    function _expected(
        Action a,
        uint256 s
    ) internal pure returns (bytes memory) {
        bytes memory frozen = abi.encodeWithSelector(IAaveAdapterErrors.ApplicationFrozen.selector);
        bytes memory paused = abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector);
        bytes memory rescue = abi.encodeWithSelector(CollRiskModuleMock.RescueRequired.selector);
        if (a == Action.NewAccountPledge || a == Action.DebtFreeTopUp || a == Action.RecreditDebtFree) {
            return s == 0 ? OK : s == 1 ? frozen : s == 2 ? rescue : paused;
        }
        if (a == Action.IndebtedTopUp || a == Action.RecreditIndebted) {
            return s <= 1 ? OK : s == 2 ? rescue : paused;
        }
        if (a == Action.Borrow) return s == 0 ? OK : s == 1 ? frozen : paused;
        if (a == Action.WithdrawWithDebt || a == Action.RemoveWithDebt) return s <= 1 ? OK : paused;
        if (a == Action.RepayWithCollateral) return s <= 2 ? OK : paused;
        return OK;
    }

    function _setState(
        address hub,
        uint256 s
    ) internal {
        PauseState[4] memory states = [PauseState.None, PauseState.Frozen, PauseState.Paused, PauseState.Paused];
        PauseReason[4] memory reasons =
            [PauseReason.None, PauseReason.None, PauseReason.General, PauseReason.MintPathSuspect];
        registry.setPause(hub, states[s], reasons[s]);
    }

    function _matrix(
        uint256 s
    ) internal {
        _setState(aave.hub, s);
        for (uint256 i = 0; i < ACTIONS; ++i) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = _run(Action(i));
            bytes memory want = _expected(Action(i), s);
            if (want.length == 0) {
                assertTrue(ok, string.concat("action should pass: ", vm.toString(i)));
            } else {
                assertFalse(ok, string.concat("action should revert: ", vm.toString(i)));
                assertEq(ret, want, string.concat("revert data of action ", vm.toString(i)));
            }
            assertFalse(lock.isLocked(), "lock free after every cell");
            vm.revertToState(snap);
        }
    }

    // TEST-192 verifies: REQ-ADAPTER-044, REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-ACCESS-072, REQ-PROXY-032
    // Sources: 5.1 TEST-192 (None column)
    /// @notice In None every action passes.
    function test_TEST_192_none() public {
        _matrix(0);
    }

    // TEST-192 verifies: REQ-ADAPTER-045, REQ-ADAPTER-072, REQ-ADAPTER-083, REQ-ACCESS-073, REQ-ACCESS-079, REQ-ACCESS-080, INV-049
    // Sources: 5.1 TEST-192 (Frozen column)
    /// @notice Under Frozen a pledge or re-credit by an account with no debt and every borrow revert
    /// `ApplicationFrozen`; indebted top-ups and re-credits (with no rescue required), every exit, withdraw and removal
    /// with debt, repay with collateral and liquidation pass.
    function test_TEST_192_frozen() public {
        _matrix(1);
    }

    // TEST-192 verifies: REQ-ADAPTER-046, REQ-ADAPTER-073, REQ-ADAPTER-083, REQ-ADAPTER-088, REQ-ACCESS-079, REQ-ACCESS-080, REQ-ACCESS-162, INV-049
    // Sources: 5.1 TEST-192 (Paused(General) column), TEST-235
    /// @notice Under `Paused(General)` every pledge and re-credit is passed on as a rescue top-up (refused here as not
    /// one), borrow and the with-debt exits revert `ApplicationPaused`, and repay, the debt-free exits,
    /// `repayAllAndWithdraw`, repay with collateral, fee collection, zero-credit release, the debt mark and liquidation
    /// pass.
    function test_TEST_192_pausedGeneral() public {
        _matrix(2);
    }

    // TEST-192 verifies: REQ-ADAPTER-046, REQ-ADAPTER-073, REQ-ADAPTER-083, REQ-ACCESS-164, REQ-ACCESS-079, REQ-ACCESS-080, INV-049
    // Sources: 5.1 TEST-192 (Paused(MintPathSuspect) column)
    /// @notice Under `Paused(MintPathSuspect)` every pledge, top-up and re-credit, borrow, the with-debt exits and repay
    /// with collateral revert `ApplicationPaused`; repay, the debt-free exits, `repayAllAndWithdraw`, fee collection,
    /// zero-credit release, the debt mark and liquidation pass.
    function test_TEST_192_pausedMintPathSuspect() public {
        _matrix(3);
    }

    // TEST-235 verifies: REQ-ADAPTER-083, REQ-ADAPTER-046, REQ-ACCESS-074, REQ-ACCESS-162
    /// @notice A rescue top-up the RiskModule admits passes `Paused(General)` and is refused once the reason moves to
    /// `MintPathSuspect`.
    function test_TEST_235_rescueTopUpGeneralNotMintPath() public {
        riskModule.setEnforceRescue(false);
        riskModule.setRescue(true);
        _setState(aave.hub, 2);
        (bool ok,) = _run(Action.IndebtedTopUp);
        assertTrue(ok, "rescue top-up under General");
        _setState(aave.hub, 3);
        (bool ok2, bytes memory ret) = _run(Action.IndebtedTopUp);
        assertFalse(ok2, "refused under MintPathSuspect");
        assertEq(ret, abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector), "ApplicationPaused");
    }

    /// @dev The exits of REQ-ACCESS-068: repay (own, all, third party), debt-free withdrawal and removal,
    /// `repayAllAndWithdraw`, fee collection, zero-credit release, the debt mark and a liquidation's burn.
    function _isExit(
        Action a
    ) internal pure returns (bool) {
        return a == Action.RepayPartial || a == Action.RepayAll || a == Action.ThirdPartyRepay
            || a == Action.WithdrawDebtFree || a == Action.RemoveDebtFree || a == Action.RepayAllAndWithdraw
            || a == Action.CollectFees || a == Action.ReleaseZeroCredit || a == Action.RefreshDebtMark
            || a == Action.Liquidation;
    }

    // TEST-193 verifies: REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-ACCESS-068, REQ-ACCESS-148, INV-067, ATTACK-035
    // Sources: 5.1 TEST-193 (Adapter side), TEST-162
    /// @notice In each of the four states, with a MarketRegistry and a RiskModule that revert on every call, every exit
    /// still passes: none of them reads the pause state, the registry or a RiskModule gate.
    function test_TEST_193_exitsPassWithBrokenRegistryInEveryState() public {
        for (uint256 s = 0; s < 4; ++s) {
            _setState(aave.hub, s);
            registry.setBroken(true);
            risk.setBroken(true);
            for (uint256 i = 0; i < ACTIONS; ++i) {
                if (!_isExit(Action(i))) continue;
                uint256 snap = vm.snapshotState();
                (bool ok,) = _run(Action(i));
                assertTrue(ok, string.concat("exit must pass: ", vm.toString(i)));
                vm.revertToState(snap);
            }
            registry.setBroken(false);
            risk.setBroken(false);
        }
    }

    // TEST-162 verifies: REQ-ADAPTER-044, REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-ACCESS-082
    // Sources: 5.1 TEST-162 (Adapter side)
    /// @notice New activity fails closed when the registry reverts: every pledge, re-credit, borrow, the with-debt
    /// exits and repay with collateral revert.
    function test_TEST_162_newActivityFailsClosed() public {
        registry.setBroken(true);
        Action[8] memory gated = [
            Action.NewAccountPledge,
            Action.IndebtedTopUp,
            Action.RecreditDebtFree,
            Action.RecreditIndebted,
            Action.Borrow,
            Action.WithdrawWithDebt,
            Action.RemoveWithDebt,
            Action.RepayWithCollateral
        ];
        for (uint256 i = 0; i < gated.length; ++i) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = _run(gated[i]);
            assertFalse(ok, string.concat("new activity must fail closed: ", vm.toString(uint256(gated[i]))));
            vm.revertToState(snap);
        }
    }

    // TEST-192 verifies: REQ-ADAPTER-044, REQ-ADAPTER-098
    /// @notice A pause of another Hub in any state leaves every action of this market as in None.
    function test_TEST_192_otherHubPauseHasNoEffect() public {
        address other = makeAddr("otherHub");
        for (uint256 s = 1; s < 4; ++s) {
            _setState(other, s);
            for (uint256 i = 0; i < ACTIONS; ++i) {
                uint256 snap = vm.snapshotState();
                (bool ok,) = _run(Action(i));
                assertTrue(ok, string.concat("other Hub's pause applied to action ", vm.toString(i)));
                vm.revertToState(snap);
            }
        }
    }

    // TEST-229 verifies: REQ-ADAPTER-082, REQ-ADAPTER-087, REQ-ADAPTER-083, REQ-ACCESS-069, INV-024
    // Sources: 5.1 TEST-229
    /// @notice A frozen wallet (in None): borrow, withdraw with debt and removal with debt revert `AddressIsFrozen`, a
    /// top-up or re-credit must be a rescue, and repay, repay with collateral and fee collection pass; a frozen
    /// debt-free wallet keeps every debt-free exit.
    function test_TEST_229_frozenWalletRow() public {
        registry.setFrozen(alice, true);
        registry.setFrozen(bob, true);
        bytes memory frozenAlice = abi.encodeWithSelector(IAaveAdapterErrors.AddressIsFrozen.selector, alice);
        bytes memory rescue = abi.encodeWithSelector(CollRiskModuleMock.RescueRequired.selector);
        Action[8] memory acts = [
            Action.Borrow,
            Action.WithdrawWithDebt,
            Action.RemoveWithDebt,
            Action.IndebtedTopUp,
            Action.RecreditIndebted,
            Action.DebtFreeTopUp,
            Action.RecreditDebtFree,
            Action.RepayWithCollateral
        ];
        bytes[8] memory want = [frozenAlice, frozenAlice, frozenAlice, rescue, rescue, rescue, rescue, OK];
        for (uint256 i = 0; i < acts.length; ++i) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = _run(acts[i]);
            if (want[i].length == 0) {
                assertTrue(ok, "frozen wallet keeps this action");
            } else {
                assertEq(ret, want[i], string.concat("frozen row ", vm.toString(i)));
            }
            vm.revertToState(snap);
        }
        Action[6] memory exits = [
            Action.RepayPartial,
            Action.RepayAll,
            Action.WithdrawDebtFree,
            Action.RemoveDebtFree,
            Action.RepayAllAndWithdraw,
            Action.CollectFees
        ];
        for (uint256 i = 0; i < exits.length; ++i) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = _run(exits[i]);
            assertTrue(ok, string.concat("frozen wallet exit ", vm.toString(i)));
            vm.revertToState(snap);
        }
    }

    // TEST-192 verifies: REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-PROXY-032
    /// @notice The cells change state when they pass: a third-party repay under `Paused(MintPathSuspect)` lowers the
    /// debt and a debt-free withdrawal under Frozen returns the position.
    function test_TEST_192_passingCellsTakeEffect() public {
        _setState(aave.hub, 3);
        uint256 before = _debtOf(pA, debtReserveId);
        _run(Action.ThirdPartyRepay);
        assertEq(_debtOf(pA, debtReserveId), before - 100e18, "repaid under MintPathSuspect");
        _setState(aave.hub, 1);
        _run(Action.WithdrawDebtFree);
        assertEq(lpVault.ownerOf(kB2), bob, "position back under Frozen");
        assertEq(_sharesOf(pB, vtReserveId), UNITS, "one record left");
    }
}
