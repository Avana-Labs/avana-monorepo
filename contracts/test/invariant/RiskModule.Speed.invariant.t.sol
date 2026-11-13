// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {SpeedView} from "../../src/policy/risk-module/types/SpeedView.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskModuleSpeedHandler} from "./handlers/RiskModuleSpeedHandler.sol";

/// @title RiskModuleSpeedInvariantTest
/// @notice TEST-324: borrows by six accounts, pledges, repays, withdrawals with debt and time steps of up to two windows,
/// against the real RiskModule. After every call: no interval of length τ holds more than the limit of its last charge
/// in the market, (Hub, asset) or pledge window; each stored window holds at least the charges of the last τ and at most
/// those of the last 2τ; every refusal is a speed error; every withdrawal with debt passed.
/// @dev World: the RiskModule fixture, GHO (fixed $1.00) borrowed, τ = 3,600 s, borrow 2,500 bps within $250,000 ..
/// $2,500,000 on the Spoke's GHO debt (starting at 1,000,000 GHO, raised by each borrow and lowered by each repay),
/// (Hub, GHO) 2,500 bps within 300,000 .. 3,000,000 GHO, pledge P_min = P_max = $1,000,000.
contract RiskModuleSpeedInvariantTest is RiskModuleFixture {
    uint256 internal constant TAU = 3600;
    uint256 internal constant ACCOUNTS = 6;

    RiskModuleSpeedHandler internal handler;

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
        rHub.setSpokeListed(GHO_ASSET, address(spoke), true);
        hub.setOwed(GHO_ASSET, address(spoke), 1_000_000e18, 0);
        store.setMarketSpeed(
            mid, MarketSpeedLimits(uint32(TAU), 2500, 0, 250_000e8, 2_500_000e8, 1_000_000e8, 1_000_000e8)
        );
        store.setDebtSpeed(address(hub), address(gho), SpeedLimit(2500, uint32(TAU), 300_000e18, 3_000_000e18));
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
        handler = new RiskModuleSpeedHandler(
            RiskModuleSpeedHandler.World({
                rm: riskModule,
                hub: rHub,
                oracle: oracle,
                adapter: address(adapter),
                collateralization: address(coll),
                spoke: address(spoke),
                wallet: wallet,
                marketId: mid,
                debtReserve: GHO_RESERVE,
                debtAsset: GHO_ASSET,
                tau: TAU,
                integrationId: V3,
                proxies: proxies,
                tokens: toks,
                feeds: feeds
            }),
            _counters(),
            1_000_000e18
        );
        targetContract(address(handler));
    }

    /// @dev Sum of `xs[j]` over the charges at times in `(t − τ, t]`.
    function _window(
        function(uint256) external view returns (uint256) ts,
        function(uint256) external view returns (uint256) xs,
        uint256 n,
        uint256 t,
        uint256 span
    ) internal view returns (uint256 s) {
        for (uint256 j = 0; j < n; ++j) {
            uint256 tj = ts(j);
            if (tj <= t && tj + span > t) s += xs(j);
        }
    }

    // TEST-324 verifies: INV-110, SPEC-CAP-011, REQ-RISK-092, ATTACK-205
    function invariant_TEST_324_borrowWindowsHoldTheirLimits() public view {
        uint256 n = handler.borrowCount();
        for (uint256 i = 0; i < n; ++i) {
            uint256 t = handler.borrowT(i);
            if (i + 1 < n && handler.borrowT(i + 1) == t) continue;
            assertLe(_window(handler.borrowT, handler.borrowUsd, n, t, TAU), handler.borrowLim(i), "market window");
            assertLe(_window(handler.borrowT, handler.debtUnits, n, t, TAU), handler.debtLim(i), "debt window");
        }
    }

    // TEST-324 verifies: INV-110, SPEC-CAP-011, REQ-RISK-093
    function invariant_TEST_324_pledgeWindowHoldsItsLimit() public view {
        uint256 n = handler.pledgeCount();
        for (uint256 i = 0; i < n; ++i) {
            uint256 t = handler.pledgeT(i);
            if (i + 1 < n && handler.pledgeT(i + 1) == t) continue;
            assertLe(_window(handler.pledgeT, handler.pledgeUsd, n, t, TAU), handler.pledgeLim(i), "pledge window");
        }
    }

    // TEST-324 verifies: INV-110, SPEC-CAP-011, REQ-RISK-095
    function invariant_TEST_324_storedWindowMatchesTheLog() public view {
        uint256 n = handler.borrowCount();
        (SpeedView memory m, SpeedView memory d) = riskModule.getBorrowSpeed(mid, GHO_RESERVE);
        uint256 now_ = block.timestamp;
        assertGe(m.used, _window(handler.borrowT, handler.borrowUsd, n, now_, TAU), "the last tau still counts");
        assertLe(m.used, _window(handler.borrowT, handler.borrowUsd, n, now_, 2 * TAU), "nothing older than 2 tau");
        assertGe(d.used, _window(handler.borrowT, handler.debtUnits, n, now_, TAU));
        assertLe(d.used, _window(handler.borrowT, handler.debtUnits, n, now_, 2 * TAU));
    }

    // TEST-324 verifies: REQ-RISK-094, REQ-RISK-098, REQ-RISK-099
    function invariant_TEST_324_exitsPassAndRefusalsAreSpeedErrors() public view {
        assertEq(handler.exitFailures(), 0, "a withdrawal with debt failed");
        assertEq(handler.unexpectedRefusals(), 0, "a refusal other than a speed error");
    }
}
