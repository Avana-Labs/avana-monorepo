// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {ICLFactory} from "../../interfaces/external/aerodrome/ICLFactory.sol";
import {ICLPool} from "../../interfaces/external/aerodrome/ICLPool.sol";
import {INonfungiblePositionManager} from "../../interfaces/external/aerodrome/INonfungiblePositionManager.sol";
import {ClLPVaultBase} from "../concentrated-liquidity/ClLPVaultBase.sol";
import {ClNfpmLPVault} from "../concentrated-liquidity/ClNfpmLPVault.sol";
import {IClPositionManager} from "../concentrated-liquidity/IClPositionManager.sol";
import {ClMarketConfig} from "../types/AmmTypes.sol";
import {ISlipstreamIntegration} from "./ISlipstreamIntegration.sol";

/// @title SlipstreamIntegration
/// @notice Aerodrome Slipstream LPVault: custodian of unstaked positions of four position-manager generations.
/// @dev Never calls a gauge mutator, the voter, `approve` or `setApprovalForAll`.
contract SlipstreamIntegration is ClNfpmLPVault, ISlipstreamIntegration {
    bytes32 internal constant AERODROME_SLIPSTREAM = keccak256("AERODROME_SLIPSTREAM");
    uint8 internal constant GENERATION_COUNT = 4;
    /// @dev Base's block interval, seconds.
    uint256 private constant BLOCK_TIME = 2;
    uint256 private immutable _BLOCK_TIME;
    uint256 private constant GENERATION_SHIFT = 248;
    /// @dev Largest tick spacing whose `maxLiquidityPerTick` fits `uint120`.
    int24 private constant MAX_TICK_SPACING = 6931;
    /// @dev Bytes of `integrationData`: `abi.encode(uint256 generation, uint256 price0, uint256 price1)`.
    uint256 private constant INTEGRATION_DATA_LENGTH = 96;

    address private immutable _NPM_0;
    address private immutable _FACTORY_0;
    address private immutable _NPM_1;
    address private immutable _FACTORY_1;
    address private immutable _NPM_2;
    address private immutable _FACTORY_2;
    address private immutable _NPM_3;
    address private immutable _FACTORY_3;

    /// @notice Fixes the integration identifier, the Avana bindings and the four (position manager, factory) pairs.
    /// @dev Reverts `InvalidDeployment` unless the AMM addresses are distinct contracts and each NPM names its factory.
    /// @param factories Pool factories of generations 0 to 3, paired by index.
    constructor(
        uint32 integrationId,
        address collateralization,
        address marketRegistry,
        address lock,
        address timelock,
        address[GENERATION_COUNT] memory npms,
        address[GENERATION_COUNT] memory factories
    ) ClLPVaultBase(integrationId, collateralization, marketRegistry, lock, timelock) {
        address[12] memory all = [
            npms[0],
            npms[1],
            npms[2],
            npms[3],
            factories[0],
            factories[1],
            factories[2],
            factories[3],
            collateralization,
            marketRegistry,
            lock,
            timelock
        ];
        bool bad = false;
        // The eight AMM addresses against each other and the bindings; the bindings were checked by the base.
        for (uint256 i = 0; i < 8; ++i) {
            if (all[i] == address(0) || all[i].code.length == 0) bad = true;
            for (uint256 j = i + 1; j < 12; ++j) {
                if (all[i] == all[j]) bad = true;
            }
        }
        if (
            bad || !_namesFactory(npms[0], factories[0]) || !_namesFactory(npms[1], factories[1])
                || !_namesFactory(npms[2], factories[2]) || !_namesFactory(npms[3], factories[3])
        ) revert InvalidDeployment();
        (_NPM_0, _NPM_1, _NPM_2, _NPM_3) = (npms[0], npms[1], npms[2], npms[3]);
        (_FACTORY_0, _FACTORY_1, _FACTORY_2, _FACTORY_3) = (factories[0], factories[1], factories[2], factories[3]);
        _BLOCK_TIME = BLOCK_TIME;
    }

    /// @inheritdoc ILPVault
    function AMM_PROTOCOL() external pure override returns (bytes32) {
        return AERODROME_SLIPSTREAM;
    }

    /// @inheritdoc ISlipstreamIntegration
    function generationCount() external pure override returns (uint8) {
        return GENERATION_COUNT;
    }

    /// @inheritdoc ISlipstreamIntegration
    function generation(
        uint8 index
    ) external view override returns (address npm, address factory) {
        if (index >= GENERATION_COUNT) revert InvalidPool();
        return _generation(index);
    }

    /// @inheritdoc ISlipstreamIntegration
    function positionKeyOf(
        uint8 index,
        uint256 tokenId
    ) external pure override returns (bytes32) {
        if (index >= GENERATION_COUNT || tokenId >> GENERATION_SHIFT != 0) revert UnsupportedNft();
        return _key(index, tokenId);
    }

    /// @inheritdoc ISlipstreamIntegration
    function isStaked(
        uint256 marketId,
        uint256 tokenId
    ) external view override returns (bool) {
        ClMarketConfig storage cfg = _market(marketId).cfg;
        address gauge = _gaugeOf(cfg.pool);
        if (gauge == address(0)) return false;
        try IClPositionManager(cfg.positionManager).ownerOf(tokenId) returns (address o) {
            return o == gauge;
        } catch {
            return false;
        }
    }

    /// @dev The position manager of the key's generation; `UnsupportedNft` for an unknown generation.
    function _positionManager(
        bytes32 positionKey
    ) internal view override returns (address npm) {
        (npm,) = _generation(uint256(positionKey) >> GENERATION_SHIFT);
    }

    function _tokenId(
        bytes32 positionKey
    ) internal pure override returns (uint256) {
        return uint256(positionKey) & ((uint256(1) << GENERATION_SHIFT) - 1);
    }

    /// @dev Known only for an allowlisted manager and a token ID below 2^248.
    function _positionKeyOf(
        address manager,
        uint256 tokenId
    ) internal view override returns (bytes32, bool) {
        if (tokenId >> GENERATION_SHIFT != 0) return (bytes32(0), false);
        uint256 found = GENERATION_COUNT;
        for (uint256 g = 0; g < GENERATION_COUNT; ++g) {
            (address npm,) = _generation(g);
            if (npm == manager) found = g;
        }
        if (found == GENERATION_COUNT) return (bytes32(0), false);
        return (_key(found, tokenId), true);
    }

    /// @dev The pool is derived from the position's own fields on the generation factory, never caller-supplied.
    function _readPoolPosition(
        bytes32 positionKey
    ) internal view override returns (address pool, int24 tickLower, int24 tickUpper, uint128 liquidity) {
        (address npm, address factory) = _generation(uint256(positionKey) >> GENERATION_SHIFT);
        address token0;
        address token1;
        int24 tickSpacing;
        // Only the pair, spacing, ticks and liquidity are used.
        // forge-lint: disable-start(unused-return)
        (,, token0, token1, tickSpacing, tickLower, tickUpper, liquidity,,,,) =
            INonfungiblePositionManager(npm).positions(_tokenId(positionKey));
        // forge-lint: disable-end(unused-return)
        pool = ICLFactory(factory).getPool(token0, token1, tickSpacing);
    }

    /// @dev The 6-field Slipstream `slot0` layout.
    function _slot0(
        address pool
    ) internal view override returns (int24 tick, uint16 observationCardinality, bool unlocked) {
        // Only the tick, the cardinality and the lock flag are used.
        // forge-lint: disable-next-line(unused-return)
        (, tick,, observationCardinality,, unlocked) = ICLPool(pool).slot0();
    }

    /// @dev The pool's code hash is checked as the factory's clone before any call to the pool.
    function _validatePool(
        address pool,
        bytes calldata integrationData
    ) internal view override returns (ClMarketConfig memory cfg, uint256 price0, uint256 price1) {
        if (integrationData.length != INTEGRATION_DATA_LENGTH) revert InvalidPool();
        uint256 index;
        (index, price0, price1) = abi.decode(integrationData, (uint256, uint256, uint256));
        if (index >= GENERATION_COUNT) revert InvalidPool();
        (cfg.positionManager, cfg.factory) = _generation(index);
        ICLFactory factory = ICLFactory(cfg.factory);
        if (pool.codehash != _cloneCodeHash(factory.poolImplementation())) revert InvalidPool();
        ICLPool p = ICLPool(pool);
        cfg.pool = pool;
        cfg.token0 = p.token0();
        cfg.token1 = p.token1();
        cfg.tickSpacing = p.tickSpacing();
        if (
            p.factory() != cfg.factory || p.nft() != cfg.positionManager || cfg.token0 >= cfg.token1
                || cfg.tickSpacing <= 0 || cfg.tickSpacing > MAX_TICK_SPACING
                || factory.tickSpacingToFee(cfg.tickSpacing) == 0
                || factory.getPool(cfg.token0, cfg.token1, cfg.tickSpacing) != pool
        ) revert InvalidPool();
    }

    /// @dev True when the pool's gauge owns the NFT; a failed gauge read counts as no gauge.
    function _isEncumbered(
        Market storage market,
        bytes32 positionKey
    ) internal view override returns (bool) {
        address gauge = _gaugeOf(market.cfg.pool);
        return gauge != address(0) && _manager(positionKey).ownerOf(_tokenId(positionKey)) == gauge;
    }

    function _blockTime() internal view override returns (uint256) {
        return _BLOCK_TIME;
    }

    /// @dev The (position manager, factory) pair of a generation; `UnsupportedNft` at or above `GENERATION_COUNT`.
    function _generation(
        uint256 index
    ) private view returns (address npm, address factory) {
        if (index == 0) return (_NPM_0, _FACTORY_0);
        if (index == 1) return (_NPM_1, _FACTORY_1);
        if (index == 2) return (_NPM_2, _FACTORY_2);
        if (index == 3) return (_NPM_3, _FACTORY_3);
        // Unreachable from `_positionKeyOf`'s loop, which passes only allowlisted indices.
        // forge-lint: disable-next-line(require-revert-in-loop)
        revert UnsupportedNft();
    }

    function _namesFactory(
        address npm,
        address factory
    ) private view returns (bool) {
        return INonfungiblePositionManager(npm).factory() == factory;
    }

    /// @dev `bytes32((generation << 248) | tokenId)`; callers ensure `tokenId < 2^248`.
    function _key(
        uint256 index,
        uint256 tokenId
    ) private pure returns (bytes32) {
        return bytes32((index << GENERATION_SHIFT) | tokenId);
    }

    function _gaugeOf(
        address pool
    ) private view returns (address gauge) {
        try ICLPool(pool).gauge() returns (address g) {
            gauge = g;
        } catch {
            gauge = address(0);
        }
    }

    /// @dev Code hash of the 45-byte EIP-1167 minimal proxy of `implementation`.
    function _cloneCodeHash(
        address implementation
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(bytes10(0x363d3d373d3d3d363d73), implementation, bytes15(0x5af43d82803e903d91602b57fd5bf3))
        );
    }
}
