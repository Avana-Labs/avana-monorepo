// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DynamicCap} from "../../src/legacy/risk-module/types/RiskModuleTypes.sol";
import {MarketDynamicCap} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskModuleDynamicCapHandler} from "./handlers/RiskModuleDynamicCapHandler.sol";

/// @title RiskModuleDynamicCapInvariantTest
/// @notice Borrows by six accounts, repays, withdrawals with debt and time steps of up to two intervals, against the
/// real LegacyRiskModule. After every call: the market's debt after each passing borrow is within the cap of the interval it
/// was made in; the borrows of one interval share one cap; stored intervals start at least tau apart; every refusal is
/// a cap error; every withdrawal with debt passed.
/// @dev World: the LegacyRiskModule fixture, GHO (fixed $1.00) borrowed, tau = 3,600 s, alpha 2,500 bps within $250,000 ..
/// $2,500,000 on the Spoke's GHO debt (starting at 1,000,000 GHO, raised by each borrow and lowered by each repay).
contract RiskModuleDynamicCapInvariantTest is RiskModuleFixture {
    uint256 internal constant TAU = 3600;
    uint256 internal constant ACCOUNTS = 6;

    RiskModuleDynamicCapHandler internal handler;

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
        hub.setOwed(GHO_ASSET, address(spoke), 1_000_000e18, 0);
        store.setMarketDynamicCap(mid, MarketDynamicCap(uint32(TAU), 2500, 250_000e8, 2_500_000e8));
        address[] memory proxies = new address[](ACCOUNTS);
        proxies[0] = address(proxy);
        for (uint256 i = 1; i < ACCOUNTS; ++i) {
            PositionProxy p = new PositionProxy(address(adapter), makeAddr(string(abi.encode(i))), address(spoke), mid);
            rSpoke.setStatus(address(p), VT_RESERVE, true, false);
            rSpoke.setStatus(address(p), GHO_RESERVE, false, true);
            rSpoke.setSupplied(address(p), VT_RESERVE, 1e21);
            rSpoke.setAccount(address(p), 1.5e18, 1000 * 1e26 * RAY, 1);
            proxies[i] = address(p);
        }
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        address[] memory feeds = new address[](2);
        (feeds[0], feeds[1]) = (feedUsdc, feedUsdt);
        handler = new RiskModuleDynamicCapHandler(
            RiskModuleDynamicCapHandler.World({
                rm: riskModule,
                hub: rHub,
                oracle: oracle,
                adapter: address(adapter),
                spoke: address(spoke),
                marketId: mid,
                debtReserve: GHO_RESERVE,
                debtAsset: GHO_ASSET,
                tau: TAU,
                proxies: proxies,
                tokens: toks,
                feeds: feeds
            }),
            1_000_000e18
        );
        targetContract(address(handler));
    }

    // INV-110, SPEC-CAP-011, REQ-RISK-092, ATTACK-205
    function invariant_debtAfterEachBorrowIsWithinItsIntervalsCap() public view {
        uint256 n = handler.borrowCount();
        for (uint256 i = 0; i < n; ++i) {
            assertLe(handler.newDebt(i), handler.cap(i), "debt after a borrow within the cap of its interval");
        }
    }

    function invariant_oneCapPerInterval() public view {
        uint256 n = handler.borrowCount();
        for (uint256 i = 1; i < n; ++i) {
            uint256 s0 = handler.intervalStart(i - 1);
            uint256 s1 = handler.intervalStart(i);
            assertGe(s1, s0, "intervals move forward");
            if (s1 == s0) assertEq(handler.cap(i), handler.cap(i - 1), "one cap per interval");
            else assertGe(s1, s0 + TAU, "a new interval opens only after tau");
        }
    }

    function invariant_storedIntervalMatchesTheLog() public view {
        uint256 n = handler.borrowCount();
        if (n == 0) return;
        DynamicCap memory d = riskModule.getDynamicCap(mid);
        assertEq(d.intervalStart, handler.intervalStart(n - 1), "the last borrow's interval is stored");
        assertEq(d.cap, handler.cap(n - 1));
    }

    // REQ-RISK-094, REQ-RISK-098, REQ-RISK-099
    function invariant_exitsPassAndRefusalsAreCapErrors() public view {
        assertEq(handler.exitFailures(), 0, "a withdrawal with debt failed");
        assertEq(handler.unexpectedRefusals(), 0, "a refusal other than a cap error");
    }
}
