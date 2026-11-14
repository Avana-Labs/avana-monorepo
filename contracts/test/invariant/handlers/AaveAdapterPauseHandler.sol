// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../../src/custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveAdapter} from "../../../src/policy/aave-adapter/IAaveAdapter.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {AdapterRegistryMock, AdapterRiskModuleMock} from "../../utils/mocks/AaveAdapterMocks.sol";
import {CollLPVaultMock, CollPoolToken} from "../../utils/mocks/CollateralizationMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The contracts the pause handler drives.
struct PauseWorld {
    IAaveAdapter adapter;
    ICollateralizationViews coll;
    AdapterRegistryMock registry;
    AdapterRiskModuleMock risk;
    CollLPVaultMock lpVault;
    IAaveV4Spoke spoke;
    address hub;
    address vaultToken;
    uint256 market;
    uint256 reserve;
    CollPoolToken gho;
    uint256 ghoReserve;
    uint32 integrationId;
}

/// @title AaveAdapterPauseHandler
/// @notice Random pause-state, pause-reason, address-freeze and broken-neighbour transitions of the TEST-193 campaign,
/// interleaved with the borrower's actions. Exits (repay by the borrower or a third party, debt-free withdrawal,
/// `repayAllAndWithdraw`, fee collection, the debt mark) are asserted live inside the handler: any revert of one Aave
/// allows is counted in `exitFailures`. New activity (pledge, borrow, a withdrawal that leaves debt) is attempted in
/// every state and any success outside the states REQ-ADAPTER-045/046/082 allow is counted in `forbiddenSuccesses`.
contract AaveAdapterPauseHandler is Test {
    /// @notice A call that found nothing to act on, or that the contract refused: reverting keeps it out of the
    /// campaign's success count, so the metrics show the calls that did real work.
    error Skipped();

    PauseWorld internal w;
    address[3] internal wallets;
    address internal immutable PAYER;

    mapping(address => bytes32[]) internal keys;
    uint256 internal nonce;

    uint256 public exitFailures;
    uint256 public forbiddenSuccesses;
    uint256 public exitsDone;
    uint256 public refusalsSeen;
    bytes public lastExitError;

    constructor(
        PauseWorld memory world,
        address[3] memory wallets_,
        address payer
    ) {
        w = world;
        wallets = wallets_;
        PAYER = payer;
    }

    // ─── State transitions ───

    function setPause(
        uint8 seed
    ) external {
        uint8 s = seed % 4;
        if (s == 0) w.registry.setPause(w.hub, PauseState.None, PauseReason.None);
        if (s == 1) w.registry.setPause(w.hub, PauseState.Frozen, PauseReason.None);
        if (s == 2) w.registry.setPause(w.hub, PauseState.Paused, PauseReason.General);
        if (s == 3) w.registry.setPause(w.hub, PauseState.Paused, PauseReason.MintPathSuspect);
    }

    function setFreeze(
        uint8 actorSeed,
        bool on
    ) external {
        w.registry.setFrozen(wallets[actorSeed % 3], on);
    }

    function breakNeighbours(
        bool registryBroken,
        bool riskBroken
    ) external {
        w.registry.setBroken(registryBroken);
        w.risk.setBroken(riskBroken);
    }

    // ─── New activity: success only where the state allows it ───

    function pledge(
        uint8 actorSeed
    ) external {
        address wallet = wallets[actorSeed % 3];
        bytes32 key = keccak256(abi.encode("pause-handler", ++nonce));
        w.lpVault.mintPosition(key, wallet, w.market, 1_000_000_000);
        (PauseState st, PauseReason reason, bool frozen) = _state(wallet);
        address proxy = w.adapter.proxyOf(wallet, w.market);
        bool indebted = proxy != address(0) && w.spoke.getUserAccountData(proxy).borrowCount != 0;
        vm.prank(wallet);
        try w.adapter.pledge(w.market, PositionRef(w.integrationId, key), block.timestamp) {
            keys[wallet].push(key);
            if (st == PauseState.Paused && reason == PauseReason.MintPathSuspect) ++forbiddenSuccesses;
            if (st == PauseState.Frozen && !indebted) ++forbiddenSuccesses;
            if (frozen && proxy == address(0)) ++forbiddenSuccesses;
        } catch {
            ++refusalsSeen;
        }
    }

    function borrow(
        uint8 actorSeed,
        uint256 amount
    ) external {
        address wallet = wallets[actorSeed % 3];
        address proxy = w.adapter.proxyOf(wallet, w.market);
        if (proxy == address(0)) revert Skipped();
        amount = bound(amount, 1e18, 2000e18);
        (PauseState st,, bool frozen) = _state(wallet);
        uint256 n = w.adapter.borrowNonce(proxy);
        vm.prank(wallet);
        try w.adapter.borrow(w.market, w.ghoReserve, amount, wallet, block.timestamp, 0, n) {
            if (st != PauseState.None || frozen) ++forbiddenSuccesses;
        } catch {
            ++refusalsSeen;
        }
    }

    function withdrawWithDebt(
        uint8 actorSeed
    ) external {
        address wallet = wallets[actorSeed % 3];
        address proxy = w.adapter.proxyOf(wallet, w.market);
        if (proxy == address(0) || keys[wallet].length < 2) revert Skipped();
        if (w.spoke.getUserAccountData(proxy).borrowCount == 0) revert Skipped();
        (PauseState st,, bool frozen) = _state(wallet);
        bytes32 key = keys[wallet][keys[wallet].length - 1];
        uint256 units = w.coll.previewRelease(w.integrationId, key);
        vm.prank(wallet);
        try w.adapter.withdraw(w.market, PositionRef(w.integrationId, key), units, block.timestamp, 0) {
            keys[wallet].pop();
            if (st == PauseState.Paused || frozen) ++forbiddenSuccesses;
        } catch {
            ++refusalsSeen;
        }
    }

    // ─── Exits: must pass in every state ───

    function repay(
        uint8 actorSeed,
        bool thirdParty,
        uint256 amount
    ) external {
        address wallet = wallets[actorSeed % 3];
        address proxy = w.adapter.proxyOf(wallet, w.market);
        if (proxy == address(0)) revert Skipped();
        uint256 debt = w.spoke.getUserTotalDebt(w.ghoReserve, proxy);
        if (debt == 0) revert Skipped();
        amount = bound(amount, 1, debt);
        address payer = thirdParty ? PAYER : wallet;
        w.gho.mint(payer, amount);
        vm.prank(payer);
        w.gho.approve(address(w.adapter), amount);
        vm.prank(payer);
        try w.adapter.repay(wallet, w.market, w.ghoReserve, amount, false, block.timestamp) {
            ++exitsDone;
        } catch (bytes memory err) {
            _exitFailed(err);
        }
    }

    function repayAllAndWithdraw(
        uint8 actorSeed
    ) external {
        address wallet = wallets[actorSeed % 3];
        address proxy = w.adapter.proxyOf(wallet, w.market);
        if (proxy == address(0) || keys[wallet].length == 0) revert Skipped();
        uint256 debt = w.spoke.getUserTotalDebt(w.ghoReserve, proxy);
        uint256[] memory ids = new uint256[](1);
        ids[0] = w.ghoReserve;
        uint256[] memory caps = new uint256[](1);
        caps[0] = debt;
        if (debt != 0) {
            w.gho.mint(wallet, debt);
            vm.prank(wallet);
            w.gho.approve(address(w.adapter), debt);
        }
        bytes32 key = keys[wallet][keys[wallet].length - 1];
        uint256 units = w.coll.previewRelease(w.integrationId, key);
        vm.prank(wallet);
        try w.adapter
        .repayAllAndWithdraw(w.market, PositionRef(w.integrationId, key), units, ids, caps, block.timestamp) {
            keys[wallet].pop();
            ++exitsDone;
        } catch (bytes memory err) {
            _exitFailed(err);
        }
    }

    function withdrawDebtFree(
        uint8 actorSeed
    ) external {
        address wallet = wallets[actorSeed % 3];
        address proxy = w.adapter.proxyOf(wallet, w.market);
        if (proxy == address(0) || keys[wallet].length == 0) revert Skipped();
        if (w.spoke.getUserAccountData(proxy).borrowCount != 0) revert Skipped();
        bytes32 key = keys[wallet][keys[wallet].length - 1];
        uint256 units = w.coll.previewRelease(w.integrationId, key);
        vm.prank(wallet);
        try w.adapter.withdraw(w.market, PositionRef(w.integrationId, key), units, block.timestamp, 0) {
            keys[wallet].pop();
            ++exitsDone;
        } catch (bytes memory err) {
            _exitFailed(err);
        }
    }

    function collectFees(
        uint8 actorSeed,
        uint256 fees
    ) external {
        address wallet = wallets[actorSeed % 3];
        if (keys[wallet].length == 0) revert Skipped();
        bytes32 key = keys[wallet][0];
        w.lpVault.accrueFees(key, bound(fees, 0, 1e9));
        vm.prank(wallet);
        try w.adapter.collectFees(w.market, PositionRef(w.integrationId, key), block.timestamp) {
            ++exitsDone;
        } catch (bytes memory err) {
            _exitFailed(err);
        }
    }

    function refreshDebtMark(
        uint8 actorSeed
    ) external {
        address proxy = w.adapter.proxyOf(wallets[actorSeed % 3], w.market);
        if (proxy == address(0)) revert Skipped();
        vm.prank(PAYER);
        try w.adapter.refreshDebtMark(proxy) {
            ++exitsDone;
        } catch (bytes memory err) {
            _exitFailed(err);
        }
    }

    // ─── Helpers ───

    function _state(
        address wallet
    ) internal view returns (PauseState st, PauseReason reason, bool frozen) {
        st = w.registry.pauseStateOf(w.hub);
        reason = w.registry.pauseReasonOf(w.hub);
        frozen = w.registry.frozen(wallet);
        // A broken registry refuses every new action, so no state allows a success then.
        if (w.registry.broken()) st = PauseState.Paused;
    }

    function _exitFailed(
        bytes memory err
    ) internal {
        ++exitFailures;
        lastExitError = err;
    }

    function keyCount(
        address wallet
    ) external view returns (uint256) {
        return keys[wallet].length;
    }
}
