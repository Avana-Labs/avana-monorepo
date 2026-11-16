// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV4Integration} from "../../../src/amm/uniswap-v4/IUniswapV4Integration.sol";
import {ILPVaultErrors} from "../../../src/custody/lp-vault/ILPVaultErrors.sol";
import {ILPVaultEvents} from "../../../src/custody/lp-vault/ILPVaultEvents.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {ClTestToken, IClPool} from "./ClPoolFixture.sol";
import {UniswapV4WorldFixture} from "./UniswapV4WorldFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title UniswapV4IntegrationFixture
/// @notice The Uniswap v4 LPVault on the local v4 world with the real Lock and named Avana callers, two markets:
/// `M1` on a USDC/USDT pool (fee 100, spacing 1, range [-50, 50]) and `M2` on a native ETH/USDC pool (fee 500,
/// spacing 10, a range around $2,000), each with its Uniswap v3 reference pool.
/// @dev The LPVault is deployed from its artifact (`deployCode`), so the test suites compile against its interface.
abstract contract UniswapV4IntegrationFixture is UniswapV4WorldFixture, ILPVaultErrors, ILPVaultEvents {
    uint32 internal constant INTEGRATION = 3;
    uint256 internal constant M1 = 1;
    uint256 internal constant M2 = 2;
    int24 internal constant M1_LOWER = -50;
    int24 internal constant M1_UPPER = 50;
    int24 internal constant M2_LOWER = -207_000;
    int24 internal constant M2_UPPER = -194_000;
    uint256 internal constant ETH_PRICE = 2000e8;
    uint256 internal constant ONE = 1e8;
    uint16 internal constant CARDINALITY = 200;

    address internal adapter = makeAddr("aaveAdapter");
    address internal lpVaultSwap = makeAddr("lpVaultSwap");
    address internal coll = makeAddr("collateralization");
    address internal registry = makeAddr("marketRegistry");
    address internal timelock = makeAddr("timelock");

    Lock internal lock;
    IUniswapV4Integration internal vault;
    ClTestToken internal usdc;
    ClTestToken internal usdt;
    PoolKey internal stableKey;
    PoolKey internal ethKey;
    IClPool internal stableRef;
    IClPool internal ethRef;

    function setUp() public virtual {
        _deployV4World();
        lock = new Lock(adapter, lpVaultSwap);
        usdc = new ClTestToken("USDC", 6);
        usdt = new ClTestToken("USDT", 6);
        (address a, address b) =
            address(usdc) < address(usdt) ? (address(usdc), address(usdt)) : (address(usdt), address(usdc));
        stableKey = _key(a, b, 100, 1);
        _initPool(stableKey, ONE, ONE, 6, 6);
        ethKey = _key(address(0), address(usdc), 500, 10);
        _initPool(ethKey, ETH_PRICE, ONE, 18, 6);
        stableRef = _referencePool(address(usdc), address(usdt), ONE, ONE, CARDINALITY, 1e18);
        ethRef = _referencePool(address(weth), address(usdc), ETH_PRICE, ONE, CARDINALITY, 1e18);
        _observe(stableRef, 3);
        _observe(ethRef, 3);
        vault = IUniswapV4Integration(
            deployCode(
                "UniswapV4Integration.sol:UniswapV4Integration",
                abi.encode(
                    INTEGRATION, coll, registry, address(lock), timelock, address(posm), address(factory), uint256(12)
                )
            )
        );
        vm.label(address(vault), "UniswapV4LPVault");
        _bindV4(M1, stableKey, address(stableRef), M1_LOWER, M1_UPPER, ONE, ONE);
        _bindV4(M2, ethKey, address(ethRef), M2_LOWER, M2_UPPER, ETH_PRICE, ONE);
    }

    // ─── Helpers ───

    function _bindData(
        PoolKey memory key,
        address ref,
        uint256 p0,
        uint256 p1
    ) internal pure returns (bytes memory) {
        return abi.encode(key, ref, p0, p1);
    }

    function _bindV4(
        uint256 marketId,
        PoolKey memory key,
        address ref,
        int24 lower,
        int24 upper,
        uint256 p0,
        uint256 p1
    ) internal returns (address[] memory tokens, uint8 d) {
        vm.prank(registry);
        return vault.bindMarket(
            marketId,
            address(0),
            _poolId(key),
            PositionShape(ShapeKind.TickRange, lower, upper),
            _bindData(key, ref, p0, p1)
        );
    }

    /// @dev Mints a position to `owner` and approves the LPVault for it.
    function _mintFor(
        address owner,
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) internal returns (bytes32 positionKey) {
        uint256 id = _mintV4(owner, key, lower, upper, liquidity);
        vm.prank(owner);
        posm.approve(address(vault), id);
        positionKey = bytes32(id);
    }

    function _lock() internal {
        vm.prank(adapter);
        lock.acquire();
    }

    function _unlock() internal {
        vm.prank(adapter);
        lock.release();
    }

    function _asColl(
        bytes memory data
    ) internal returns (bytes memory) {
        _lock();
        vm.prank(coll);
        (bool ok, bytes memory out) = address(vault).call(data);
        if (!ok) {
            assembly {
                revert(add(out, 32), mload(out))
            }
        }
        _unlock();
        return out;
    }

    function _receive(
        uint256 marketId,
        address owner,
        bytes32 key
    ) internal returns (uint128 units) {
        return abi.decode(_asColl(abi.encodeCall(vault.receivePosition, (marketId, owner, key))), (uint128));
    }

    function _unwind(
        bytes32 key,
        uint128 units,
        uint256[] memory mins,
        address recipient
    ) internal returns (uint256[] memory) {
        return abi.decode(_asColl(abi.encodeCall(vault.unwind, (key, units, mins, recipient))), (uint256[]));
    }

    function _collect(
        bytes32 key,
        address depositor
    ) internal returns (uint256[] memory) {
        return abi.decode(_asColl(abi.encodeCall(vault.collectFees, (key, depositor))), (uint256[]));
    }

    function _zeros() internal pure returns (uint256[] memory z) {
        z = new uint256[](2);
    }

    function _vec(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory v) {
        v = new uint256[](2);
        (v[0], v[1]) = (a, b);
    }

    /// @dev Balances of the market's two Avana tokens (WETH for the ETH leg).
    function _balances(
        uint256 marketId,
        address who
    ) internal view returns (uint256 b0, uint256 b1) {
        (,,, address[] memory tokens) = vault.marketOf(marketId);
        b0 = ClTestToken(tokens[0]).balanceOf(who);
        b1 = ClTestToken(tokens[1]).balanceOf(who);
    }
}
