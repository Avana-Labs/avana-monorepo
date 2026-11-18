// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {INonfungiblePositionManager} from "../../interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {IUniswapV3Factory} from "../../interfaces/external/uniswap/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../../interfaces/external/uniswap/IUniswapV3Pool.sol";
import {ClLPVaultBase} from "../concentrated-liquidity/ClLPVaultBase.sol";
import {ClNfpmLPVault} from "../concentrated-liquidity/ClNfpmLPVault.sol";
import {ClMarketConfig} from "../types/AmmTypes.sol";
import {IUniswapV3Integration} from "./IUniswapV3Integration.sol";

/// @title UniswapV3Integration
/// @notice Uniswap v3 LPVault: custodian of canonical NonfungiblePositionManager positions in exact-range markets.
contract UniswapV3Integration is ClNfpmLPVault, IUniswapV3Integration {
    bytes32 public constant UNISWAP_V3 = keccak256("UNISWAP_V3");
    /// @notice Init code hash of the canonical Uniswap v3 pool, from which `FACTORY` derives every pool address.
    bytes32 public constant POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    /// @notice Largest block interval accepted, seconds.
    uint256 public constant MAX_BLOCK_TIME = 12;
    address private immutable _NFPM;
    address private immutable _FACTORY;
    uint256 private immutable _BLOCK_TIME;

    /// @notice Fixes the Avana bindings and the canonical NFPM and factory.
    /// @dev Reverts `InvalidDeployment` for a bad NFPM/factory pair or a block time that does not match a known chain.
    /// @param blockTime The chain's minimum block interval, seconds.
    constructor(
        uint32 integrationId,
        address collateralization,
        address marketRegistry,
        address lock,
        address timelock,
        address nfpm,
        address factory,
        uint256 blockTime
    ) ClLPVaultBase(integrationId, collateralization, marketRegistry, lock, timelock) {
        uint256 known = _knownBlockTime(block.chainid);
        if (blockTime == 0 || blockTime > MAX_BLOCK_TIME || (known != 0 && blockTime != known)) {
            revert InvalidDeployment();
        }
        if (nfpm == address(0) || factory == address(0) || nfpm == factory) revert InvalidDeployment();
        if (
            nfpm == collateralization || nfpm == marketRegistry || nfpm == lock || nfpm == timelock
                || factory == collateralization || factory == marketRegistry || factory == lock || factory == timelock
        ) revert InvalidDeployment();
        if (nfpm.code.length == 0 || INonfungiblePositionManager(nfpm).factory() != factory) {
            revert InvalidDeployment();
        }
        _NFPM = nfpm;
        _FACTORY = factory;
        _BLOCK_TIME = blockTime;
    }

    /// @inheritdoc IUniswapV3Integration
    function BLOCK_TIME() external view override returns (uint256) {
        return _BLOCK_TIME;
    }

    /// @inheritdoc IUniswapV3Integration
    function NFPM() external view override returns (address) {
        return _NFPM;
    }

    /// @inheritdoc IUniswapV3Integration
    function FACTORY() external view override returns (address) {
        return _FACTORY;
    }

    /// @inheritdoc ILPVault
    function AMM_PROTOCOL() external pure override returns (bytes32) {
        return UNISWAP_V3;
    }

    function _positionManager(
        bytes32
    ) internal view override returns (address) {
        return _NFPM;
    }

    function _tokenId(
        bytes32 positionKey
    ) internal pure override returns (uint256) {
        return uint256(positionKey);
    }

    function _positionKeyOf(
        address manager,
        uint256 tokenId
    ) internal view override returns (bytes32, bool) {
        return (bytes32(tokenId), manager == _NFPM);
    }

    /// @dev The pool is derived from the position's own fields, never caller-supplied.
    function _readPoolPosition(
        bytes32 positionKey
    ) internal view override returns (address pool, int24 tickLower, int24 tickUpper, uint128 liquidity) {
        address token0;
        address token1;
        uint24 fee;
        // Only the pair, fee, ticks and liquidity are used.
        // forge-lint: disable-start(unused-return)
        (,, token0, token1, fee, tickLower, tickUpper, liquidity,,,,) =
            INonfungiblePositionManager(_NFPM).positions(uint256(positionKey));
        // forge-lint: disable-end(unused-return)
        pool = IUniswapV3Factory(_FACTORY).getPool(token0, token1, fee);
    }

    /// @dev The 7-field Uniswap v3 `slot0` layout.
    function _slot0(
        address pool
    ) internal view override returns (int24 tick, uint16 observationCardinality, bool unlocked) {
        // Only the tick, the cardinality and the lock flag are used.
        // forge-lint: disable-next-line(unused-return)
        (, tick,, observationCardinality,,, unlocked) = IUniswapV3Pool(pool).slot0();
    }

    /// @dev Checks the pool against the factory, its CREATE2 address and the standard fee tiers.
    function _validatePool(
        address pool,
        bytes calldata integrationData
    ) internal view override returns (ClMarketConfig memory cfg, uint256 price0, uint256 price1) {
        if (integrationData.length != 64) revert InvalidPool();
        (price0, price1) = abi.decode(integrationData, (uint256, uint256));
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        cfg.pool = pool;
        cfg.positionManager = _NFPM;
        cfg.factory = _FACTORY;
        cfg.token0 = p.token0();
        cfg.token1 = p.token1();
        cfg.fee = p.fee();
        cfg.tickSpacing = p.tickSpacing();
        if (
            p.factory() != _FACTORY || cfg.token0 >= cfg.token1
                || IUniswapV3Factory(_FACTORY).getPool(cfg.token0, cfg.token1, cfg.fee) != pool
                || _poolAddress(cfg.token0, cfg.token1, cfg.fee) != pool || cfg.tickSpacing != _standardSpacing(cfg.fee)
        ) revert InvalidPool();
    }

    /// @dev A staked v3 NFT is owned by its staking contract and already fails the owner check.
    function _isEncumbered(
        Market storage,
        bytes32
    ) internal pure override returns (bool) {
        return false;
    }

    function _blockTime() internal view override returns (uint256) {
        return _BLOCK_TIME;
    }

    /// @dev The block interval of a known chain; 0 for any other, where the constructor's value stands.
    function _knownBlockTime(
        uint256 chainId
    ) private pure returns (uint256) {
        if (chainId == 1 || chainId == 11_155_111) return 12;
        if (chainId == 8453 || chainId == 84_532 || chainId == 10) return 2;
        return 0;
    }

    function _poolAddress(
        address token0,
        address token1,
        uint24 fee
    ) internal view virtual returns (address) {
        bytes32 h = keccak256(
            abi.encodePacked(hex"ff", _FACTORY, keccak256(abi.encode(token0, token1, fee)), _poolInitCodeHash())
        );
        return address(uint160(uint256(h)));
    }

    /// @dev The canonical pool init code hash; a test harness on a mock factory overrides it.
    function _poolInitCodeHash() internal view virtual returns (bytes32) {
        return POOL_INIT_CODE_HASH;
    }

    /// @dev Tick spacing of the standard fee tiers; 0 for any other.
    function _standardSpacing(
        uint24 fee
    ) private pure returns (int24) {
        if (fee == 100) return 1;
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10_000) return 200;
        return 0;
    }
}

