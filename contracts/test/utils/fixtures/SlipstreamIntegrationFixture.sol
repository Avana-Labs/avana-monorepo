// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SlipstreamIntegration} from "../../../src/amm/slipstream/SlipstreamIntegration.sol";
import {ILPVaultErrors} from "../../../src/custody/lp-vault/ILPVaultErrors.sol";
import {ILPVaultEvents} from "../../../src/custody/lp-vault/ILPVaultEvents.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {AvanaTest} from "../AvanaTest.sol";
import {MockCLFactory, MockCLGauge, MockCLPool, MockSlipstreamNPM} from "../mocks/SlipstreamMocks.sol";
import {MintableToken} from "../mocks/UniswapV3Mocks.sol";

/// @title SlipstreamIntegrationFixture
/// @notice The production Slipstream LPVault with the real Lock and four mock generations (factory, position manager,
/// clone pools), and two bound markets of one USDC/USDT pair: market 1 on `[-50, 50]` of the generation-2 (Gauges V3)
/// pool of spacing 1, which has a gauge, and market 2 on the full range of the generation-3 (Aero) pool of spacing
/// 100. Collateralization, the MarketRegistry, the AaveAdapter, LPVaultSwap and the timelock are named addresses.
/// @dev Suites set `isolate = false`: `_asColl` takes the Lock as the AaveAdapter, makes one call as Collateralization
/// and frees the Lock, as one outer entry point would.
abstract contract SlipstreamIntegrationFixture is AvanaTest, ILPVaultErrors, ILPVaultEvents {
    uint32 internal constant INTEGRATION = 2;
    uint256 internal constant M1 = 1;
    uint256 internal constant M2 = 2;
    uint8 internal constant G1 = 2; // market 1's generation (Gauges V3)
    uint8 internal constant G2 = 3; // market 2's generation (Aero)
    int24 internal constant M1_LOWER = -50;
    int24 internal constant M1_UPPER = 50;
    int24 internal constant FULL_100 = 887_200;

    address internal adapter = makeAddr("aaveAdapter");
    address internal lpVaultSwap = makeAddr("lpVaultSwap");
    address internal coll = makeAddr("collateralization");
    address internal registry = makeAddr("marketRegistry");
    address internal timelock = makeAddr("timelock");

    Lock internal lock;
    MockCLFactory[4] internal factories;
    MockSlipstreamNPM[4] internal npms;
    MintableToken internal usdc;
    MintableToken internal usdt;
    MintableToken internal aero;
    MockCLPool internal pool1;
    MockCLPool internal pool100;
    MockCLGauge internal gauge1;
    SlipstreamIntegration internal vault;

    function setUp() public virtual {
        lock = new Lock(adapter, lpVaultSwap);
        for (uint256 g = 0; g < 4; ++g) {
            factories[g] = new MockCLFactory();
            npms[g] = new MockSlipstreamNPM(address(factories[g]));
            factories[g].setNft(address(npms[g]));
        }
        usdc = new MintableToken("USDC", 6);
        usdt = new MintableToken("USDT", 6);
        aero = new MintableToken("AERO", 18);
        pool1 = MockCLPool(factories[G1].createPool(address(usdc), address(usdt), 1));
        pool100 = MockCLPool(factories[G2].createPool(address(usdc), address(usdt), 100));
        gauge1 = new MockCLGauge(address(pool1), npms[G1], aero);
        pool1.setGauge(address(gauge1));
        vault = _deploy(_npmList(), _factoryList());
        _bind(M1, address(pool1), G1, M1_LOWER, M1_UPPER);
        _bind(M2, address(pool100), G2, -FULL_100, FULL_100);
        vm.label(address(vault), "SlipstreamLPVault");
        vm.label(address(gauge1), "CLGauge(mock)");
    }

    // ─── Helpers ───

    function _npmList() internal view returns (address[4] memory list) {
        for (uint256 g = 0; g < 4; ++g) {
            list[g] = address(npms[g]);
        }
    }

    function _factoryList() internal view returns (address[4] memory list) {
        for (uint256 g = 0; g < 4; ++g) {
            list[g] = address(factories[g]);
        }
    }

    function _deploy(
        address[4] memory n,
        address[4] memory f
    ) internal returns (SlipstreamIntegration) {
        return new SlipstreamIntegration(INTEGRATION, coll, registry, address(lock), timelock, n, f);
    }

    function _data(
        uint256 gen
    ) internal pure returns (bytes memory) {
        return abi.encode(gen, uint256(1e8), uint256(1e8));
    }

    function _bind(
        uint256 marketId,
        address pool,
        uint256 gen,
        int24 lower,
        int24 upper
    ) internal returns (address[] memory tokens, uint8 d) {
        vm.prank(registry);
        return
            vault.bindMarket(marketId, pool, bytes32(0), PositionShape(ShapeKind.TickRange, lower, upper), _data(gen));
    }

    function _key(
        uint256 gen,
        uint256 id
    ) internal pure returns (bytes32) {
        return bytes32((gen << 248) | id);
    }

    function _id(
        bytes32 key
    ) internal pure returns (uint256) {
        return uint256(key) & ((uint256(1) << 248) - 1);
    }

    /// @notice Mints an NFT of `pool`'s pair and spacing on generation `gen` to `owner` and approves the LPVault.
    function _mint(
        address owner,
        uint8 gen,
        MockCLPool pool,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) internal returns (bytes32 key) {
        uint256 id = npms[gen].mint(owner, pool.token0(), pool.token1(), pool.tickSpacing(), lower, upper, liquidity);
        vm.prank(owner);
        npms[gen].approve(address(vault), id);
        return _key(gen, id);
    }

    function _mint1(
        address owner,
        uint128 liquidity
    ) internal returns (bytes32) {
        return _mint(owner, G1, pool1, M1_LOWER, M1_UPPER, liquidity);
    }

    function _npm1() internal view returns (MockSlipstreamNPM) {
        return npms[G1];
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

    function _liquidity(
        bytes32 key
    ) internal view returns (uint128 l) {
        (,,,,,,, l,,,,) = npms[uint256(key) >> 248].positions(_id(key));
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
        return MintableToken(pool1.token0());
    }

    function _token1() internal view returns (MintableToken) {
        return MintableToken(pool1.token1());
    }
}
