// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {LegacyRiskModule} from "../../../src/legacy/risk-module/LegacyRiskModule.sol";
import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {PriceState} from "../../../src/types/OracleTypes.sol";
import {RiskLPOracleMock, RiskSpokeMock, RiskSwapMock, RiskTokenMock} from "../../utils/mocks/RiskModuleMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @title RiskModuleHandler
/// @notice Random sequences of Aave, oracle, issuer and keeper changes, time steps and borrow-side pre-checks against
/// the real LegacyRiskModule and MarketRegistry. Every pre-check that passes is compared with an independent reading of the
/// gates of 2.7; a pass while a gate is closed is a violation.
/// @dev Steered: three pre-checks in four first open every gate the handler controls, and half of those then close
/// exactly one, chosen by the seed, so each gate is tested alone at its boundary; the fourth runs on whatever state the
/// sequence left. A pre-check refused with every modelled gate open is counted (`refusedWhileClear`). The tokens and
/// leg feeds the oracle reports are set once in the constructor: an external setter was a fuzz target, and a call that
/// set every leg feed to address(0) left the LegacyRiskModule no feed age to check (an unused leg is skipped, 2.7 step (5)),
/// so a stale-feed gate the handler closed by warping could not be seen.
contract RiskModuleHandler is Test {
    /// @notice A call that found nothing to act on, or that the contract refused: reverting keeps it out of the
    /// campaign's success count, so the metrics show the calls that did real work.
    error Skipped();

    struct World {
        LegacyRiskModule rm;
        MarketRegistry registry;
        RiskSpokeMock spoke;
        RiskLPOracleMock oracle;
        RiskSwapMock swap;
        RiskTokenMock usdt;
        address proxy;
        uint256 marketId;
        uint256 vtReserve;
        uint256 debtReserve;
        uint256 feedAge;
        // The two tokens and their leg feeds, as the fixture reports them; fixed for the campaign.
        address[2] legTokens;
        address[2] legFeeds;
        // The account that holds the governance and tighten roles with no delay.
        address governor;
    }

    World internal w;
    bool internal _drift;
    bool internal _issuer;
    bool internal _offboarding;
    uint64 internal _reportAt;

    uint256 public violations;
    uint256 public borrowsWithoutKeeper;
    uint256 public borrows;
    uint256 public withdrawals;
    /// @notice Pre-checks refused while every gate the handler models was open.
    uint256 public refusedWhileClear;

    constructor(
        World memory world
    ) {
        w = world;
        _reportAt = uint64(block.timestamp);
    }

    function setPrice(
        uint8 s,
        bool borrowAllowed
    ) external {
        w.oracle.setState(PriceState(s % 4), s % 4 == 1 ? 1 << 3 : 0, borrowAllowed);
    }

    function setDrift(
        bool on
    ) external {
        _drift = on;
        _config();
    }

    function setIssuer(
        bool on
    ) external {
        _issuer = on;
        w.usdt.setPaused(on, false);
    }

    function setKeepers(
        uint8 n
    ) external {
        w.swap.setKeepers(n % 3);
    }

    /// @notice Offboards the market, which no call undoes: one seed in sixteen, so most runs keep testing the borrow
    /// gates and some test a borrow after offboarding.
    function offboard(
        uint256 seed
    ) external {
        if (_offboarding || uint256(keccak256(abi.encode(seed))) % 16 != 0) revert Skipped();
        _offboarding = true;
        vm.prank(w.governor);
        w.registry.setMarketOffboarding(w.marketId);
    }

    function refreshFeeds() external {
        _reportAt = uint64(block.timestamp);
        _report();
    }

    function warp(
        uint32 dt
    ) external {
        vm.warp(block.timestamp + (dt % 50_000));
    }

    function borrow(
        uint256 seed
    ) external {
        _steer(seed);
        bool clear = _clear(true);
        uint256 keepers = w.swap.activeKeeperCount();
        try w.rm.preBorrowCheck(w.proxy, w.debtReserve, 1) {
            ++borrows;
            if (!clear) ++violations;
            if (keepers == 0) ++borrowsWithoutKeeper;
        } catch {
            if (clear) ++refusedWhileClear;
            revert Skipped();
        }
    }

    function withdraw(
        uint256 seed
    ) external {
        _steer(seed);
        bool clear = _clear(false);
        try w.rm.preWithdrawCheck(w.proxy) {
            ++withdrawals;
            if (!clear) ++violations;
        } catch {
            if (clear) ++refusedWhileClear;
            revert Skipped();
        }
    }

    /// @dev Seed bits from a hash, so the fuzzer's small dictionary values still spread over the modes: mode 0 leaves
    /// the state as the sequence made it; 1 opens every gate; 2 and 3 open every gate and close one.
    function _steer(
        uint256 seed
    ) internal {
        uint256 h = uint256(keccak256(abi.encode(seed)));
        if (h % 4 == 0) return;
        _open();
        if (h % 4 == 1) return;
        _closeOne((h >> 8) % 6);
    }

    /// @dev Opens every gate the handler controls: Live price with borrowing allowed, fresh feeds, no drift, no issuer
    /// pause and one active keeper. Offboarding cannot be undone, so a borrow after it stays
    /// closed.
    function _open() internal {
        w.oracle.setState(PriceState.Live, 0, true);
        _drift = false;
        _config();
        _issuer = false;
        w.usdt.setPaused(false, false);
        if (w.swap.activeKeeperCount() == 0) w.swap.setKeepers(1);
        _reportAt = uint64(block.timestamp);
        _report();
    }

    /// @dev Closes one gate: the price Cached or with borrowing disallowed, a stale feed, drift, an issuer pause or no
    /// keeper.
    function _closeOne(
        uint256 gate
    ) internal {
        if (gate == 0) {
            w.oracle.setState(PriceState.Cached, 0, true);
        } else if (gate == 1) {
            w.oracle.setState(PriceState.Live, 0, false);
        } else if (gate == 2) {
            vm.warp(block.timestamp + w.feedAge + 1);
        } else if (gate == 3) {
            _drift = true;
            _config();
        } else if (gate == 4) {
            _issuer = true;
            w.usdt.setPaused(true, false);
        } else {
            w.swap.setKeepers(0);
        }
    }

    /// @dev Every gate of 2.7 Borrow-side checks, read independently of the LegacyRiskModule's code.
    function _clear(
        bool isBorrow
    ) internal view returns (bool) {
        if (!w.oracle.getPriceStatus().borrowFresh) return false;
        if (block.timestamp - _reportAt > w.feedAge) return false;
        if (_drift || _issuer) return false;
        if (isBorrow && _offboarding) return false;
        return w.swap.activeKeeperCount() != 0;
    }

    function _config() internal {
        IAaveV4Spoke.ReserveConfig memory v;
        v.receiveSharesEnabled = _drift;
        w.spoke.setConfig(w.vtReserve, v);
        IAaveV4Spoke.ReserveConfig memory d;
        d.borrowable = true;
        w.spoke.setConfig(w.debtReserve, d);
    }

    function _report() internal {
        address[] memory toks = new address[](2);
        address[] memory legFeeds = new address[](2);
        uint64[] memory ats = new uint64[](2);
        uint256[] memory quotes = new uint256[](2);
        (toks[0], toks[1]) = (w.legTokens[0], w.legTokens[1]);
        (legFeeds[0], legFeeds[1]) = (w.legFeeds[0], w.legFeeds[1]);
        (ats[0], ats[1]) = (_reportAt, _reportAt);
        (quotes[0], quotes[1]) = (1e8, 1e8);
        w.oracle.setTokens(toks, legFeeds, ats, quotes, new uint32[](2));
    }
}
