// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPVault} from "../LPVault.sol";
import {IUniswapV2Factory} from "../dependencies/uniswap-v2/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "../dependencies/uniswap-v2/IUniswapV2Pair.sol";
import {IUniswapV2Integration} from "../interfaces/IUniswapV2Integration.sol";
import {IUniswapV2Positions} from "../interfaces/IUniswapV2Positions.sol";
import {ClTickMath} from "../libraries/ClTickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title UniswapV2Integration
/// @notice Uniswap v2 LPVault: the shared LPVault over `UniswapV2Positions` NFTs. A position is full range with
/// liquidity `lpAmount · √k / totalSupply` (see contracts/design/uniswap-v2.md).
/// @dev v2 fees compound into `k`, so there are no separate fees: `_collect` and `_uncollectedFees` are zero and the
/// growth stays with the position: a removal or unwind burns only the LP that holds the removed liquidity now. Token amounts out of `burn` are measured as balance
/// differences, so a fee-on-transfer or rebasing token never pays a recipient from another position's tokens.
contract UniswapV2Integration is LPVault, IUniswapV2Integration {
    using SafeERC20 for IERC20;

    /// @inheritdoc IUniswapV2Integration
    int24 public constant override TICK_SPACING = 1;

    address private immutable _POSITIONS;
    address private immutable _FACTORY;

    /// @dev LP each record holds: what the NFT held at the pledge, plus LP added through the LPVault, less LP burned. LP
    /// sent straight to the wrapper's open `increase` is not in it, so it is never credited or burned and goes back with
    /// the NFT. Set again at each pledge.
    mapping(uint256 tokenId => uint256 lp) private _recordLp;

    /// @notice Fixes the AccessManager, the position wrapper and the canonical factory.
    /// @dev Reverts `InvalidDeployment` unless the wrapper is a contract that names `factory`.
    constructor(
        address authority,
        address positions,
        address factory
    ) LPVault(authority) {
        if (positions == address(0) || factory == address(0) || positions.code.length == 0) revert InvalidDeployment();
        if (IUniswapV2Positions(positions).FACTORY() != factory) revert InvalidDeployment();
        _POSITIONS = positions;
        _FACTORY = factory;
    }

    /// @inheritdoc IUniswapV2Integration
    function POSITIONS() external view override returns (address) {
        return _POSITIONS;
    }

    /// @inheritdoc IUniswapV2Integration
    function FACTORY() external view override returns (address) {
        return _FACTORY;
    }

    /// @inheritdoc IUniswapV2Integration
    function liquidityOf(
        address pair,
        uint256 lpAmount
    ) external view override returns (uint128) {
        return _liquidityOf(pair, lpAmount);
    }

    function _nft(
        bytes32 positionKey
    ) internal view override returns (IERC721, uint256) {
        return (IERC721(_POSITIONS), uint256(positionKey));
    }

    /// @dev The pair comes from the wrapper's record; an unknown key reads as pool 0 and fails `PoolMismatch`.
    function _readPosition(
        bytes32 positionKey
    ) internal view override returns (bytes32 pool, int24 tickLower, int24 tickUpper, uint128 liquidity) {
        (address pair, uint256 lp) = IUniswapV2Positions(_POSITIONS).positions(uint256(positionKey));
        pool = bytes32(uint256(uint160(pair)));
        (tickLower, tickUpper) = (ClTickMath.MIN_TICK, ClTickMath.MAX_TICK);
        if (pair != address(0)) liquidity = _liquidityOf(pair, lp);
    }

    /// @dev The pool must be the factory's pair of its own tokens.
    function _poolInfo(
        bytes32 pool
    ) internal view override returns (address token0, address token1, int24 tickSpacing) {
        address p = address(uint160(uint256(pool)));
        if (uint256(pool) >> 160 != 0 || p.code.length == 0) revert InvalidPool(pool);
        (token0, token1) = (IUniswapV2Pair(p).token0(), IUniswapV2Pair(p).token1());
        if (IUniswapV2Factory(_FACTORY).getPair(token0, token1) != p) revert InvalidPool(pool);
        tickSpacing = TICK_SPACING;
    }

    /// @dev The record starts with all the LP the NFT holds, the LP its credit was read from.
    function _recordPledge(
        bytes32 positionKey
    ) internal override {
        // The pair was checked against the market by the pledge; only the LP amount is recorded.
        // forge-lint: disable-next-line(unused-return)
        (, uint256 lp) = IUniswapV2Positions(_POSITIONS).positions(uint256(positionKey));
        _recordLp[uint256(positionKey)] = lp;
    }

    /// @dev Router-style amounts at the reserves (the LPVault checks the minimums), `mint` to the LPVault, then the LP
    /// goes into the position. The liquidity added is that of the LP that arrived in the position.
    function _increase(
        Market storage m,
        bytes32 positionKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256,
        uint256
    ) internal override returns (uint128 liquidity, uint256 amount0, uint256 amount1, uint256, uint256) {
        address pair = address(uint160(uint256(m.pool)));
        (amount0, amount1) = _amountsAtReserves(pair, amount0Desired, amount1Desired);
        IERC20(m.token0).safeTransfer(pair, amount0);
        IERC20(m.token1).safeTransfer(pair, amount1);
        uint256 lp = IUniswapV2Pair(pair).mint(address(this));
        IERC20(pair).forceApprove(_POSITIONS, lp);
        uint256 received = IUniswapV2Positions(_POSITIONS).increase(uint256(positionKey), lp);
        _recordLp[uint256(positionKey)] += received;
        liquidity = _liquidityOf(pair, received);
        return (liquidity, amount0, amount1, 0, 0);
    }

    /// @dev The Uniswap v2 router's amounts: all of one desired amount and the other at the reserve ratio.
    function _amountsAtReserves(
        address pair,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) private view returns (uint256 amount0, uint256 amount1) {
        // The timestamp is not used.
        // forge-lint: disable-next-line(unused-return)
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        uint256 optimal1 = Math.mulDiv(amount0Desired, r1, r0);
        if (optimal1 <= amount1Desired) return (amount0Desired, optimal1);
        return (Math.mulDiv(amount1Desired, r0, r1), amount1Desired);
    }

    /// @dev Burns the LP that holds `liquidity` at the pair's √k now, at most the record's share of its LP. Fee growth
    /// since the pledge stays in the position, as v3 and v4 fees do, and goes back with the NFT. Amounts are the
    /// LPVault's balance differences around `burn`.
    function _decrease(
        Market storage m,
        bytes32 positionKey,
        uint128 liquidity,
        uint256,
        uint256
    ) internal override returns (uint256 amount0, uint256 amount1, uint256, uint256) {
        (amount0, amount1) = _burnShare(uint256(positionKey), liquidity, m.token0, m.token1);
        return (amount0, amount1, 0, 0);
    }

    /// @dev Unwraps the LP holding `liquidity` now (capped at the record's share) to the pair and burns it to the
    /// LPVault; the pair's reported amounts are not trusted, the balance differences are.
    function _burnShare(
        uint256 tokenId,
        uint128 liquidity,
        address token0,
        address token1
    ) private returns (uint256 amount0, uint256 amount1) {
        // Only the pair is used; the LP to burn comes from the record, not from all the NFT holds.
        // forge-lint: disable-next-line(unused-return)
        (address pair,) = IUniswapV2Positions(_POSITIONS).positions(tokenId);
        uint256 recorded = _recordLp[tokenId];
        uint256 lp = Math.mulDiv(recorded, liquidity, _positions[bytes32(tokenId)].liquidity + liquidity);
        uint256 held = _lpOf(pair, liquidity);
        if (held < lp) lp = held;
        if (_burnsToNothing(pair, lp)) return (0, 0);
        _recordLp[tokenId] = recorded - lp;
        IUniswapV2Positions(_POSITIONS).unwrap(tokenId, lp, pair);
        uint256 before0 = IERC20(token0).balanceOf(address(this));
        uint256 before1 = IERC20(token1).balanceOf(address(this));
        // forge-lint: disable-next-line(unused-return)
        IUniswapV2Pair(pair).burn(address(this));
        amount0 = IERC20(token0).balanceOf(address(this)) - before0;
        amount1 = IERC20(token1).balanceOf(address(this)) - before1;
    }

    /// @dev Fees compound into the LP; nothing to collect.
    function _collect(
        Market storage,
        bytes32
    ) internal pure override returns (uint256, uint256) {
        return (0, 0);
    }

    /// @dev Fees compound into the LP; nothing uncollected.
    function _uncollectedFees(
        Market storage,
        bytes32
    ) internal pure override returns (uint256, uint256) {
        return (0, 0);
    }

    /// @dev Whether burning `lp` would pay zero of either token, which `burn` refuses: the dust stays in the position.
    function _burnsToNothing(
        address pair,
        uint256 lp
    ) private view returns (bool) {
        if (lp == 0) return true;
        (uint256 r0, uint256 r1, uint256 supply) = _state(pair);
        return Math.mulDiv(lp, r0, supply) == 0 || Math.mulDiv(lp, r1, supply) == 0;
    }

    /// @dev The LP holding `liquidity` now, `⌈liquidity · supply / √(r0 · r1)⌉` with `_state`'s supply (the pending
    /// protocol fee included); the largest value when the pair has no reserves, so the record's share applies.
    function _lpOf(
        address pair,
        uint128 liquidity
    ) private view returns (uint256) {
        (uint256 r0, uint256 r1, uint256 supply) = _state(pair);
        uint256 rootK = Math.sqrt(r0 * r1);
        if (rootK == 0) return type(uint256).max;
        return Math.mulDiv(liquidity, supply, rootK, Math.Rounding.Ceil);
    }

    /// @dev `lpAmount · √(r0 · r1) / supply`.
    function _liquidityOf(
        address pair,
        uint256 lpAmount
    ) private view returns (uint128) {
        if (lpAmount == 0) return 0;
        (uint256 r0, uint256 r1, uint256 supply) = _state(pair);
        return SafeCast.toUint128(Math.mulDiv(lpAmount, Math.sqrt(r0 * r1), supply));
    }

    /// @dev The reserves and the LP supply with the protocol fee v2-core's `_mintFee` would mint at the next `mint` or
    /// `burn` if the fee were on. It is counted whenever `kLast` is set, also while `feeTo` is off: v2-core keeps
    /// `kLast` until the next mint or burn, so a fee switched on before then mints on all growth since `kLast`, and a
    /// credit fixed at the pledge must already be below that dilution. With the fee off this reads at most the
    /// pending fee lower than Aave's `UniswapV2PriceProvider`, never higher.
    function _state(
        address pair
    ) private view returns (uint256 r0, uint256 r1, uint256 supply) {
        IUniswapV2Pair p = IUniswapV2Pair(pair);
        // The timestamp is not used.
        // forge-lint: disable-next-line(unused-return)
        (r0, r1,) = p.getReserves();
        supply = p.totalSupply();
        uint256 rootKLast = Math.sqrt(p.kLast());
        if (rootKLast != 0) {
            uint256 rootK = Math.sqrt(r0 * r1);
            if (rootK > rootKLast) supply += Math.mulDiv(supply, rootK - rootKLast, rootK * 5 + rootKLast);
        }
    }
}
