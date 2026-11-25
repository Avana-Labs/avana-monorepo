// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracle} from "../../src/LPOracle.sol";
import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {BandMath} from "../../src/libraries/BandMath.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {LPPriceMath} from "../../src/libraries/LPPriceMath.sol";
import {BigUint} from "../utils/BigUint.sol";
import {UniswapV2TestBase} from "../utils/UniswapV2TestBase.sol";
import {BandTestFeed, BandTestPriceSpoke, BandTestToken, BandTestVault} from "../utils/mocks/BandOracleMocks.sol";
import {FakeUniswapV2Pair} from "../utils/mocks/UniswapV2Mocks.sol";
import {MintableToken} from "../utils/mocks/UniswapV3Mocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Fuzzed attacks on the Uniswap v2 LPVault's √k credit and its in-kind unwind.
contract UniswapV2IntegrationFuzzTest is UniswapV2TestBase {
    function setUp() public {
        _deploy(address(new MintableToken("A", 18)), address(new MintableToken("B", 18)), 1000e18, 1000e18);
    }

    /// @dev Any sequence of price-moving swaps leaves a pledged position's live liquidity at or above its credit.
    function testFuzz_swapsNeverLowerLiveLiquidityBelowCredit(
        uint256[6] memory amounts,
        uint8 directions
    ) public {
        (bytes32 key, uint128 credit) = _position(user, 100e18, 100e18);
        for (uint256 i = 0; i < 6; ++i) {
            _swap(attacker, (directions >> i) & 1 == 1, bound(amounts[i], 1e6, 1e24));
        }
        (,,, uint128 live) = vault.positionInfo(key);
        assertGe(live, credit);
    }

    /// @dev A synced donation raises a holder's liquidity by less than half the donation (valued at the 1:1 fair price,
    /// full-range liquidity L is worth at most 2L), so donating to inflate collateral always loses.
    function testFuzz_donationGainBelowDonation(
        uint256 donation0,
        uint256 donation1,
        uint256 share
    ) public {
        donation0 = bound(donation0, 0, 1e24);
        donation1 = bound(donation1, 0, 1e24);
        share = bound(share, 1e15, 1e24);
        vm.assume(donation0 + donation1 > 0);
        (bytes32 key, uint128 credit) = _position(attacker, share, share);
        MintableToken(t0).mint(address(pair), donation0);
        MintableToken(t1).mint(address(pair), donation1);
        pair.sync();
        (,,, uint128 live) = vault.positionInfo(key);
        assertLe(2 * (uint256(live) - credit), donation0 + donation1);
    }

    /// @dev An unwind of any credit burns at most the position's proportional LP, pays out exactly what arrived, and
    /// leaves every other position's LP untouched, at any
    /// price an attacker pushes the pair to.
    function testFuzz_unwindTakesAtMostTheProportionalShare(
        uint256 creditPart,
        uint256 swapIn
    ) public {
        (bytes32 key, uint128 credit) = _position(user, 100e18, 100e18);
        (bytes32 keyB,) = _position(other, 30e18, 30e18);
        _swap(attacker, true, bound(swapIn, 0, 1e22));
        creditPart = bound(creditPart, 1, credit);
        uint256 held = _held(key);
        uint256 heldB = _held(keyB);
        vm.prank(adapter);
        (uint128 l, uint128 removed,,) = vault.unwind(key, uint128(creditPart), 0, 0, recipient);
        assertLe(removed, credit);
        // At most the proportional LP; none when it would redeem zero of a token (the dust stays).
        assertLe(held - _held(key), Math.mulDiv(held, l, credit));
        assertEq(_held(keyB), heldB);
        assertEq(_bal(t0, address(vault)), 0);
        assertEq(_bal(t1, address(vault)), 0);
    }
}

/// @notice Avana's value of Uniswap v2 LP tokens against Aave's own v2 LP price, `UniswapV2PriceProvider`'s geometric
/// formula `2 · √(v0 · v1) / supply` with `v_i = r_i · p_i / 10^d_i`, over every pair state: random reserves, LP
/// supply and holding, the protocol fee on or off, and `kLast` 0, below `k` or at or above it. Aave adds the fee v2-core
/// would mint next, `supply · (√k − √kLast) / (5√k + √kLast)`, when the fee is on and `kLast` is set below `k`.
/// Avana's value is `liquidityOf(lp)` vault-token units at the full-range `LPOracle` answer, with the market's unit
/// decimals chosen as `RiskModule` lists them (`BandMath.unitDecimals`).
contract UniswapV2AavePriceFuzzTest is UniswapV2TestBase {
    using BigUint for uint256[];

    uint256 internal constant MARKET = 7;

    BandTestVault internal bands;
    BandTestPriceSpoke internal priceSpoke;

    struct State {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 lp;
        uint256 kLast;
        bool feeOn;
        uint256 p0;
        uint256 p1;
        uint8 d0;
        uint8 d1;
    }

    function setUp() public {
        _deploy(address(new MintableToken("A", 18)), address(new MintableToken("B", 18)), 1000e18, 1000e18);
        bands = new BandTestVault();
        priceSpoke = new BandTestPriceSpoke(8);
        priceSpoke.init();
    }

    /// @notice Bug hunted: Avana valuing v2 LP above Aave's geometric price in some fee state: a supply adjustment
    /// that differs from v2-core's `_mintFee` (wrong sign, missing when the fee is on, counted when `kLast` is at or
    /// above `k`), or rounding up anywhere between the √k share and the oracle answer. Checked exactly in big integers,
    /// `(A · S)² · 10^(d0 + d1) ≤ 4 · lp² · r0 · r1 · p0 · p1`. The liquidity also equals the √k share at Aave's supply
    /// whenever the fee is on or `kLast` is 0, and is at most it otherwise (Avana counts a pending fee while the fee is
    /// off, Aave does not).
    function testFuzz_valueNeverAboveAaveGeometricPrice(
        uint256[5] memory st,
        uint256[2] memory prices,
        uint8[2] memory decs,
        uint8 feeMode
    ) public {
        State memory c = _state(st, prices, decs, feeMode);
        FakeUniswapV2Pair fake = _pair(c);
        uint256 l = vault.liquidityOf(address(fake), c.lp);

        uint256 rootK = Math.sqrt(c.r0 * c.r1);
        uint256 aaveSupply = _aaveSupply(c, rootK);
        uint256 share = Math.mulDiv(c.lp, rootK, aaveSupply);
        if (c.feeOn || c.kLast == 0) assertEq(l, share, "liquidity differs from the share at Aave's supply");
        else assertLe(l, share, "liquidity above the share at Aave's supply");

        (uint256 answer, uint8 ud) = _answer(c);
        if (answer <= 1) return; // the floor of 1 Aave V4 needs; `LPOracle.unit.t.sol` covers it
        assertTrue(
            _withinAave(c, Math.mulDiv(l, answer, 10 ** ud), aaveSupply),
            "Avana's LP value above Aave's geometric price"
        );
    }

    /// @dev `(a · S)² · 10^(d0 + d1) ≤ 4 · lp² · r0 · r1 · p0 · p1`: `a` at most `2 · √(v0 · v1) · lp / S`, exactly.
    function _withinAave(
        State memory c,
        uint256 a,
        uint256 supply
    ) internal pure returns (bool) {
        uint256[] memory lhs = BigUint.from(a).mul(supply);
        lhs = lhs.mul(lhs).mul(10 ** (uint256(c.d0) + c.d1));
        uint256[] memory rhs = BigUint.from(c.lp).mul(c.lp).mul(c.r0).mul(c.r1);
        return lhs.lte(rhs.mul(c.p0).mul(c.p1).mul(4));
    }

    function _state(
        uint256[5] memory st,
        uint256[2] memory prices,
        uint8[2] memory decs,
        uint8 feeMode
    ) internal pure returns (State memory c) {
        c.r0 = bound(st[0], 1, type(uint112).max);
        c.r1 = bound(st[1], 1, type(uint112).max);
        c.supply = bound(st[2], 1, type(uint128).max);
        c.lp = bound(st[3], 1, c.supply);
        uint256 k = c.r0 * c.r1;
        uint256 mode = feeMode % 3;
        c.kLast = mode == 0 ? 0 : mode == 1 ? bound(st[4], 1, k) : bound(st[4], k, type(uint256).max);
        c.feeOn = (feeMode >> 2) & 1 == 1;
        c.p0 = bound(prices[0], 1, LPPriceMath.MAX_PRICE);
        c.p1 = bound(prices[1], 1, LPPriceMath.MAX_PRICE);
        c.d0 = uint8(bound(decs[0], 0, LPPriceMath.MAX_DECIMALS));
        c.d1 = uint8(bound(decs[1], 0, LPPriceMath.MAX_DECIMALS));
    }

    function _pair(
        State memory c
    ) internal returns (FakeUniswapV2Pair fake) {
        fake = new FakeUniswapV2Pair(t0, t1);
        // Bound to 112 bits above.
        // forge-lint: disable-next-line(unsafe-typecast)
        fake.setReserves(uint112(c.r0), uint112(c.r1));
        fake.mintLp(address(this), c.supply);
        fake.setKLast(c.kLast);
        factory.setFeeTo(c.feeOn ? makeAddr("feeTo") : address(0));
    }

    /// @dev `UniswapV2PriceProvider.getTotalSupplyAtWithdrawal`: v2-core's pending fee mint, only with the fee on.
    function _aaveSupply(
        State memory c,
        uint256 rootK
    ) internal pure returns (uint256 supply) {
        supply = c.supply;
        uint256 rootKLast = Math.sqrt(c.kLast);
        if (c.feeOn && c.kLast != 0 && rootK > rootKLast) {
            supply += c.supply * (rootK - rootKLast) / (rootK * 5 + rootKLast);
        }
    }

    /// @dev The full-range LPOracle answer of the pair's tokens and the unit decimals `RiskModule` would list.
    function _answer(
        State memory c
    ) internal returns (uint256 answer, uint8 ud) {
        BandTestToken a = new BandTestToken("T0", c.d0);
        BandTestToken b = new BandTestToken("T1", c.d1);
        bands.setMarket(MARKET, address(a), address(b), ClTickMath.MIN_TICK, ClTickMath.MAX_TICK);
        // Prices are at most 1e18 < 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 id0 = priceSpoke.addReserve(address(a), c.d0, address(new BandTestFeed(8, int256(c.p0))));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 id1 = priceSpoke.addReserve(address(b), c.d1, address(new BandTestFeed(8, int256(c.p1))));
        ud = BandMath.unitDecimals(
            LPPriceMath.sqrtPriceX96(c.p0, c.p1, c.d0, c.d1),
            ClTickMath.MIN_TICK,
            ClTickMath.MAX_TICK,
            c.p0,
            c.p1,
            c.d0,
            c.d1
        );
        if (ud == 0) ud = 18;
        LPOracle oracle = new LPOracle(
            ILPOracle.Params({
                lpVault: address(bands),
                marketId: MARKET,
                unitDecimals: ud,
                priceSpoke: address(priceSpoke),
                reserveId0: id0,
                reserveId1: id1,
                description: "v2 fuzz"
            })
        );
        answer = uint256(oracle.latestAnswer());
    }
}
