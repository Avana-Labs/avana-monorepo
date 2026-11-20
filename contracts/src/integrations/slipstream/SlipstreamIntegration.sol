// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPVault} from "../../vault/LPVault.sol";
import {ICLFactory} from "../../dependencies/aerodrome/ICLFactory.sol";
import {ICLPool} from "../../dependencies/aerodrome/ICLPool.sol";
import {INonfungiblePositionManager} from "../../dependencies/aerodrome/INonfungiblePositionManager.sol";
import {INfpmPositions} from "../shared/interfaces/INfpmPositions.sol";
import {NfpmLPVault} from "../shared/NfpmLPVault.sol";
import {ISlipstreamIntegration} from "./interfaces/ISlipstreamIntegration.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title SlipstreamIntegration
/// @notice Aerodrome Slipstream LPVault: the shared LPVault over four position-manager generations.
/// @dev Never calls a gauge, the voter, `approve` on an NFT or `setApprovalForAll`.
contract SlipstreamIntegration is NfpmLPVault, ISlipstreamIntegration {
    uint8 internal constant GENERATION_COUNT = 4;
    uint256 private constant GENERATION_SHIFT = 248;

    address private immutable _NPM_0;
    address private immutable _FACTORY_0;
    address private immutable _NPM_1;
    address private immutable _FACTORY_1;
    address private immutable _NPM_2;
    address private immutable _FACTORY_2;
    address private immutable _NPM_3;
    address private immutable _FACTORY_3;

    /// @notice Fixes the AccessManager and the four (position manager, factory) pairs.
    /// @dev Reverts `InvalidDeployment` unless the eight addresses are distinct contracts and each manager names its
    /// factory.
    /// @param npms Position managers of generations 0 to 3.
    /// @param factories Pool factories of generations 0 to 3, paired by index.
    constructor(
        address authority,
        address[GENERATION_COUNT] memory npms,
        address[GENERATION_COUNT] memory factories
    ) LPVault(authority) {
        address[8] memory all =
            [npms[0], npms[1], npms[2], npms[3], factories[0], factories[1], factories[2], factories[3]];
        for (uint256 i = 0; i < 8; ++i) {
            if (all[i] == address(0) || all[i].code.length == 0) revert InvalidDeployment();
            for (uint256 j = i + 1; j < 8; ++j) {
                if (all[i] == all[j]) revert InvalidDeployment();
            }
        }
        for (uint256 g = 0; g < GENERATION_COUNT; ++g) {
            if (INonfungiblePositionManager(npms[g]).factory() != factories[g]) revert InvalidDeployment();
        }
        (_NPM_0, _NPM_1, _NPM_2, _NPM_3) = (npms[0], npms[1], npms[2], npms[3]);
        (_FACTORY_0, _FACTORY_1, _FACTORY_2, _FACTORY_3) = (factories[0], factories[1], factories[2], factories[3]);
    }

    /// @inheritdoc ISlipstreamIntegration
    function generationCount() external pure override returns (uint8) {
        return GENERATION_COUNT;
    }

    /// @inheritdoc ISlipstreamIntegration
    function generation(
        uint8 index
    ) external view override returns (address npm, address factory) {
        return _generation(index);
    }

    /// @inheritdoc ISlipstreamIntegration
    function positionKeyOf(
        uint8 index,
        uint256 tokenId
    ) external pure override returns (bytes32) {
        if (index >= GENERATION_COUNT || tokenId >> GENERATION_SHIFT != 0) revert UnsupportedNft();
        return bytes32((uint256(index) << GENERATION_SHIFT) | tokenId);
    }

    /// @dev Reverts `UnsupportedNft` for an unknown generation.
    function _nft(
        bytes32 positionKey
    ) internal view override returns (IERC721, uint256) {
        (address npm,) = _generation(uint256(positionKey) >> GENERATION_SHIFT);
        return (IERC721(npm), _tokenId(positionKey));
    }

    /// @dev The pool is derived from the position's own fields on its generation's factory, never caller-supplied.
    function _poolOf(
        bytes32 positionKey,
        INfpmPositions.NfpmPositionData memory p
    ) internal view override returns (address) {
        (, address factory) = _generation(uint256(positionKey) >> GENERATION_SHIFT);
        // A Slipstream tick spacing is positive and below 2^23.
        // forge-lint: disable-next-line(unsafe-typecast)
        return ICLFactory(factory).getPool(p.token0, p.token1, int24(p.feeOrTickSpacing));
    }

    /// @dev The pool's code hash is checked as its factory's clone before any call to the pool.
    function _poolInfo(
        bytes32 pool
    ) internal view override returns (address token0, address token1, int24 tickSpacing) {
        address p = address(uint160(uint256(pool)));
        if (uint256(pool) >> 160 != 0 || p.code.length == 0) revert InvalidPool(pool);
        for (uint256 g = 0; g < GENERATION_COUNT; ++g) {
            (address npm, address factory) = _generation(g);
            if (p.codehash != _cloneCodeHash(ICLFactory(factory).poolImplementation())) continue;
            ICLPool cl = ICLPool(p);
            (token0, token1, tickSpacing) = (cl.token0(), cl.token1(), cl.tickSpacing());
            if (
                cl.factory() != factory || cl.nft() != npm
                    || ICLFactory(factory).getPool(token0, token1, tickSpacing) != p
            ) revert InvalidPool(pool);
            return (token0, token1, tickSpacing);
        }
        revert InvalidPool(pool);
    }

    function _poolGrowth(
        address pool
    ) internal view override returns (int24 tick, uint256 global0, uint256 global1) {
        // Only the tick is used.
        // forge-lint: disable-next-line(unused-return)
        (, tick,,,,) = ICLPool(pool).slot0();
        (global0, global1) = (ICLPool(pool).feeGrowthGlobal0X128(), ICLPool(pool).feeGrowthGlobal1X128());
    }

    function _feeGrowthOutside(
        address pool,
        int24 tick
    ) internal view override returns (uint256 outside0, uint256 outside1) {
        // Only the fee growth is used.
        // forge-lint: disable-next-line(unused-return)
        (,,, outside0, outside1,,,,,) = ICLPool(pool).ticks(tick);
    }

    /// @dev The (position manager, factory) pair of a generation; `UnsupportedNft` at or above `GENERATION_COUNT`.
    function _generation(
        uint256 index
    ) private view returns (address npm, address factory) {
        if (index == 0) return (_NPM_0, _FACTORY_0);
        if (index == 1) return (_NPM_1, _FACTORY_1);
        if (index == 2) return (_NPM_2, _FACTORY_2);
        if (index == 3) return (_NPM_3, _FACTORY_3);
        revert UnsupportedNft();
    }

    function _tokenId(
        bytes32 positionKey
    ) private pure returns (uint256) {
        return uint256(positionKey) & ((uint256(1) << GENERATION_SHIFT) - 1);
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
