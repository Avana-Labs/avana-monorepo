// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {AccountGateStatus} from "../../src/types/AccountGateStatus.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleSecondSourceUnitTest
/// @notice The LPOracle's second-source confirmation is a permission the RiskModule enforces itself on every borrow and
/// withdraw-with-debt (REQ-ORACLE-100): an unconfirmed token (token bit 4 disagrees, bit 5 unavailable, an
/// out-of-range configuration word included) or the market's second-source bit 16 refuses both with
/// `SecondSourceDisagrees`, even when the oracle's own `borrowAllowed` reads true; the price state stays Live and the
/// pledge, post-health and remaining-record checks, which repay, exits and liquidation rely on, never read it.
contract RiskModuleSecondSourceUnitTest is RiskModuleFixture {
    uint32 internal constant DISAGREE = 1 << 4;
    uint32 internal constant UNAVAILABLE = 1 << 5;
    uint256 internal constant MARKET_SECOND_SOURCE = 1 << 16;

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
    }

    function _tokens(
        uint32 r0,
        uint32 r1,
        uint64 at0,
        uint64 at1
    ) internal {
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        address[] memory feeds = new address[](2);
        (feeds[0], feeds[1]) = (feedUsdc, feedUsdt);
        uint64[] memory ats = new uint64[](2);
        (ats[0], ats[1]) = (at0, at1);
        uint32[] memory reasons = new uint32[](2);
        (reasons[0], reasons[1]) = (r0, r1);
        oracle.setTokens(toks, feeds, ats, new uint256[](2), reasons);
    }

    function _now() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _expectBoth(
        address token
    ) internal {
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.SecondSourceDisagrees.selector, token));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.SecondSourceDisagrees.selector, token));
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-020, REQ-ADAPTER-015
    function test_TEST_276_unconfirmedTokenRefusesBorrowAndWithdraw() public {
        // The oracle still reports Live with its own borrow flag on: the RiskModule's own read refuses.
        _tokens(0, UNAVAILABLE, _now(), _now());
        _expectBoth(address(usdt));
        _tokens(DISAGREE, 0, _now(), _now());
        _expectBoth(address(usdc));
        // Both unconfirmed: the first token in pool order is reported.
        _tokens(UNAVAILABLE, DISAGREE, _now(), _now());
        _expectBoth(address(usdc));
        _tokens(0, 0, _now(), _now());
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-276 verifies: REQ-ORACLE-100
    function test_TEST_276_marketSecondSourceFlagRefuses() public {
        oracle.setState(PriceState.Live, MARKET_SECOND_SOURCE, true);
        _expectBoth(address(0));
        oracle.setState(PriceState.Live, 0, true);
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-276 verifies: REQ-ORACLE-100, REQ-ADAPTER-015, REQ-ADAPTER-016
    function test_TEST_276_orderWithinTheCollateralPriceStep() public {
        // The price state comes first.
        oracle.setState(PriceState.Cached, MARKET_SECOND_SOURCE, false);
        _tokens(DISAGREE, DISAGREE, _now(), _now());
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mid, PriceState.Cached));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        oracle.setState(PriceState.Live, MARKET_SECOND_SOURCE, true);
        // Token by token: a stale first token is reported before the second token's confirmation.
        _tokens(0, DISAGREE, _now() - FEED_AGE - 1, _now());
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdc, FEED_AGE + 1));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        // An unconfirmed first token is reported before the second token's age.
        _tokens(DISAGREE, 0, _now(), _now() - FEED_AGE - 1);
        _expectBoth(address(usdc));
        // Every token confirmed but the market flag set, then the oracle's own borrow gate.
        _tokens(0, 0, _now(), _now());
        _expectBoth(address(0));
        oracle.setState(PriceState.Live, 0, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mid, PriceState.Live));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }

    // TEST-276 verifies: REQ-ORACLE-100
    function testFuzz_TEST_276_confirmation(
        uint32 r0,
        uint32 r1,
        bool marketFlag
    ) public {
        _tokens(r0, r1, _now(), _now());
        oracle.setState(PriceState.Live, marketFlag ? MARKET_SECOND_SOURCE : 0, true);
        bool bad0 = r0 & (DISAGREE | UNAVAILABLE) != 0;
        bool bad1 = r1 & (DISAGREE | UNAVAILABLE) != 0;
        if (bad0) {
            _expectBoth(address(usdc));
        } else if (bad1) {
            _expectBoth(address(usdt));
        } else if (marketFlag) {
            _expectBoth(address(0));
        } else {
            riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
            riskModule.preWithdrawCheck(address(proxy));
        }
    }

    // TEST-276 verifies: REQ-ORACLE-100, REQ-ADAPTER-038
    function test_TEST_276_statusReportsBothActionsRefused() public {
        _tokens(0, UNAVAILABLE, _now(), _now());
        AccountGateStatus memory s = riskModule.getAccountGateStatus(address(proxy));
        assertFalse(s.statusUnavailable);
        assertEq(uint8(s.markets[0].priceState), uint8(PriceState.Live));
        assertFalse(s.borrowAllowed);
        assertFalse(s.withdrawWithDebtAllowed);
        _tokens(0, 0, _now(), _now());
        s = riskModule.getAccountGateStatus(address(proxy));
        assertTrue(s.borrowAllowed);
        assertTrue(s.withdrawWithDebtAllowed);
    }

    // TEST-276 verifies: REQ-ORACLE-100, REQ-RISK-005
    function test_TEST_276_onlyBorrowSideChecksReadIt() public {
        // A pledge (new account and top-up), the post-health check and the remaining-record check do not depend on the
        // confirmation: the paths repay, exits and liquidation take never stop on it alone.
        _tokens(UNAVAILABLE, DISAGREE, _now(), _now());
        oracle.setState(PriceState.Live, MARKET_SECOND_SOURCE, true);
        _pledge(10_000e18, _counters(), false);
        assertEq(riskModule.postHealthCheck(address(proxy), 1e18), 1.5e18);
        riskModule.checkRemainingRecord(mid, 10_000e18);
        rSpoke.setAccount(address(proxy), type(uint256).max, 0, 0);
        rSpoke.setStatus(address(proxy), GHO_RESERVE, false, false);
        _pledge(10_000e18, _counters(), false);
    }

    // TEST-276 verifies: REQ-ORACLE-100, REQ-ADAPTER-024, REQ-ADAPTER-025
    function test_TEST_276_everyBorrowAndWithdrawPath() public {
        // Every borrowed reserve (fixed-price GHO, DebtOracle-priced USDC) and every withdraw-with-debt, whatever debt is
        // held, reads the confirmation after its poke.
        _enableUsdcDebt();
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
        _tokens(0, DISAGREE, _now(), _now());
        uint256[2] memory reserves = [GHO_RESERVE, USDC_RESERVE];
        for (uint256 i = 0; i < reserves.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.SecondSourceDisagrees.selector, address(usdt)));
            riskModule.preBorrowCheck(address(proxy), reserves[i], 1);
        }
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.SecondSourceDisagrees.selector, address(usdt)));
        riskModule.preWithdrawCheck(address(proxy));
        // The oracle's own borrow flag false with every token confirmed (for example token decimals not verified in
        // time) refuses both as not Live for borrowing.
        _tokens(0, 0, _now(), _now());
        oracle.setState(PriceState.Live, 0, false);
        for (uint256 i = 0; i < reserves.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mid, PriceState.Live));
            riskModule.preBorrowCheck(address(proxy), reserves[i], 1);
        }
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mid, PriceState.Live));
        riskModule.preWithdrawCheck(address(proxy));
        oracle.setState(PriceState.Live, 0, true);
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 1);
        riskModule.preWithdrawCheck(address(proxy));
    }
}
