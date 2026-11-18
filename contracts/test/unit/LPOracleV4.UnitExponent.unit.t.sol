// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV4Integration} from "../../src/amm/uniswap-v4/IUniswapV4Integration.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleBase} from "../../src/oracle/lp-oracle/ILPOracleBase.sol";
import {InitParams, LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {LPOracleV4} from "../../src/oracle/lp-oracle/LPOracleV4.sol";
import {Market} from "../../src/types/MarketTypes.sol";
import {PositionShape, ShapeKind} from "../../src/types/PositionTypes.sol";
import {LPOracleV4Fixture} from "../utils/fixtures/LPOracleV4Fixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The vault-token unit of `SPEC-ORC-005` end to end on a Uniswap v4 market: the real Uniswap v4 LPVault binds
/// the native ETH/USDC market (unit exponent `k` and decimals `d`), the real `LPOracleV4` is initialized with that `k`
/// in its market argument, and once the MarketRegistry holds the market with the LPVault's `d`, `checkConfig` returns 0.
/// The feed's price of one whole token then equals the LPVault's composition of `10^d` units at the listing prices,
/// and `d` is the smallest that reaches $1. A feed initialized with another `k` is refused at `initialize`, and before
/// the binding the unit-exponent check counts only once the market is registered.
/// forge-config: default.isolate = false
contract LPOracleV4UnitExponentUnitTest is LPOracleV4Fixture {
    using Math for uint256;

    /// @dev The module's unit-exponent bit (`REQ-ORACLE-105` bit 7), shifted into the `checkConfig` bitmap.
    uint256 internal constant UNIT_EXP_BIT = (1 << 7) << LPOracleCodes.MODULE_CHECKS_SHIFT;

    IUniswapV4Integration internal vault;
    LPOracleV4 internal feed;

    function setUp() public {
        _deployV4Market();
        Lock lock = new Lock(makeAddr("aaveAdapter"), makeAddr("lpVaultSwap"));
        vault = IUniswapV4Integration(
            deployCode(
                "UniswapV4Integration.sol:UniswapV4Integration",
                abi.encode(
                    uint32(3),
                    makeAddr("collateralization"),
                    address(registry),
                    address(lock),
                    tl,
                    address(posm),
                    address(factory),
                    uint256(BLOCK_TIME)
                )
            )
        );
    }

    /// @dev `bindMarket` as the MarketRegistry calls it at listing; returns the market's `k` and `d`.
    function _bind() internal returns (uint8 k, uint8 d) {
        vm.prank(address(registry));
        (, d) = vault.bindMarket(
            MARKET,
            address(0),
            keccak256(abi.encode(key)),
            PositionShape(ShapeKind.TickRange, LOWER, UPPER),
            abi.encode(key, address(ref), ETH, USD)
        );
        k = vault.unitExponent(MARKET);
    }

    function _feedParams(
        uint8 k
    ) internal view returns (InitParams memory p) {
        p = _params();
        p.integration = address(vault);
        p.market = abi.encode(address(pm), _v4Key(), LOWER, UPPER, uint256(k), address(ref));
    }

    function _deployFeed(
        uint8 k
    ) internal {
        feed = LPOracleV4(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (_feedParams(k)))))
        );
    }

    /// @dev The MarketRegistry's record of the market: this feed, the LPVault, the v4 pool's id, the range, the tokens
    /// and `d`.
    function _register(
        uint8 d
    ) internal {
        Market memory m;
        m.integration = address(vault);
        m.poolId = keccak256(abi.encode(key));
        m.shape = PositionShape(ShapeKind.TickRange, LOWER, UPPER);
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (address(weth), address(usdc));
        m.decimals = d;
        m.lpOracle = address(feed);
        registry.setMarketOf(address(feed), MARKET, m);
    }

    /// @dev USD value, 8 decimals, of the LPVault's composition of `units` at the listing prices.
    function _vaultValue(
        uint256 units
    ) internal view returns (uint256 v) {
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (ETH, USD);
        (uint256[] memory a,) = vault.composition(MARKET, units, prices);
        v = a[0].mulDiv(ETH, 1e18) + a[1].mulDiv(USD, 1e6);
        if (v == 0) v = 1;
    }

    // TEST-332 verifies: SPEC-ORC-005, SPEC-ORC-006, REQ-ORACLE-105, REQ-ORACLE-047, REQ-AMM-V4-007
    /// @notice The feed initialized with the LPVault's `k` passes `checkConfig` once the market is registered with the
    /// LPVault's `d`; its answer is the LPVault's composition of `10^d` units valued at the listing prices, at least $1,
    /// and `d` is the smallest that reaches $1.
    function test_TEST_332_v4MarketListsAtTheLPVaultsUnitExponent() public {
        (uint8 k, uint8 d) = _bind();
        _deployFeed(k);
        _register(d);
        assertEq(feed.checkConfig(_config()), 0, "checkConfig passes once registered");
        uint256 price8 = uint256(feed.latestAnswer());
        assertEq(price8, _vaultValue(10 ** uint256(d)), "feed answer = LPVault composition of 10^d units");
        assertGe(price8, 1e8, "a whole token is worth at least $1");
        if (d > 6) assertLt(_vaultValue(10 ** uint256(d - 1)), 1e8, "d is the smallest worth $1");
    }

    // TEST-332 verifies: SPEC-ORC-005, REQ-ORACLE-105
    /// @notice Once the LPVault has bound the market, a feed initialized with another `k` than the pool's is refused at
    /// `initialize` with the unit-exponent bit alone, on either side of the pool's `k`.
    function test_TEST_332_v4FeedWithAnotherExponentIsRefused() public {
        (uint8 k,) = _bind();
        uint8[2] memory wrong = [k + 1, k == 0 ? k + 2 : k - 1];
        for (uint256 i = 0; i < 2; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ILPOracleBase.ConfigCheckFailed.selector, UNIT_EXP_BIT));
            new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (_feedParams(wrong[i]))));
        }
        _deployFeed(k);
    }

    // TEST-332 verifies: SPEC-ORC-005, REQ-ORACLE-105
    /// @notice The unit-exponent bit is not counted before the LPVault binds the market (the read reverts and the
    /// registry has not registered the feed), and is counted once it is registered while the LPVault has no such market.
    function test_TEST_332_v4UnitExponentReadBeforeBinding() public {
        _deployFeed(0);
        assertEq(feed.checkConfig(_config()) & UNIT_EXP_BIT, 0, "unbound: not counted");
        _register(9);
        assertTrue(feed.checkConfig(_config()) & UNIT_EXP_BIT != 0, "registered, unbound: counted");
    }
}
