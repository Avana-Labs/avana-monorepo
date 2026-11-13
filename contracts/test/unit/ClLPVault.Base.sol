// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {IClIntegration} from "../../src/amm/IClIntegration.sol";
import {SlipstreamIntegration} from "../../src/amm/slipstream/SlipstreamIntegration.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {ILPVaultEvents} from "../../src/custody/lp-vault/ILPVaultEvents.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {SlipstreamIntegrationFixture} from "../utils/fixtures/SlipstreamIntegrationFixture.sol";
import {UniswapV3IntegrationFixture} from "../utils/fixtures/UniswapV3IntegrationFixture.sol";
import {UniswapV3IntegrationHarness} from "../utils/harness/UniswapV3IntegrationHarness.sol";
import {MockCLPool} from "../utils/mocks/SlipstreamMocks.sol";
import {MintableToken, MockV3Pool} from "../utils/mocks/UniswapV3Mocks.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice The position-manager calls the shared suites make on both mock managers (`MockNFPM`, `MockSlipstreamNPM`).
interface IClTestManager is IERC721 {
    function accrue(
        uint256 tokenId,
        uint128 amount0,
        uint128 amount1
    ) external;

    function increaseLiquidity(
        uint256 tokenId,
        uint128 liquidity
    ) external;
}

/// @notice The pool setters the shared suites use on both mock pools (`MockV3Pool`, `MockCLPool`).
interface IClTestPool {
    function setPrice(
        int24 tick
    ) external;

    function setLiquidity(
        uint128 liquidity
    ) external;

    function token0() external view returns (address);

    function token1() external view returns (address);
}

/// @title ClLPVaultBase
/// @notice Shared base of the concentrated-liquidity LPVault suites that run one test body against each production
/// LPVault: the Uniswap v3 LPVault (`ClLPVaultUniswapHooks`) and the Slipstream LPVault (`ClLPVaultSlipstreamHooks`),
/// each on its own fixture with the real Lock, so a rule of 2.2 or 2.19 is checked on both deployed contracts. The hooks
/// give the suite the LPVault, its named core addresses, its position manager and pools, and a minting helper.
/// @dev Suites set `isolate = false`: one test is one transaction, so the Lock behaves as in production.
abstract contract ClLPVaultBase is AvanaTest, ILPVaultErrors, ILPVaultEvents {
    /// @dev Market 1 is `[-50, 50]` and market 2 the full range of the second pool, in both fixtures.
    uint256 internal constant MKT_A = 1;
    uint256 internal constant MKT_B = 2;
    /// @dev A third market a suite binds on its own pool (`_cBindMarketC`).
    uint256 internal constant MKT_C = 3;
    int24 internal constant MKT_A_LOWER = -50;
    int24 internal constant MKT_A_UPPER = 50;

    /// @dev The named addresses of the fixture and its real Lock.
    struct Core {
        address coll;
        address adapter;
        address lpVaultSwap;
        address registry;
        address timelock;
        Lock lock;
    }

    // ─── Hooks ───

    function _cVault() internal view virtual returns (IClIntegration);

    function _cCore() internal view virtual returns (Core memory);

    function _cManager(
        bytes32 key
    ) internal view virtual returns (IClTestManager);

    function _cTokenId(
        bytes32 key
    ) internal pure virtual returns (uint256);

    /// @notice Mints a position of `marketId`'s pool and exact range to `owner` and approves the LPVault for it.
    function _cMint(
        uint256 marketId,
        address owner,
        uint128 liquidity
    ) internal virtual returns (bytes32 key);

    function _cPool(
        uint256 marketId
    ) internal view virtual returns (IClTestPool);

    function _cLiquidity(
        bytes32 key
    ) internal view virtual returns (uint128);

    /// @notice A second LPVault of the same protocol with every binding of the fixture's except `timelock`, market 1
    /// bound.
    function _cVaultWithTimelock(
        address timelock_
    ) internal virtual returns (IClIntegration);

    /// @notice Creates a pool of `tokenA`/`tokenB` and binds it as market `MKT_C` on `[-50, 50]`.
    function _cBindMarketC(
        address tokenA,
        address tokenB
    ) internal virtual;

    // ─── Helpers ───

    /// @notice One Collateralization call into the LPVault inside a Lock session held by `holder` (a Lock member).
    function _cAs(
        address holder,
        bytes memory data
    ) internal returns (bytes memory out) {
        Core memory c = _cCore();
        vm.prank(holder);
        c.lock.acquire();
        vm.prank(c.coll);
        bool ok;
        (ok, out) = address(_cVault()).call(data);
        if (!ok) {
            assembly {
                revert(add(out, 32), mload(out))
            }
        }
        vm.prank(holder);
        c.lock.release();
    }

    /// @notice A call into the LPVault inside a Lock session held by `holder`, made by `caller`; returns whether it
    /// succeeded and its revert data.
    function _cTry(
        address holder,
        address caller,
        bytes memory data
    ) internal returns (bool ok, bytes memory out) {
        Core memory c = _cCore();
        vm.prank(holder);
        c.lock.acquire();
        vm.prank(caller);
        (ok, out) = address(_cVault()).call(data);
        vm.prank(holder);
        c.lock.release();
    }

    /// @notice Mints and pledges a position of `marketId` for `owner` (Collateralization's `receivePosition` under the
    /// AaveAdapter's Lock session); returns its key and units.
    function _cPledge(
        uint256 marketId,
        address owner,
        uint128 liquidity
    ) internal returns (bytes32 key, uint128 units) {
        key = _cMint(marketId, owner, liquidity);
        units = abi.decode(
            _cAs(_cCore().adapter, abi.encodeCall(IAmmIntegration.receivePosition, (marketId, owner, key))), (uint128)
        );
    }

    /// @notice Liquidity per vault-token unit of `marketId` (`10^k`, `SPEC-UNIT-002`), read from the LPVault.
    function _cScale(
        uint256 marketId
    ) internal returns (uint128 scale) {
        bytes32 probe = _cMint(marketId, carol, 1e18);
        uint128 units = _cVault().validatePosition(marketId, carol, probe);
        scale = uint128(1e18 / units);
        vm.prank(carol);
        _cManager(probe).transferFrom(carol, address(0xdead), _cTokenId(probe));
    }

    function _cZeros() internal pure returns (uint256[] memory z) {
        z = new uint256[](2);
    }

    function _cToken(
        uint256 marketId,
        uint256 i
    ) internal view returns (MintableToken) {
        IClTestPool p = _cPool(marketId);
        return MintableToken(i == 0 ? p.token0() : p.token1());
    }

    /// @notice Code at the MarketRegistry address that reverts on every call: no exit path may depend on it.
    function _cBreakRegistry() internal {
        vm.etch(_cCore().registry, hex"5f5ffd");
    }

    /// @notice The custody entry of `key` (views are refused while the Lock is held, so read with it free).
    function _cDepositor(
        bytes32 key
    ) internal view returns (address) {
        return _cVault().depositorOf(key);
    }
}

/// @title ClLPVaultUniswapHooks
/// @notice The hooks of `ClLPVaultBase` on the Uniswap v3 LPVault fixture.
abstract contract ClLPVaultUniswapHooks is UniswapV3IntegrationFixture, ClLPVaultBase {
    MockV3Pool internal cPoolC;

    function _cVault() internal view override returns (IClIntegration) {
        return IClIntegration(address(vault));
    }

    function _cCore() internal view override returns (Core memory) {
        return Core(coll, adapter, lpVaultSwap, registry, timelock, lock);
    }

    function _cManager(
        bytes32
    ) internal view override returns (IClTestManager) {
        return IClTestManager(address(nfpm));
    }

    function _cTokenId(
        bytes32 key
    ) internal pure override returns (uint256) {
        return uint256(key);
    }

    function _cMint(
        uint256 marketId,
        address owner,
        uint128 liquidity
    ) internal override returns (bytes32) {
        if (marketId == MKT_C) return _mint(owner, cPoolC, MKT_A_LOWER, MKT_A_UPPER, liquidity);
        return marketId == M1
            ? _mint(owner, pool500, M1_LOWER, M1_UPPER, liquidity)
            : _mint(owner, pool3000, -FULL_60, FULL_60, liquidity);
    }

    function _cPool(
        uint256 marketId
    ) internal view override returns (IClTestPool) {
        if (marketId == MKT_C) return IClTestPool(address(cPoolC));
        return IClTestPool(marketId == M1 ? address(pool500) : address(pool3000));
    }

    function _cBindMarketC(
        address tokenA,
        address tokenB
    ) internal override {
        cPoolC = MockV3Pool(v3Factory.createPool(tokenA, tokenB, 500, 10));
        _bind(MKT_C, address(cPoolC), MKT_A_LOWER, MKT_A_UPPER);
    }

    function _cLiquidity(
        bytes32 key
    ) internal view override returns (uint128 l) {
        (,,,,,,, l,,,,) = nfpm.positions(uint256(key));
    }

    function _cVaultWithTimelock(
        address timelock_
    ) internal override returns (IClIntegration v) {
        UniswapV3IntegrationHarness h = new UniswapV3IntegrationHarness(
            INTEGRATION,
            coll,
            registry,
            address(lock),
            timelock_,
            address(nfpm),
            address(v3Factory),
            v3Factory.poolInitCodeHash()
        );
        vm.prank(registry);
        h.bindMarket(
            M1,
            address(pool500),
            bytes32(0),
            PositionShape(ShapeKind.TickRange, M1_LOWER, M1_UPPER),
            abi.encode(1e8, 1e8)
        );
        v = IClIntegration(address(h));
    }
}

/// @title ClLPVaultSlipstreamHooks
/// @notice The hooks of `ClLPVaultBase` on the Slipstream LPVault fixture.
abstract contract ClLPVaultSlipstreamHooks is SlipstreamIntegrationFixture, ClLPVaultBase {
    MockCLPool internal cPoolC;

    function _cVault() internal view override returns (IClIntegration) {
        return IClIntegration(address(vault));
    }

    function _cCore() internal view override returns (Core memory) {
        return Core(coll, adapter, lpVaultSwap, registry, timelock, lock);
    }

    function _cManager(
        bytes32 key
    ) internal view override returns (IClTestManager) {
        return IClTestManager(address(npms[uint256(key) >> 248]));
    }

    function _cTokenId(
        bytes32 key
    ) internal pure override returns (uint256) {
        return _id(key);
    }

    function _cMint(
        uint256 marketId,
        address owner,
        uint128 liquidity
    ) internal override returns (bytes32) {
        if (marketId == MKT_C) return _mint(owner, G1, cPoolC, MKT_A_LOWER, MKT_A_UPPER, liquidity);
        return marketId == M1
            ? _mint(owner, G1, pool1, M1_LOWER, M1_UPPER, liquidity)
            : _mint(owner, G2, pool100, -FULL_100, FULL_100, liquidity);
    }

    function _cPool(
        uint256 marketId
    ) internal view override returns (IClTestPool) {
        if (marketId == MKT_C) return IClTestPool(address(cPoolC));
        return IClTestPool(marketId == M1 ? address(pool1) : address(pool100));
    }

    function _cBindMarketC(
        address tokenA,
        address tokenB
    ) internal override {
        cPoolC = MockCLPool(factories[G1].createPool(tokenA, tokenB, 1));
        _bind(MKT_C, address(cPoolC), G1, MKT_A_LOWER, MKT_A_UPPER);
    }

    function _cLiquidity(
        bytes32 key
    ) internal view override returns (uint128) {
        return _liquidity(key);
    }

    function _cVaultWithTimelock(
        address timelock_
    ) internal override returns (IClIntegration v) {
        SlipstreamIntegration s = new SlipstreamIntegration(
            INTEGRATION, coll, registry, address(lock), timelock_, _npmList(), _factoryList()
        );
        vm.prank(registry);
        s.bindMarket(M1, address(pool1), bytes32(0), PositionShape(ShapeKind.TickRange, M1_LOWER, M1_UPPER), _data(G1));
        v = IClIntegration(address(s));
    }
}
