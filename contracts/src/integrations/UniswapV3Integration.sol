// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPVault} from "../LPVault.sol";
import {INonfungiblePositionManager} from "../dependencies/uniswap/INonfungiblePositionManager.sol";
import {IUniswapV3Factory} from "../dependencies/uniswap/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../dependencies/uniswap/IUniswapV3Pool.sol";
import {INfpmPositions} from "../interfaces/INfpmPositions.sol";
import {IUniswapV3Integration} from "../interfaces/IUniswapV3Integration.sol";
import {NfpmLPVault} from "./NfpmLPVault.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title UniswapV3Integration
/// @notice Uniswap v3 LPVault: the shared LPVault over the canonical NonfungiblePositionManager.
contract UniswapV3Integration is NfpmLPVault, IUniswapV3Integration {
    address private immutable _NFPM;
    address private immutable _FACTORY;

    /// @notice Fixes the AccessManager and the canonical NFPM and factory.
    /// @dev Reverts `InvalidDeployment` unless the NFPM is a contract that names `factory`.
    constructor(
        address authority,
        address nfpm,
        address factory
    ) LPVault(authority) {
        if (nfpm == address(0) || factory == address(0) || nfpm == factory || nfpm.code.length == 0) {
            revert InvalidDeployment();
        }
        if (INonfungiblePositionManager(nfpm).factory() != factory) revert InvalidDeployment();
        _NFPM = nfpm;
        _FACTORY = factory;
    }

    /// @inheritdoc IUniswapV3Integration
    function NFPM() external view override returns (address) {
        return _NFPM;
    }

    /// @inheritdoc IUniswapV3Integration
    function FACTORY() external view override returns (address) {
        return _FACTORY;
    }

    function _nft(
        bytes32 positionKey
    ) internal view override returns (IERC721, uint256) {
        return (IERC721(_NFPM), uint256(positionKey));
    }

    /// @dev The pool is derived from the position's own fields on the factory, never caller-supplied.
    function _poolOf(
        bytes32,
        INfpmPositions.NfpmPositionData memory p
    ) internal view override returns (address) {
        return IUniswapV3Factory(_FACTORY).getPool(p.token0, p.token1, p.feeOrTickSpacing);
    }

    /// @dev The pool must be the factory's pool of its own tokens and fee.
    function _poolInfo(
        bytes32 pool
    ) internal view override returns (address token0, address token1, int24 tickSpacing) {
        address p = address(uint160(uint256(pool)));
        if (uint256(pool) >> 160 != 0 || p.code.length == 0) revert InvalidPool(pool);
        IUniswapV3Pool v3 = IUniswapV3Pool(p);
        (token0, token1, tickSpacing) = (v3.token0(), v3.token1(), v3.tickSpacing());
        if (v3.factory() != _FACTORY || IUniswapV3Factory(_FACTORY).getPool(token0, token1, v3.fee()) != p) {
            revert InvalidPool(pool);
        }
    }

    function _poolGrowth(
        address pool
    ) internal view override returns (int24 tick, uint256 global0, uint256 global1) {
        // Only the tick is used.
        // forge-lint: disable-next-line(unused-return)
        (, tick,,,,,) = IUniswapV3Pool(pool).slot0();
        (global0, global1) = (IUniswapV3Pool(pool).feeGrowthGlobal0X128(), IUniswapV3Pool(pool).feeGrowthGlobal1X128());
    }

    function _feeGrowthOutside(
        address pool,
        int24 tick
    ) internal view override returns (uint256 outside0, uint256 outside1) {
        // Only the fee growth is used.
        // forge-lint: disable-next-line(unused-return)
        (,, outside0, outside1,,,,) = IUniswapV3Pool(pool).ticks(tick);
    }
}
