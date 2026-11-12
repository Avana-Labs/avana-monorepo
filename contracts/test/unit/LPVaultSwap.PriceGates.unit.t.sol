// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title LPVaultSwapPriceGatesUnitTest
/// @notice The price rules of a liquidation, per seized market and per repaid reserve (2.11 REQ-SWAP-008, REQ-SWAP-009,
/// REQ-SWAP-091, Q-247): the LPOracle is poked before its state is read; Cached, Expired, liquidation-paused,
/// disagreement-paused and disagreement-expired markets and a leg older than `liquidationPriceMaxAge` revert
/// `StalePrice`; a repaid non-GHO reserve whose DebtOracle is not Live, is liquidation-paused or has a stale leg reverts
/// `DebtPriceStale(r)`; GHO's fixed source is never gated; inside a grace window only accounts below
/// `graceHealthFactor` are liquidated. The seized value uses the smaller collateral price and the larger debt price.
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
        return abi.encodeWithSelector(ILPVaultSwapErrors.StalePrice.selector);
    }

    function _debtStale() internal view returns (bytes memory) {
        return abi.encodeWithSelector(ILPVaultSwapErrors.DebtPriceStale.selector, usdcReserveId);
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

    /// @notice LPVaultSwap calls `poke()` before it reads the state: a failure the poke records (here a pending
    /// Expired transition) refuses the call that triggered it.
    // TEST-049 verifies: REQ-SWAP-008, Q-199
    function test_TEST_049_pokeBeforeRead() public {
        uint256 pokes = lpOracle.pokes();
        lpOracle.setPendingState(PriceState.Expired);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _stale());
        assertEq(uint8(lpOracle.state()), uint8(PriceState.Live), "the poke reverted with the call");
        lpOracle.setState(PriceState.Live);
        _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGt(lpOracle.pokes(), pokes, "poked in the call");
    }

    /// @notice (a) `liquidationPaused` (which includes a sequencer reporting down) and (d) the disagreement pause and a
    /// disagreement past `disagreementPauseMax` each refuse the seizure.
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

    /// @notice (c) Every used leg of every token is checked against the ParameterStore's `liquidationPriceMaxAge` of
    /// its feed: 88,200 s (86,400 s heartbeat plus 1,800 s margin) passes at exactly 88,200 s and fails at 88,201 s.
    // TEST-049 verifies: REQ-SWAP-008, REQ-SWAP-047, Q-182, Q-247
    // TEST-230 verifies: REQ-SWAP-008, INV-087
    function test_TEST_049_legAgeAgainstLiquidationMaxAge() public {
        store.setLiquidationPriceMaxAge(feed, 88_200);
        lpOracle.setLeg(1, 1, feed, uint64(block.timestamp - 88_201));
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _stale());
        lpOracle.setLeg(1, 1, feed, uint64(block.timestamp - 88_200));
        _liquidateAs(keeper, _params(proxy, 1950e6));
        // A tightened per-feed age applies at once: the ParameterStore is read on every call.
        store.setLiquidationPriceMaxAge(feed, 3600);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _stale());
        // The first token's first leg is checked too.
        store.setLiquidationPriceMaxAge(feed, 88_200);
        lpOracle.setLeg(0, 0, usdcFeed, uint64(block.timestamp - 100_000));
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _stale());
        // A future timestamp counts as age 0.
        lpOracle.setLeg(0, 0, usdcFeed, uint64(block.timestamp + 10));
        _liquidateAs(keeper, _params(proxy, 1950e6));
    }

    /// @notice REQ-SWAP-091: the repaid USDC reserve's DebtOracle is poked and must be Live, not liquidation-paused and
    /// within `liquidationPriceMaxAge` on every leg; otherwise `DebtPriceStale(r)`.
    // TEST-049 verifies: REQ-SWAP-091, REQ-SWAP-096, Q-238, Q-247, Q-248
    // TEST-226 verifies: REQ-SWAP-091
    function test_TEST_049_staleRepaidReserveRefused() public {
        usdcOracle.setState(PriceState.Cached, true);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _debtStale());
        usdcOracle.setState(PriceState.Drifting, false);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _debtStale());
        usdcOracle.setState(PriceState.Live, true);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _debtStale());
        usdcOracle.setState(PriceState.Live, false);
        usdcOracle.setLeg(0, usdcFeed, uint64(block.timestamp - 88_201));
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _debtStale());
        usdcOracle.setLeg(0, usdcFeed, uint64(block.timestamp - 88_200));
        usdcOracle.setLeg(1, feed, uint64(block.timestamp - 90_000));
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _debtStale());
        usdcOracle.setLeg(1, address(0), 0);
        uint256 pokes = usdcOracle.pokes();
        _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGt(usdcOracle.pokes(), pokes, "DebtOracle poked");
    }

    /// @notice The DebtOracle is poked before it is read: a pending Expired transition refuses the call.
    // TEST-049 verifies: REQ-SWAP-091, Q-199
    function test_TEST_049_debtOraclePokedBeforeRead() public {
        usdcOracle.setPendingState(PriceState.Expired);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _debtStale());
    }

    /// @notice GHO's fixed source is never gated: an account owing USDC and GHO is liquidated against its GHO debt
    /// while the USDC DebtOracle is Expired, and its USDC reserve is refused (the gate is per repaid reserve).
    // TEST-049 verifies: REQ-SWAP-091, INV-072, Q-247
    // TEST-226 verifies: REQ-SWAP-091, INV-072, Q-247, Q-248
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

    /// @notice REQ-SWAP-009 grace latch: inside a grace window an account at `HF >= graceHealthFactor` reverts
    /// `GraceHealthFactor`; below it, it is liquidated. The bound is read per call.
    // TEST-049 verifies: REQ-SWAP-009, REQ-SWAP-051, Q-129, Q-154, Q-324
    function test_TEST_049_graceHealthFactor() public {
        lpOracle.setFlags(false, false, false, true);
        uint256 hf = _hf(proxy);
        store.setGraceHealthFactor(hf);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.GraceHealthFactor.selector));
        store.setGraceHealthFactor(hf + 1);
        _liquidateAs(keeper, _params(proxy, 1950e6));
        // Outside grace the bound does not apply.
        lpOracle.setFlags(false, false, false, false);
        store.setGraceHealthFactor(0);
        _liquidateAs(keeper, _params(proxy, 1950e6));
    }

    /// @notice SPEC-LIQ-004: `Pc` is the smaller of the AaveOracle price and the LPOracle's served price, `Pdebt` the
    /// larger of the AaveOracle price and the DebtOracle's. With the AaveOracle at $1.00 for USDC and the DebtOracle at
    /// $1.01, Aave seizes at $1.00 and LPVaultSwap values the seizure at $1.01; with the AaveOracle at $2.00 for the
    /// vault token and the LPOracle at $2.10, LPVaultSwap values it at $2.00.
    // TEST-050 verifies: SPEC-LIQ-004, REQ-SWAP-008, Q-327
    function test_TEST_050_valuationPrices() public {
        uint256 snapshot = vm.snapshotState();
        LiquidationResult memory base = _liquidateAs(keeper, _params(proxy, 1950e6));
        vm.revertToState(snapshot);
        vm.mockCall(
            aave.cdpOracle,
            abi.encodeWithSignature("getReservePrice(uint256)", usdcReserveId),
            abi.encode(uint256(PRICE_UNIT))
        );
        usdcOracle.setAnswer(101_000_000);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(r.unitsSeized, base.unitsSeized, "Aave seized at its own $1.00");
        uint256 v = r.unitsSeized * P_VAULT / 101_000_000;
        assertEq(
            r.minOut,
            _floorOf(v, 100, 1 + _ceilDiv(P_USDT, 101_000_000), FLOOR_ROUNDING_ALLOWANCE_USDC),
            "floor at Pdebt = max(1.00, 1.01)"
        );
        assertLt(r.minOut, base.minOut, "V lower against the dearer debt price");
        vm.revertToState(snapshot);
        vm.mockCall(
            aave.cdpOracle,
            abi.encodeWithSignature("getReservePrice(uint256)", vtReserveId),
            abi.encode(uint256(200_000_000))
        );
        r = _liquidateAs(keeper, _params(proxy, 1950e6));
        v = r.unitsSeized * 200_000_000 / PRICE_UNIT;
        assertEq(r.minOut, _floorOf(v, 100, 2, FLOOR_ROUNDING_ALLOWANCE_USDC), "floor at Pc = min(2.00, 2.10)");
    }

    /// @notice A zero served price of the market (`latestAnswer <= 0`) reverts the valuation with
    /// `ZeroCollateralPrice` after Aave's own read fails or the seizure is refused; the call never settles at 0.
    // TEST-050 verifies: SPEC-LIQ-004
    function test_TEST_050_zeroLegPriceRefused() public {
        uint256[] memory prices = new uint256[](2);
        prices[0] = PRICE_UNIT;
        prices[1] = 0;
        lpOracle.setPrices(prices);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.ZeroCollateralPrice.selector));
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
        store.setGraceHealthFactor(0);
        (uint256 units,,) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertGt(units, 0, "settled in grace");
    }
}
