// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {RiskModule} from "../../../src/policy/risk-module/RiskModule.sol";
import {PriceState} from "../../../src/types/PriceState.sol";
import {RiskLPOracleMock, RiskSpokeMock, RiskSwapMock, RiskTokenMock} from "../../utils/mocks/RiskModuleMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @title RiskModuleHandler
/// @notice Random sequences of Aave, oracle, issuer and keeper changes, time steps, breaker pokes, guardian resets and
/// borrow-side pre-checks against the real RiskModule and MarketRegistry. Every pre-check that passes is compared with
/// an independent reading of the gates of 2.7; a pass while a gate is closed is a violation.
contract RiskModuleHandler is Test {
    struct World {
        RiskModule rm;
        MarketRegistry registry;
        RiskSpokeMock spoke;
        RiskLPOracleMock oracle;
        RiskSwapMock swap;
        RiskTokenMock usdt;
        address proxy;
        address guardian;
        uint256 marketId;
        uint256 vtReserve;
        uint256 debtReserve;
        uint256 feedAge;
    }

    World internal w;
    bool internal _vtPaused;
    bool internal _debtPaused;
    bool internal _frozen;
    bool internal _drift;
    bool internal _issuer;
    bool internal _offboarding;
    uint64 internal _reportAt;

    uint256 public violations;
    uint256 public latchShrinks;
    uint256 public borrowsWithoutKeeper;
    uint256 public borrows;
    uint256 public withdrawals;

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

    function setPauses(
        bool vtPaused,
        bool debtPaused,
        bool frozen
    ) external {
        (_vtPaused, _debtPaused, _frozen) = (vtPaused, debtPaused, frozen);
        _config();
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

    function offboard() external {
        if (_offboarding) return;
        _offboarding = true;
        vm.prank(address(w.rm.TIMELOCK()));
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

    function poke() external {
        (uint32 before,) = w.registry.marketBreaker(w.marketId);
        try w.rm.pokeBreakers(w.marketId) {} catch {}
        (uint32 afterPoke,) = w.registry.marketBreaker(w.marketId);
        if (afterPoke & before != before) ++latchShrinks;
    }

    function reset() external {
        vm.prank(w.guardian);
        try w.registry.resetMarketBreaker(w.marketId) {} catch {}
    }

    function borrow() external {
        bool clear = _clear(true);
        uint256 keepers = w.swap.activeKeeperCount();
        try w.rm.preBorrowCheck(w.proxy, w.debtReserve, 1) {
            ++borrows;
            if (!clear) ++violations;
            if (keepers == 0) ++borrowsWithoutKeeper;
        } catch {}
    }

    function withdraw() external {
        bool clear = _clear(false);
        try w.rm.preWithdrawCheck(w.proxy) {
            ++withdrawals;
            if (!clear) ++violations;
        } catch {}
    }

    /// @dev Every gate of 2.7 Borrow-side checks, read independently of the RiskModule's code.
    function _clear(
        bool isBorrow
    ) internal view returns (bool) {
        if (w.oracle.getPriceState().state != PriceState.Live || !w.oracle.getPriceState().borrowAllowed) return false;
        if (block.timestamp - _reportAt > w.feedAge) return false;
        if (_vtPaused || _debtPaused || _drift || _issuer) return false;
        if (isBorrow && (_frozen || _offboarding)) return false;
        if (w.swap.activeKeeperCount() == 0) return false;
        (uint32 latched, uint64 lastBreach) = w.registry.marketBreaker(w.marketId);
        if (latched != 0) return false;
        if (lastBreach != 0 && block.timestamp < uint256(lastBreach) + 1800) return false;
        return true;
    }

    function _config() internal {
        IAaveV4Spoke.ReserveConfig memory v;
        (v.paused, v.frozen, v.receiveSharesEnabled) = (_vtPaused, _frozen, _drift);
        w.spoke.setConfig(w.vtReserve, v);
        IAaveV4Spoke.ReserveConfig memory d;
        (d.paused, d.borrowable) = (_debtPaused, true);
        w.spoke.setConfig(w.debtReserve, d);
    }

    function _report() internal {
        address[] memory toks = new address[](2);
        address[] memory legFeeds = new address[](2);
        uint64[] memory ats = new uint64[](2);
        uint256[] memory quotes = new uint256[](2);
        (toks[0], toks[1]) = (tokens[0], tokens[1]);
        (legFeeds[0], legFeeds[1]) = (feeds[0], feeds[1]);
        (ats[0], ats[1]) = (_reportAt, _reportAt);
        (quotes[0], quotes[1]) = (1e8, 1e8);
        w.oracle.setTokens(toks, legFeeds, ats, quotes, new uint32[](2));
    }

    /// @dev The two tokens and their leg feeds, as the fixture reports them.
    address[2] internal tokens;
    address[2] internal feeds;

    function setLegs(
        address[2] calldata t,
        address[2] calldata f
    ) external {
        tokens = t;
        feeds = f;
    }
}
