// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapBase} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapBase.sol";
import {LiquidationParams, LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title LPVaultSwapPriceGatesUnitTest
/// @notice The price rules of a liquidation, per seized market and per repaid reserve (2.11 REQ-SWAP-008, REQ-SWAP-009,
/// REQ-SWAP-091, Q-247): the LPOracle is poked before its state is read; Cached, Expired, liquidation-paused,
/// disagreement-paused and disagreement-expired markets and a leg older than `liquidationPriceMaxAge` revert
/// `StalePrice`; a repaid non-GHO reserve whose DebtOracle is not Live, is liquidation-paused or has a stale leg reverts
/// `DebtPriceStale(r)`; GHO's fixed source is never gated. The seized value uses the smaller collateral price and the
/// larger debt price.
/// forge-config: default.isolate = false
contract LPVaultSwapPriceGatesUnitTest is LPVaultSwapUnitBase {
    address internal proxy;
    address internal feed = makeAddr("usdtFeed");
    address internal usdcFeed = makeAddr("usdcFeed");

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    function _stale() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ILPVaultSwapBase.StalePrice.selector);
    }

    function _debtStale() internal view returns (bytes memory) {
        return abi.encodeWithSelector(ILPVaultSwapBase.DebtPriceStale.selector, usdcReserveId);
    }

    /// @notice (b) Cached and Expired markets refuse seizure; Live and Drifting markets settle.
    // TEST-049 verifies: REQ-SWAP-008, REQ-SWAP-050, INV-030, Q-128
    function test_TEST_049_cachedOrExpiredMarketRefused() public {
        lpOracle.setState(PriceState.Cached);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _stale());
        lpOracle.setState(PriceState.Expired);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _stale());
        lpOracle.setState(PriceState.Drifting);
        _liquidateAs(keeper, _params(proxy, 1950e6));
        lpOracle.setState(PriceState.Live);
        _liquidateAs(keeper, _params(proxy, 1950e6));
    }

    /// @notice (a) `liquidationPaused` and (d) the disagreement pause and an expired disagreement each refuse the
    /// seizure.
    // TEST-049 verifies: REQ-SWAP-008, REQ-SWAP-050, INV-059, Q-208, Q-248
    function test_TEST_049_pausedOrDisagreeingMarketRefused() public {
        lpOracle.setFlags(true, false, false, false);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _stale());
        lpOracle.setFlags(false, true, false, false);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _stale());
        lpOracle.setFlags(false, false, true, false);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _stale());
        lpOracle.setFlags(false, false, false, false);
        _liquidateAs(keeper, _params(proxy, 1950e6));
    }

    /// @notice GHO's fixed source is never gated: an account owing USDC and GHO is liquidated against its GHO debt
    /// while the USDC DebtOracle is Expired, and its USDC reserve is refused (the gate is per repaid reserve).
    // TEST-049 verifies: REQ-SWAP-091, INV-072, Q-247
    // TEST-226 verifies: REQ-SWAP-091, INV-072, Q-247, Q-248
    // TEST-201 verifies: REQ-SWAP-091, INV-072; shared: TEST-201's per-reserve liquidation gate, USDC refused and GHO settled
    function test_TEST_226_ghoRepaidWhileUsdcOracleExpired() public {
        (address mixed,) = _openAccount(alice, 10_000e6, 16_000e6, 250_000_000);
        lpOracle.setAnswer(250_000_000);
        adapter.borrow(mixed, ghoReserveId, address(gho), 1000e18, alice);
        lpOracle.setAnswer(int256(P_VAULT));
        assertLt(_hf(mixed), 1e18, "liquidatable");
        usdcOracle.setState(PriceState.Expired, true);
        _expectLiquidateRevert(keeper, _params(mixed, 1950e6), _debtStale());
        LiquidationParams memory p = _params(mixed, 1050e18); // the whole GHO debt: Aave refuses a dust remainder
        p.debtReserveId = ghoReserveId;
        LiquidationResult memory r = _liquidateAs(keeper, p);
        assertEq(r.debtAsset, address(gho), "GHO repaid");
        assertGt(r.debtRepaid, 0, "GHO debt repaid");
    }

    /// @notice A zero served price of the market (`latestAnswer <= 0`) reverts the valuation with
    /// `ZeroCollateralPrice` after Aave's own read fails or the seizure is refused; the call never settles at 0.
    // TEST-050 verifies: SPEC-LIQ-004
    function test_TEST_050_zeroLegPriceRefused() public {
        uint256[] memory prices = new uint256[](2);
        prices[0] = PRICE_UNIT;
        prices[1] = 0;
        lpOracle.setPrices(prices);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapBase.ZeroCollateralPrice.selector));
    }

    /// @notice `settlePending` ignores grace but is refused while the market's price fails (no grace bound applies).
    // TEST-170 verifies: REQ-SWAP-066, REQ-SWAP-071
    function test_TEST_170_pendingIgnoresGraceButNotStalePrice() public {
        _seizeAndKeep(proxy, 1000e6);
        _liquidateAs(keeper, _params(proxy, 500e6));
        lpOracle.setState(PriceState.Expired);
        vm.expectRevert(_stale());
        lvs.settlePending(MARKET_ID, usdcReserveId);
        lpOracle.setState(PriceState.Live);
        lpOracle.setFlags(false, false, false, true);
        (uint256 units,,) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertGt(units, 0, "settled in grace");
    }
}
