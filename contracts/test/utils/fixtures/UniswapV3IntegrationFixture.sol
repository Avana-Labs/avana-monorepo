// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultErrors} from "../../../src/custody/lp-vault/ILPVaultErrors.sol";
import {ILPVaultEvents} from "../../../src/custody/lp-vault/ILPVaultEvents.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {AvanaTest} from "../AvanaTest.sol";
import {UniswapV3IntegrationHarness} from "../harness/UniswapV3IntegrationHarness.sol";
import {MintableToken, MockNFPM, MockV3Factory, MockV3Pool} from "../mocks/UniswapV3Mocks.sol";

/// @title UniswapV3IntegrationFixture
/// @notice The Uniswap v3 LPVault (mock-factory harness) with the real Lock, a mock NFPM, factory and pools, and two
/// bound markets of one USDC/USDT pair: market 1 on `[-50, 50]` of the 0.05% pool (spacing 10, 9 vault decimals) and
/// market 2 on the full range of the 0.3% pool (spacing 60, 6 vault decimals). Collateralization, the MarketRegistry,
/// the AaveAdapter, LPVaultSwap and the timelock are named addresses.
/// @dev Suites set `isolate = false`: `_asColl` takes the Lock as the AaveAdapter, makes one call as Collateralization
/// and frees the Lock, as one outer entry point would.
abstract contract UniswapV3IntegrationFixture is AvanaTest, ILPVaultErrors, ILPVaultEvents {
    uint32 internal constant INTEGRATION = 1;
    uint256 internal constant M1 = 1;
    uint256 internal constant M2 = 2;
    int24 internal constant M1_LOWER = -50;
    int24 internal constant M1_UPPER = 50;
    int24 internal constant FULL_60 = 887_220;

    address internal adapter = makeAddr("aaveAdapter");
    address internal lpVaultSwap = makeAddr("lpVaultSwap");
    address internal coll = makeAddr("collateralization");
    address internal registry = makeAddr("marketRegistry");
    address internal timelock = makeAddr("timelock");

    Lock internal lock;
    MockV3Factory internal v3Factory;
    MockNFPM internal nfpm;
    MintableToken internal usdc;
    MintableToken internal usdt;
    MockV3Pool internal pool500;
    MockV3Pool internal pool3000;
    UniswapV3IntegrationHarness internal vault;

    function setUp() public virtual {
        lock = new Lock(adapter, lpVaultSwap);
        v3Factory = new MockV3Factory();
        nfpm = new MockNFPM(address(v3Factory));
        usdc = new MintableToken("USDC", 6);
        usdt = new MintableToken("USDT", 6);
        pool500 = MockV3Pool(v3Factory.createPool(address(usdc), address(usdt), 500, 10));
        pool3000 = MockV3Pool(v3Factory.createPool(address(usdc), address(usdt), 3000, 60));
        vault = new UniswapV3IntegrationHarness(
            INTEGRATION,
            coll,
            registry,
            address(lock),
            timelock,
            address(nfpm),
            address(v3Factory),
            v3Factory.poolInitCodeHash()
        );
        _bind(M1, address(pool500), M1_LOWER, M1_UPPER);
        _bind(M2, address(pool3000), -FULL_60, FULL_60);
        vm.label(address(vault), "UniswapV3LPVault");
        vm.label(address(nfpm), "NFPM(mock)");
        vm.label(address(v3Factory), "V3Factory(mock)");
    }

    // ─── Helpers ───

    function _bind(
        uint256 marketId,
        address pool,
        int24 lower,
        int24 upper
    ) internal returns (address[] memory tokens, uint8 d) {
        vm.prank(registry);
        return vault.bindMarket(
            marketId, pool, bytes32(0), PositionShape(ShapeKind.TickRange, lower, upper), abi.encode(1e8, 1e8)
        );
    }

    /// @notice Mints an NFT of `pool`'s pair and fee to `owner` and approves the LPVault for it.
    function _mint(
        address owner,
        MockV3Pool pool,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) internal returns (bytes32 key) {
        uint256 id = nfpm.mint(owner, pool.token0(), pool.token1(), pool.fee(), lower, upper, liquidity);
        vm.prank(owner);
        nfpm.approve(address(vault), id);
        return bytes32(id);
    }

    function _mint1(
        address owner,
        uint128 liquidity
    ) internal returns (bytes32) {
        return _mint(owner, pool500, M1_LOWER, M1_UPPER, liquidity);
    }

    function _lock() internal {
        vm.prank(adapter);
        lock.acquire();
    }

    function _unlock() internal {
        vm.prank(adapter);
        lock.release();
    }

    /// @notice One Collateralization call inside a Lock session held by the AaveAdapter.
    function _asColl(
        bytes memory data
    ) internal returns (bytes memory ret) {
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

    function _pledge1(
        address owner,
        uint128 liquidity
    ) internal returns (bytes32 key) {
        key = _mint1(owner, liquidity);
        _receive(M1, owner, key);
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

    function _token0() internal view returns (MintableToken) {
        return MintableToken(pool500.token0());
    }

    function _token1() internal view returns (MintableToken) {
        return MintableToken(pool500.token1());
    }
}
