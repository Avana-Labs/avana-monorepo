// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracle} from "../../src/LPOracle.sol";
import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {LPOracleTestBase} from "../utils/LPOracleTestBase.sol";
import {BandTestFeed, BandTestPriceSpoke, BandTestToken} from "../utils/mocks/BandOracleMocks.sol";

/// @notice Attacks and misconfigurations of the Aave V4 price source: a wrong or swapped reserve, a decimals mismatch,
/// an oracle that is not the price Spoke's, a source Aave cannot read, a source Aave governance swaps mid-life, and an
/// extreme price that puts the band's composition at an edge.
/// @dev The price Spoke runs the real pinned `AaveOracle`, so the `> 0` and source-decimals checks are Aave's own.
contract LPOracleAttacksUnitTest is LPOracleTestBase {
    uint256 internal constant MARKET = 1;
    uint256 internal constant MIRRORED = 2;
    uint256 internal constant STABLE = 3;
    int24 internal constant FULL_LOWER = -887_270;
    int24 internal constant FULL_UPPER = 887_270;

    /// @dev The pinned AaveOracle's errors.
    error InvalidPrice(uint256 reserveId);
    error InvalidSourceDecimals(uint256 reserveId);

    BandTestToken internal weth;
    BandTestToken internal usdc;
    BandTestToken internal usdt;
    BandTestFeed internal ethUsd;
    BandTestFeed internal usdcUsd;
    uint256 internal wethId;
    uint256 internal usdcId;
    uint256 internal usdtId;
    LPOracle internal oracle;

    function setUp() public {
        _setUpPriceSpoke();
        (weth, ethUsd, wethId) = _listed("WETH", 18, 2000e8);
        (usdc, usdcUsd, usdcId) = _listed("USDC", 6, 1e8);
        (usdt,, usdtId) = _listed("USDT", 6, 1e8);
        vault.setMarket(MARKET, address(weth), address(usdc), FULL_LOWER, FULL_UPPER);
        vault.setMarket(STABLE, address(usdc), address(usdt), -100, 100);
        oracle = _oracle(MARKET, wethId, usdcId);
    }

    // ─── Wrong reserve, order, decimals, oracle ───

    /// @notice Attack: list the LPOracle on the price Spoke's USDT reserve for a WETH/USDC market's token1.
    /// Invariant: each token is priced by its own Aave reserve. Result: the deployment reverts.
    function test_wrongReserve_underlyingMismatch_reverts() public {
        _expectInvalid(_params(MARKET, wethId, usdtId));
        _expectInvalid(_params(MARKET, usdtId, usdcId));
    }

    /// @notice Attack: give the reserves in the wrong order, which would price WETH at $1 and USDC at $2,000 (a WETH/USDC
    /// unit valued by the wrong composition). Invariant: reserve i is token i in pool order. Result: reverts.
    function test_swappedTokenOrder_reverts() public {
        _expectInvalid(_params(MARKET, usdcId, wethId));
    }

    /// @notice Attack: a reserve of the right token whose recorded decimals differ from the token's (a value off by
    /// 10^12). Invariant: the decimals Aave prices with are the token's. Result: reverts.
    function test_reserveDecimalsMismatch_reverts() public {
        uint256 wrongDecimals = priceSpoke.addReserve(address(weth), 6, address(ethUsd));
        _expectInvalid(_params(MARKET, wrongDecimals, usdcId));
    }

    /// @notice A reserve ID the price Spoke never listed fails in the Spoke itself.
    function test_unlistedReserve_reverts() public {
        vm.expectRevert(bytes("ReserveNotListed"));
        new LPOracle(_params(MARKET, wethId, 99));
    }

    /// @notice An AaveOracle with other than 8 decimals (which no real Spoke accepts) is refused: the math reads every
    /// price as 8-decimal.
    function test_oracleNotEightDecimals_reverts() public {
        BandTestPriceSpoke spoke18 = new BandTestPriceSpoke(18);
        spoke18.init();
        uint256 id0 = spoke18.addReserve(address(weth), 18, address(new BandTestFeed(18, 2000e18)));
        uint256 id1 = spoke18.addReserve(address(usdc), 6, address(new BandTestFeed(18, 1e18)));
        ILPOracle.Params memory p = _params(MARKET, id0, id1);
        p.priceSpoke = address(spoke18);
        _expectInvalid(p);
    }

    /// @notice Attack: a contract posing as a price Spoke whose `ORACLE()` is another Spoke's oracle. Invariant: the
    /// oracle prices the named Spoke's reserves. Result: reverts (the AaveOracle is bound to its own Spoke).
    function test_oracleOfAnotherSpoke_reverts() public {
        BandTestPriceSpoke impostor = new BandTestPriceSpoke(8);
        impostor.init();
        impostor.addReserve(address(weth), 18, address(ethUsd));
        impostor.addReserve(address(usdc), 6, address(usdcUsd));
        vm.mockCall(address(impostor), abi.encodeWithSignature("ORACLE()"), abi.encode(priceSpoke.ORACLE()));
        ILPOracle.Params memory p = _params(MARKET, 0, 1);
        p.priceSpoke = address(impostor);
        _expectInvalid(p);
    }

    /// @notice Token order: the same pair listed in the other pool order (USDC token0, WETH token1) values a full-range
    /// unit the same, so neither order is favoured.
    function test_mirroredPoolOrder_samePrice() public {
        vault.setMarket(MIRRORED, address(usdc), address(weth), FULL_LOWER, FULL_UPPER);
        LPOracle mirrored = _oracle(MIRRORED, usdcId, wethId);
        assertApproxEqRel(_answer(mirrored), _answer(oracle), 1e9, "mirrored order");
    }

    // ─── Sources Aave cannot read ───

    /// @notice A source answering 0 or below is refused by Aave's own check (`InvalidPrice(reserveId)`), so no zero or
    /// signed price reaches the math; the vault token is then as unreadable as Aave's own WETH reserve.
    function test_sourceZeroOrNegative_revertsWithAavesCheck() public {
        ethUsd.set(0);
        vm.expectRevert(abi.encodeWithSelector(InvalidPrice.selector, wethId));
        oracle.latestAnswer();
        ethUsd.set(-1);
        vm.expectRevert(abi.encodeWithSelector(InvalidPrice.selector, wethId));
        oracle.latestAnswer();
        ethUsd.set(2000e8);
        assertGt(_answer(oracle), 0, "recovers with the source");
    }

    /// @notice A source that reverts makes the read revert; nothing falls back to a stale or default price.
    function test_sourceReverts_reverts() public {
        usdcUsd.setReverting(true);
        vm.expectRevert(bytes("source down"));
        oracle.latestAnswer();
        vm.expectRevert(bytes("source down"));
        oracle.getPrices();
    }

    /// @notice An oracle cannot be deployed on a source that answers 0: both prices are read at construction.
    function test_deadSourceAtDeployment_reverts() public {
        usdcUsd.set(0);
        vm.expectRevert(abi.encodeWithSelector(InvalidPrice.selector, usdcId));
        new LPOracle(_params(MARKET, wethId, usdcId));
    }

    // ─── Aave governance swaps a source mid-life ───

    /// @notice Aave repoints USDC's reserve to a new source (say a CAPO adapter at $0.98): the next read uses it with
    /// no new LPOracle and no Avana vote; a source Aave refuses (18 decimals) never reaches the LPOracle.
    function test_sourceSwappedByAaveGovernance_followedOnNextRead() public {
        uint256 before = _answer(oracle);
        BandTestFeed capo = new BandTestFeed(8, 0.98e8);
        priceSpoke.updateReservePriceSource(usdcId, address(capo));
        (, uint256 p1,) = oracle.getPrices();
        assertEq(p1, 0.98e8, "the new source");
        // Full range: the unit value scales with the square root of each token's price.
        assertApproxEqRel(_answer(oracle), before * 98_994_949 / 100_000_000, 1e12, "sqrt(0.98)");

        BandTestFeed wrongDecimals = new BandTestFeed(18, 1e18);
        vm.expectRevert(abi.encodeWithSelector(InvalidSourceDecimals.selector, usdcId));
        priceSpoke.updateReservePriceSource(usdcId, address(wrongDecimals));
        (, p1,) = oracle.getPrices();
        assertEq(p1, 0.98e8, "a refused source changes nothing");
    }

    /// @notice A repoint to a source that answers 0 is refused by Aave at `setReserveSource`, so governance cannot
    /// leave the LPOracle on a dead source by mistake.
    function test_swapToDeadSource_refusedByAave() public {
        BandTestFeed dead = new BandTestFeed(8, 0);
        vm.expectRevert(abi.encodeWithSelector(InvalidPrice.selector, usdcId));
        priceSpoke.updateReservePriceSource(usdcId, address(dead));
        assertGt(_answer(oracle), 0);
    }

    // ─── Band edge ───

    /// @notice Attack: an extreme but valid token price that puts a custom band far above its upper edge.
    /// Invariant: the band is valued at its real one-sided composition, never negative or unbounded amounts.
    /// Result: all unit inventory is token1 and the answer is exactly its value.
    function test_extremePrice_upperBandClampUsesOneSidedInventory() public {
        usdcUsd.set(10_000_000_000e8);
        LPOracle custom = _oracle(STABLE, usdcId, usdtId);
        (uint256 amount0, uint256 amount1) = custom.getUnitAmounts();
        assertEq(amount0, 0, "above band holds no token0");
        assertGt(amount1, 0, "above band retains token1 inventory");
        assertEq(_answer(custom), amount1 * 1e2, "answer is the token1 edge value at six decimals");
    }

    function _expectInvalid(
        ILPOracle.Params memory p
    ) internal {
        vm.expectRevert(ILPOracle.InvalidParams.selector);
        new LPOracle(p);
    }
}
