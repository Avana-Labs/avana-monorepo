// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../../src/policy/risk-module/IRiskModuleErrors.sol";
import {RiskModule} from "../../../src/policy/risk-module/RiskModule.sol";
import {PledgeCharge} from "../../../src/policy/risk-module/types/PledgeCharge.sol";
import {SpeedView} from "../../../src/policy/risk-module/types/SpeedView.sol";
import {PledgeCounters} from "../../../src/types/PledgeCounters.sol";
import {RiskHubMock, RiskLPOracleMock} from "../../utils/mocks/RiskModuleMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @title RiskModuleSpeedHandler
/// @notice Random borrows by many accounts, pledges, repays, withdrawals with debt and time steps against the real
/// RiskModule's speed windows (TEST-324). Every passing charge is logged with the limit the next check would have
/// seen; every refusal must be a speed error; every exit must pass whatever the windows hold.
contract RiskModuleSpeedHandler is Test {
    struct World {
        RiskModule rm;
        RiskHubMock hub;
        RiskLPOracleMock oracle;
        address adapter;
        address collateralization;
        address spoke;
        address wallet;
        uint256 marketId;
        uint256 debtReserve;
        uint256 debtAsset;
        uint256 tau;
        uint32 integrationId;
        address[] proxies;
        address[] tokens;
        address[] feeds;
    }

    World internal w;
    PledgeCounters internal k;

    // Ghost logs: time, charge and the limit of the check, per window.
    uint256[] public borrowT;
    uint256[] public borrowUsd;
    uint256[] public borrowLim;
    uint256[] public debtUnits;
    uint256[] public debtLim;
    uint256[] public pledgeT;
    uint256[] public pledgeUsd;
    uint256[] public pledgeLim;

    uint256 public unexpectedRefusals;
    uint256 public exitFailures;
    uint256 public exits;
    uint256 public owed;

    constructor(
        World memory world,
        PledgeCounters memory counters,
        uint256 owed0
    ) {
        w = world;
        k = counters;
        owed = owed0;
    }

    function borrowCount() external view returns (uint256) {
        return borrowT.length;
    }

    function pledgeCount() external view returns (uint256) {
        return pledgeT.length;
    }

    /// @notice A borrow of the debt reserve by one of the accounts, through the Adapter.
    function borrow(
        uint256 actor,
        uint256 amount
    ) external {
        address proxy = w.proxies[actor % w.proxies.length];
        amount = bound(amount, 1e18, 3_000_000e18);
        (SpeedView memory m, SpeedView memory d) = w.rm.getBorrowSpeed(w.marketId, w.debtReserve);
        vm.prank(w.adapter);
        try w.rm.preBorrowCheck(proxy, w.debtReserve, amount) {
            borrowT.push(block.timestamp);
            borrowUsd.push((amount + 1e10 - 1) / 1e10); // $1.00, 18 decimals, rounded up as charged
            borrowLim.push(m.limit);
            debtUnits.push(amount);
            debtLim.push(d.limit);
            // Aave books the draw on the Spoke.
            owed += amount;
            w.hub.setOwed(w.debtAsset, w.spoke, owed, 0);
        } catch (bytes memory err) {
            bytes4 s = bytes4(err);
            if (
                s != IRiskModuleErrors.BorrowSpeedExceeded.selector && s != IRiskModuleErrors.DebtSpeedExceeded.selector
            ) {
                ++unexpectedRefusals;
            }
        }
    }

    /// @notice A pledge through Collateralization.
    function pledge(
        uint256 units
    ) external {
        // At least the $10 minimum pledge ($2.00 per whole token), at most $800,000.
        units = bound(units, 5e18, 400_000e18);
        SpeedView memory p = w.rm.getPledgeSpeed(w.marketId);
        vm.prank(w.collateralization);
        try w.rm
            .checkPledge(
                w.wallet, w.proxies[0], w.marketId, w.integrationId, bytes32(uint256(1)), uint128(units), k, false
            ) returns (
            PledgeCharge memory c
        ) {
            pledgeT.push(block.timestamp);
            pledgeUsd.push(c.usdCharge);
            pledgeLim.push(p.limit);
        } catch (bytes memory err) {
            if (bytes4(err) != IRiskModuleErrors.PledgeSpeedExceeded.selector) ++unexpectedRefusals;
        }
    }

    /// @notice A repay on the Spoke (no RiskModule call) and a withdrawal with debt, which must pass.
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

    /// @notice Time moves on by up to two windows; the LPOracle reports again.
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
