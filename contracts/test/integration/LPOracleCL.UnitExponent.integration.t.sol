// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ClUnitMath} from "../../src/amm/concentrated-liquidity/ClUnitMath.sol";
import {SettlementMath} from "../../src/liquidation/lp-vault-swap/SettlementMath.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {Market} from "../../src/types/Market.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {ClTestToken} from "../utils/fixtures/ClPoolFixture.sol";
import {ClIntegrationStub, LPOracleCLDeployer, LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {UniswapV3IntegrationHarness} from "../utils/harness/UniswapV3IntegrationHarness.sol";
import {OracleRegistryMock, OracleStoreMock} from "../utils/mocks/LPOracleMocks.sol";
import {MockNFPM} from "../utils/mocks/UniswapV3Mocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The vault-token unit of `SPEC-ORC-005` end to end on real Uniswap v3 pools: the real Uniswap v3 LPVault
/// binds the market (unit exponent `k` and decimals `d`), the real `LPOracleCL` is initialized with the pool's `k` in
/// its market argument, and once the MarketRegistry holds the market with the vault's `d`, the feed's `checkConfig`
/// returns 0 (`CHECK_MARKET`, `CL_CHECK_UNIT_EXP`). The feed's price of one whole token then equals the LPVault's
/// composition of `10^d` units valued at the listing prices, and pricing a real position by `n · price8 / 10^d` (Aave's
/// value, the health factor) and by `SettlementMath.seizedValue` (liquidation) stays at or just below what burning its
/// `n · 10^k` liquidity from the pool returns. Pools with `k = 0` and `k > 0`: WETH/DAI at $3,000 (18/18), DAI/USDT on
/// tick spacing 1 (18/6), an 18-decimal meme coin at $0.00001 against WETH and USDC on the 1 % tier and an 8-decimal
/// token at $90,000 against that meme coin, in both token orders. A pair whose raw price ratio, shocked by
/// `LISTING_SHOCK_FACTOR`, leaves `SPEC-ORC-009`'s lower branch but stays below `2^128` lists (INTEG-04); a feed
/// initialized with another `k` than the pool's is refused by `checkConfig`.
contract LPOracleCLUnitExponentIntegrationTest is LPOracleCLFixture {
    using Math for uint256;

    /// @dev The module's unit-exponent bit (`REQ-ORACLE-105` bit 7), shifted into the `checkConfig` bitmap.
    uint256 internal constant UNIT_EXP_BIT = (1 << 7) << LPOracleCodes.MODULE_CHECKS_SHIFT;
    /// @dev Token addresses that fix the pool order: the token placed at `LOW` is token0.
    address internal constant LOW = address(0x1000000000000000000000000000000000000001);
    address internal constant HIGH = address(0x2000000000000000000000000000000000000002);
    /// @dev Another market of the same pool, bound before the market under test.
    uint256 internal constant EARLIER = 7;

    UniswapV3IntegrationHarness internal vault;

    /// @dev One listing: token A at `priceA` with `decA` decimals, token B likewise, the fee tier, which token is
    /// token0, and the range: the full range for `spacings == 0`, else `spacings` tick spacings each side of the
    /// spacing that holds the price.
    struct Case {
        string symA;
        uint8 decA;
        uint256 priceA;
        bool stableA;
        string symB;
        uint8 decB;
        uint256 priceB;
        bool stableB;
        uint24 fee;
        bool aIsToken0;
        int24 spacings;
    }

    /// @dev What a listing found: the LPVault's `k` and `d`, the feed's answer.
    struct Listed {
        uint8 k;
        uint8 d;
        uint256 price8;
    }

    // ─── Pools with k > 0 ───

    // TEST-332 verifies: SPEC-ORC-005, SPEC-ORC-006, REQ-ORACLE-105, REQ-ORACLE-047, REQ-AMM-V3-002, SPEC-UNIT-001
    /// @notice WETH/DAI on the 0.3 % tier at $3,000 and $1, full range: one spacing of `10^19` liquidity is the first
    /// worth $1, so `k = 3`, and the full range lists at `d = 13` (the market of the 2026-11-13 rehearsal). A feed with
    /// `k = 0` would have found `d = 16`.
    function test_TEST_332_wethDaiFullRangeListsAtK3() public {
        Listed memory l = _listAndCheck(_wethDai(true, 0));
        assertEq(l.k, 3, "k = 3");
        assertEq(l.d, 13, "d = 13");
        l = _listAndCheck(_wethDai(false, 0));
        assertEq(l.k, 3, "k = 3, DAI token0");
        assertEq(l.d, 13, "d = 13, DAI token0");
    }

    // TEST-332 verifies: SPEC-ORC-005, SPEC-ORC-006, REQ-ORACLE-105
    /// @notice WETH/DAI on a narrow range, ten spacings each side, in both orders.
    function test_TEST_332_wethDaiNarrowRangeLists() public {
        Listed memory l = _listAndCheck(_wethDai(true, 10));
        assertEq(l.k, 3, "k = 3");
        _listAndCheck(_wethDai(false, 10));
    }

    // TEST-332 verifies: SPEC-ORC-005, SPEC-ORC-006, REQ-ORACLE-105, REQ-AMM-V3-002
    /// @notice DAI (18) / USDT (6) on the 0.01 % tier (spacing 1), ten ticks each side of the price: `k = 1`.
    function test_TEST_332_daiUsdtSpacingOneListsAtK1() public {
        Listed memory l = _listAndCheck(_daiUsdt(true));
        assertEq(l.k, 1, "k = 1, DAI token0");
        l = _listAndCheck(_daiUsdt(false));
        assertEq(l.k, 1, "k = 1, USDT token0");
    }

    // TEST-332 verifies: SPEC-ORC-005, SPEC-ORC-006, REQ-ORACLE-105
    /// @notice An 18-decimal meme coin at $0.00001 against WETH on the 1 % tier, full range and ten spacings each side,
    /// in both orders.
    function test_TEST_332_memeWethLists() public {
        _listAndCheck(_memeWeth(true, 0));
        _listAndCheck(_memeWeth(false, 0));
        _listAndCheck(_memeWeth(true, 10));
        _listAndCheck(_memeWeth(false, 10));
    }

    // TEST-332 verifies: SPEC-ORC-005, SPEC-ORC-006, REQ-ORACLE-105
    /// @notice The meme coin against USDC on the 1 % tier lists with the meme coin as token0, full range and ten
    /// spacings each side.
    function test_TEST_332_memeUsdcListsMemeFirst() public {
        _listAndCheck(_memeUsdc(true, 0));
        _listAndCheck(_memeUsdc(true, 10));
    }

    // TEST-332 verifies: SPEC-ORC-009, REQ-ORACLE-105
    /// @notice With USDC as token0 the raw ratio is `10^8 · 10^18 / (1,000 · 10^6) = 10^17`; shocked by 100 each way it is
    /// `10^21`, past the former `2^64` bound and far below `2^128`, so the market lists (INTEG-04).
    function test_TEST_332_memeUsdcListsUsdcFirst() public {
        _listAndCheck(_memeUsdc(false, 0));
    }

    // TEST-332 verifies: SPEC-ORC-005, SPEC-ORC-006, REQ-ORACLE-105
    /// @notice An 8-decimal token at $90,000 against the meme coin on the 1 % tier lists with the meme coin as token0.
    function test_TEST_332_btcMemeListsMemeFirst() public {
        _listAndCheck(_btcMeme(false, 0));
        _listAndCheck(_btcMeme(false, 10));
    }

    // TEST-332 verifies: SPEC-ORC-009, REQ-ORACLE-105
    /// @notice With the $90,000 token as token0 the raw ratio is `9·10^12 · 10^18 / (1,000 · 10^8) = 9·10^19`, past
    /// the former `2^64` bound before any shock and below `2^128` after it: the market lists (INTEG-04).
    function test_TEST_332_btcMemeListsBtcFirst() public {
        _listAndCheck(_btcMeme(true, 0));
    }

    // ─── Pools with k = 0 ───

    // TEST-332 verifies: SPEC-ORC-005, REQ-ORACLE-105
    /// @notice WETH/USDC on the 0.05 % tier, full range, and USDC/USDT on the 0.01 % tier: `k = 0`, units are
    /// liquidity, and the feed lists as before.
    function test_TEST_332_kZeroPoolsList() public {
        Listed memory l = _listAndCheck(Case("WETH", 18, 3000e8, false, "USDC", 6, 1e8, true, 500, true, 0));
        assertEq(l.k, 0, "WETH/USDC k = 0");
        l = _listAndCheck(Case("USDC", 6, 1e8, true, "USDT", 6, 1e8, true, 100, true, 10));
        assertEq(l.k, 0, "USDC/USDT k = 0");
    }

    // ─── The pool's exponent is shared ───

    // TEST-332 verifies: SPEC-ORC-005, SPEC-UNIT-002, REQ-ORACLE-105
    /// @notice A later market of a pool takes the exponent its first market fixed, not one recomputed at the later
    /// listing's prices: the WETH/DAI pool's first market binds full range at $3,000 (`k = 3`); after WETH falls to
    /// $300 the market under test lists ten spacings each side of the new price, where a first binding would find
    /// `k = 4`, and its feed carries the stored 3.
    function test_TEST_332_laterMarketKeepsPoolExponent() public {
        _setUpPool(_wethDai(true, 10));
        _bind(EARLIER, -_top(), _top(), price0, price1);
        assertEq(vault.unitExponent(EARLIER), 3, "first market k = 3");
        price0 = 300e8;
        (, uint8 fresh) = ClUnitMath.firstBindingExponent(_valuation(), pool.tickSpacing());
        assertEq(fresh, 4, "a first binding at $300 would take k = 4");
        _swapTo(pool, ClPriceMath.oracleSqrtPrice(price0, price1, token0.decimals(), token1.decimals()));
        (tickLower, tickUpper) = _range(10);
        vm.warp(block.timestamp + 2 * WINDOW);
        vm.roll(block.number + 300);
        _refreshFeeds();
        Listed memory l = _listWithK(3);
        assertEq(l.k, 3, "later market k = 3");
    }

    // ─── A feed with another exponent ───

    // TEST-332 verifies: SPEC-ORC-005, REQ-ORACLE-105, REQ-ORACLE-046
    /// @notice A WETH/DAI feed initialized with `k = 0` (the composition before this rule) finds `d = 16` and is
    /// refused once the market is bound and registered at the LPVault's `d = 13`: `CHECK_MARKET` and the unit-exponent
    /// bit. One with `k = 4` finds `d = 12`: the same two bits.
    function test_TEST_332_feedWithAnotherExponentIsRefused() public {
        for (uint8 wrong = 0; wrong <= 4; wrong += 4) {
            _setUpPool(_wethDai(true, 0));
            _deployOracle(wrong);
            (, uint8 d) = _bind(MARKET, tickLower, tickUpper, price0, price1);
            _register(d);
            uint256 failed = oracle.checkConfig(_config());
            assertTrue(failed & LPOracleCodes.CHECK_MARKET != 0, "CHECK_MARKET");
            assertTrue(failed & UNIT_EXP_BIT != 0, "unit-exponent bit");
        }
    }

    // TEST-332 verifies: SPEC-ORC-005, REQ-ORACLE-105
    /// @notice The unit-exponent bit is not counted before the market is bound (the read reverts and the registry has
    /// not registered the feed), and is counted once it is registered while the LPVault has no such market.
    function test_TEST_332_unitExponentReadBeforeBinding() public {
        _setUpPool(_wethDai(true, 0));
        _deployOracle(3);
        assertEq(oracle.checkConfig(_config()) & UNIT_EXP_BIT, 0, "unbound: not counted");
        _register(13);
        assertTrue(oracle.checkConfig(_config()) & UNIT_EXP_BIT != 0, "registered, unbound: counted");
    }

    // ─── Cases ───

    function _wethDai(
        bool wethFirst,
        int24 spacings
    ) internal pure returns (Case memory) {
        return Case("WETH", 18, 3000e8, false, "DAI", 18, 1e8, true, 3000, wethFirst, spacings);
    }

    function _daiUsdt(
        bool daiFirst
    ) internal pure returns (Case memory) {
        return Case("DAI", 18, 1e8, true, "USDT", 6, 1e8, true, 100, daiFirst, 10);
    }

    function _memeWeth(
        bool memeFirst,
        int24 spacings
    ) internal pure returns (Case memory) {
        return Case("MEME", 18, 1000, false, "WETH", 18, 3000e8, false, 10_000, memeFirst, spacings);
    }

    function _memeUsdc(
        bool memeFirst,
        int24 spacings
    ) internal pure returns (Case memory) {
        return Case("MEME", 18, 1000, false, "USDC", 6, 1e8, true, 10_000, memeFirst, spacings);
    }

    function _btcMeme(
        bool btcFirst,
        int24 spacings
    ) internal pure returns (Case memory) {
        return Case("XBTC", 8, 90_000e8, false, "MEME", 18, 1000, false, 10_000, btcFirst, spacings);
    }

    // ─── Listing ───

    /// @dev Lists `c` with the exponent its pool's first binding takes, then checks prices end to end.
    function _listAndCheck(
        Case memory c
    ) internal returns (Listed memory l) {
        _setUpPool(c);
        (bool found, uint8 k) = ClUnitMath.firstBindingExponent(_valuation(), pool.tickSpacing());
        assertTrue(found, "pool has a unit exponent");
        l = _listWithK(k);
    }

    /// @dev Initializes the feed with `k`, binds and registers the market, requires `checkConfig == 0` and checks the
    /// prices.
    function _listWithK(
        uint8 k
    ) internal returns (Listed memory l) {
        _deployOracle(k);
        uint8 kVault;
        (kVault, l.d) = _bind(MARKET, tickLower, tickUpper, price0, price1);
        l.k = kVault;
        assertEq(kVault, k, "the LPVault's k is the feed's");
        _register(l.d);
        assertEq(oracle.checkConfig(_config()), 0, "checkConfig passes once registered");
        l.price8 = uint256(oracle.latestAnswer());
        _checkWholeToken(l);
        _checkPosition(l);
    }

    /// @dev The feed's answer is the LPVault's composition of `10^d` units valued at the listing prices, at least $1,
    /// and `d` is the smallest that reaches $1 (`SPEC-ORC-005`).
    function _checkWholeToken(
        Listed memory l
    ) internal view {
        assertEq(l.price8, _vaultValue(10 ** uint256(l.d)), "feed answer = LPVault composition of 10^d units");
        assertGe(l.price8, 1e8, "a whole token is worth at least $1");
        if (l.d > 6) assertLt(_vaultValue(10 ** uint256(l.d - 1)), 1e8, "d is the smallest worth $1");
    }

    /// @dev A real position of `n = 3 · 10^d + 12,345` units (plus a remainder of liquidity below one unit) on the
    /// market's range: burning its `n · 10^k` liquidity returns tokens worth at least Aave's value `n · price8 / 10^d`
    /// and the liquidation value `seizedValue(n)` in an 18-decimal $1 debt, and at most `SPEC-ORC-008`'s error more:
    /// `Σ_i (2 · v_i / 10^(d_i) + 1)` per whole token, for `⌊n / 10^d⌋ + 1` whole tokens, plus 2 for the floors of the
    /// value and the burn. For the $90,000 8-decimal token that is 180,000 units ($0.0018) per whole token.
    function _checkPosition(
        Listed memory l
    ) internal {
        uint256 n = 3 * 10 ** uint256(l.d) + 12_345;
        uint256 unit = 10 ** uint256(l.k);
        uint128 liquidity = uint128(n * unit + unit / 2);
        actor.mint(pool, tickLower, tickUpper, liquidity);
        (uint256 b0, uint256 b1) = actor.burn(pool, tickLower, tickUpper, uint128(n * unit));
        uint256 redeemable = b0.mulDiv(price0, 10 ** token0.decimals()) + b1.mulDiv(price1, 10 ** token1.decimals());
        uint256 aaveValue = n.mulDiv(l.price8, 10 ** uint256(l.d));
        uint256 perToken = 2 * price0 / 10 ** token0.decimals() + 2 * price1 / 10 ** token1.decimals() + 2;
        uint256 bound = (n / 10 ** uint256(l.d) + 1) * perToken + 2;
        assertLe(aaveValue, redeemable, "Aave value never above the redeemable value");
        assertLe(redeemable - aaveValue, bound, "Aave value within SPEC-ORC-008's error of the redeemable value");
        uint256 seized = SettlementMath.seizedValue(n, l.price8, l.d, 18, 1e8);
        assertLe(seized, redeemable * 1e10, "liquidation value never above the redeemable value");
        assertLe(redeemable * 1e10 - seized, bound * 1e10, "liquidation value within SPEC-ORC-008's error");
    }

    /// @dev USD value, 8 decimals, of the LPVault's composition of `units` at the listing prices (each amount already
    /// one raw unit less), as `SPEC-ORC-008` values it.
    function _vaultValue(
        uint256 units
    ) internal view returns (uint256 v) {
        (uint256[] memory a,) = vault.composition(MARKET, units, _pair(price0, price1));
        v = a[0].mulDiv(price0, 10 ** token0.decimals()) + a[1].mulDiv(price1, 10 ** token1.decimals());
        if (v == 0) v = 1;
    }

    // ─── Set-up ───

    /// @dev The pool of `c` (created two hours before `T0` at the listing prices, 151 observation slots, full-range
    /// liquidity), its feeds and configuration, the range, the LPOracle implementation and the real Uniswap v3 LPVault
    /// on the same factory, whose MarketRegistry is the registry mock.
    function _setUpPool(
        Case memory c
    ) internal {
        vm.warp(T0 - 7200);
        vm.roll(100);
        _deployFactory();
        ClTestToken a = _tokenAt(c.symA, c.decA, c.aIsToken0 ? LOW : HIGH);
        ClTestToken b = _tokenAt(c.symB, c.decB, c.aIsToken0 ? HIGH : LOW);
        (token0, token1) = c.aIsToken0 ? (a, b) : (b, a);
        (price0, price1) = c.aIsToken0 ? (c.priceA, c.priceB) : (c.priceB, c.priceA);
        (stable[0], stable[1]) = c.aIsToken0 ? (c.stableA, c.stableB) : (c.stableB, c.stableA);
        pool = _createPool(token0, token1, c.fee, price0, price1, 151, 1e18);
        (tickLower, tickUpper) = _range(c.spacings);
        vm.warp(T0 - 3600);
        _touch(pool);
        vm.warp(T0);
        vm.roll(block.number + 1);
        integration = new ClIntegrationStub();
        registry = new OracleRegistryMock();
        store = new OracleStoreMock();
        store.setRegistry(registry);
        p0Feed = _feed("p0", price0);
        a0Feed = _feed("a0", price0);
        s0Feed = _feed("s0", price0);
        p1Feed = _feed("p1", price1);
        a1Feed = _feed("a1", price1);
        s1Feed = _feed("s1", price1);
        registry.setRoutes(address(token0), _one(address(p0Feed)), _one(address(a0Feed)), RouteSlot.None);
        registry.setRoutes(address(token1), _one(address(p1Feed)), _one(address(a1Feed)), RouteSlot.None);
        store.setConfig(_config());
        implementation = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        MockNFPM nfpm = new MockNFPM(address(factory));
        vault = new UniswapV3IntegrationHarness(
            1,
            makeAddr("collateralization"),
            address(registry),
            makeAddr("lock"),
            tl,
            address(nfpm),
            address(factory),
            keccak256(vm.getCode("out-univ3/UniswapV3Pool.sol/UniswapV3Pool.json"))
        );
    }

    /// @dev The feeds at the current prices, pushed now.
    function _refreshFeeds() internal {
        p0Feed.push(int256(price0), block.timestamp);
        a0Feed.push(int256(price0), block.timestamp);
        s0Feed.push(int256(price0), block.timestamp);
        p1Feed.push(int256(price1), block.timestamp);
        a1Feed.push(int256(price1), block.timestamp);
        s1Feed.push(int256(price1), block.timestamp);
    }

    /// @dev Initializes the market's feed with the unit exponent `k` in its market argument.
    function _deployOracle(
        uint8 k
    ) internal {
        oracle = LPOracleCL(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (_oracleParams(k)))))
        );
    }

    function _oracleParams(
        uint8 k
    ) internal view returns (InitParams memory p) {
        p = _params();
        p.integration = address(vault);
        p.market = abi.encode(address(pool), tickLower, tickUpper, uint256(k));
    }

    /// @dev `bindMarket` as the MarketRegistry calls it inside `listCollateralMarket`; returns the market's `k` and `d`.
    function _bind(
        uint256 id,
        int24 lower,
        int24 upper,
        uint256 p0,
        uint256 p1
    ) internal returns (uint8 k, uint8 d) {
        vm.prank(address(registry));
        (, d) = vault.bindMarket(
            id, address(pool), bytes32(0), PositionShape(ShapeKind.TickRange, lower, upper), abi.encode(p0, p1)
        );
        k = vault.unitExponent(id);
    }

    /// @dev The MarketRegistry's record of the market: this feed, the LPVault, the pool's tokens and `d`.
    function _register(
        uint8 d
    ) internal {
        Market memory m;
        m.integration = address(vault);
        m.pool = address(pool);
        m.shape = PositionShape(ShapeKind.TickRange, tickLower, tickUpper);
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (address(token0), address(token1));
        m.decimals = d;
        m.lpOracle = address(oracle);
        registry.setMarketOf(address(oracle), MARKET, m);
    }

    function _valuation() internal view returns (ClUnitMath.Valuation memory) {
        return ClUnitMath.valuation(price0, price1, token0.decimals(), token1.decimals());
    }

    /// @dev The full range for `spacings == 0`, else `spacings` tick spacings each side of the spacing holding the
    /// pool's price.
    function _range(
        int24 spacings
    ) internal view returns (int24 lower, int24 upper) {
        if (spacings == 0) return (-_top(), _top());
        int24 s = pool.tickSpacing();
        (, int24 tick,,,,,) = pool.slot0();
        // Floor of tick / s toward −∞.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 base = (tick / s) * s;
        if (base > tick) base -= s;
        (lower, upper) = (base - spacings * s, base + (spacings + 1) * s);
    }

    /// @dev The highest usable tick of the pool's spacing.
    function _top() internal view returns (int24) {
        int24 s = pool.tickSpacing();
        // forge-lint: disable-next-line(divide-before-multiply)
        return (ClPriceMath.MAX_TICK / s) * s;
    }

    /// @dev A test token deployed at `at`, so the pool order is fixed by the case, not by the deployment nonce.
    function _tokenAt(
        string memory sym,
        uint8 dec,
        address at
    ) internal returns (ClTestToken t) {
        deployCodeTo("ClPoolFixture.sol:ClTestToken", abi.encode(sym, dec), at);
        t = ClTestToken(at);
        vm.label(at, sym);
    }

    function _pair(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        (out[0], out[1]) = (a, b);
    }
}
