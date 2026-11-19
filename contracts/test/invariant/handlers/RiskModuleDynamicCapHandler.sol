// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../../src/legacy/risk-module/IRiskModuleErrors.sol";
import {LegacyRiskModule} from "../../../src/legacy/risk-module/LegacyRiskModule.sol";
import {DynamicCap} from "../../../src/legacy/risk-module/types/RiskModuleTypes.sol";
import {RiskHubMock, RiskLPOracleMock} from "../../utils/mocks/RiskModuleMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @title RiskModuleDynamicCapHandler
/// @notice Random borrows by many accounts, repays, withdrawals with debt and time steps against the real
/// LegacyRiskModule's dynamic borrow cap. Every passing borrow is logged with the market's debt after it and the interval
/// the LegacyRiskModule stored; every refusal must be a cap error; every exit must pass whatever the cap holds.
contract RiskModuleDynamicCapHandler is Test {
    struct World {
        LegacyRiskModule rm;
        RiskHubMock hub;
        RiskLPOracleMock oracle;
        address adapter;
        address spoke;
        uint256 marketId;
        uint256 debtReserve;
        uint256 debtAsset;
        uint256 tau;
        address[] proxies;
        address[] tokens;
        address[] feeds;
    }

    World internal w;

    // Ghost logs of every passing borrow: the market's debt after it and the stored interval's start and cap.
    uint256[] public newDebt;
    uint256[] public intervalStart;
    uint256[] public cap;

    uint256 public unexpectedRefusals;
    uint256 public refusals;
    uint256 public exitFailures;
    uint256 public exits;
    uint256 public owed;

    constructor(
        World memory world,
        uint256 owed0
    ) {
        w = world;
        owed = owed0;
    }

    function borrowCount() external view returns (uint256) {
        return newDebt.length;
    }

    /// @notice A borrow of the debt reserve by one of the accounts, through the Adapter.
    function borrow(
        uint256 actor,
        uint256 amount
    ) external {
        address proxy = w.proxies[actor % w.proxies.length];
        amount = bound(amount, 1e18, 1_500_000e18);
        // $1.00 per token, 18 decimals: the debt reads rounded down, the borrow rounded up.
        uint256 debtAfter = owed / 1e10 + (amount + 1e10 - 1) / 1e10;
        vm.prank(w.adapter);
        try w.rm.preBorrowCheck(proxy, w.debtReserve, amount) {
            DynamicCap memory d = w.rm.getDynamicCap(w.marketId);
            newDebt.push(debtAfter);
            intervalStart.push(d.intervalStart);
            cap.push(d.cap);
            // Aave books the draw on the Spoke.
            owed += amount;
            w.hub.setOwed(w.debtAsset, w.spoke, owed, 0);
        } catch (bytes memory err) {
            ++refusals;
            if (bytes4(err) != IRiskModuleErrors.DynamicBorrowCapExceeded.selector) ++unexpectedRefusals;
        }
    }

    /// @notice A repay on the Spoke (no LegacyRiskModule call) and a withdrawal with debt, which must pass.
    function repayAndWithdraw(
        uint256 actor,
        uint256 amount
    ) external {
        amount = bound(amount, 0, owed);
        owed -= amount;
        w.hub.setOwed(w.debtAsset, w.spoke, owed, 0);
        ++exits;
        vm.prank(w.adapter);
        try w.rm.preWithdrawCheck(w.proxies[actor % w.proxies.length]) {}
        catch {
            ++exitFailures;
        }
    }

    /// @notice Time moves on by up to two intervals; the LPOracle reports again.
    function warp(
        uint256 dt
    ) external {
        dt = bound(dt, 1, 2 * w.tau);
        vm.warp(block.timestamp + dt);
        uint64[] memory ats = new uint64[](w.tokens.length);
        uint256[] memory quotes = new uint256[](w.tokens.length);
        for (uint256 i = 0; i < ats.length; ++i) {
            ats[i] = uint64(block.timestamp);
            quotes[i] = 1e8;
        }
        w.oracle.setTokens(w.tokens, w.feeds, ats, quotes, new uint32[](w.tokens.length));
    }
}
