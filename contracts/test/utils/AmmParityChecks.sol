// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {INonfungiblePositionManager} from "../../src/dependencies/uniswap/INonfungiblePositionManager.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {INfpmPositions} from "../../src/interfaces/INfpmPositions.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {LPPriceMath} from "../../src/libraries/LPPriceMath.sol";
import {AvanaTest} from "./AvanaTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AmmParityChecks
/// @notice Compares, for one pledged position, what Avana computes with what the upstream manager and pool actually
/// pay. `_checkNfpmParity` does it for a NonfungiblePositionManager AMM (Uniswap v3, Slipstream), inside a state
/// snapshot that is rolled back:
/// - fees: `feesOf` equals what `decreaseLiquidity(all)` then `collect` pays beyond the principal (fee growth inside
///   and outside, tick crossings, the modulo-2^256 differences);
/// - position value: `LPPriceMath.amounts` at the pool's square-root price (the amounts Avana's oracle uses) equals
///   the principal the pool burns, to the wei;
/// - credit: the band amounts of the record's credit are worth at most the burned principal at the pool's price,
///   which is the documented safe direction (FloorCreditMath rounds the credit down).
abstract contract AmmParityChecks is AvanaTest {
    uint256 private constant Q96 = 1 << 96;

    struct Burned {
        uint256 principal0;
        uint256 principal1;
        uint256 fees0;
        uint256 fees1;
    }

    /// @dev The pool's current square-root price (the first word of `slot0`, as for Uniswap v3 and Slipstream).
    function _poolSqrtPrice(
        address pool
    ) internal view returns (uint160 s) {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        require(ok && ret.length >= 32, "slot0");
        s = abi.decode(ret, (uint160));
    }

    /// @dev What the manager pays the vault for the whole position now, without keeping the change.
    function _burnAllAndRollBack(
        address vault,
        address nfpm,
        uint256 tokenId
    ) internal returns (Burned memory b) {
        uint128 liquidity = INfpmPositions(nfpm).positions(tokenId).liquidity;
        uint256 snap = vm.snapshotState();
        vm.startPrank(vault);
        if (liquidity > 0) {
            (b.principal0, b.principal1) = INonfungiblePositionManager(nfpm)
                .decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                    })
                );
        }
        (uint256 c0, uint256 c1) = INonfungiblePositionManager(nfpm)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(0xdead),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        vm.stopPrank();
        vm.revertToState(snap);
        (b.fees0, b.fees1) = (c0 - b.principal0, c1 - b.principal1);
    }

    /// @dev Every parity check of the contract notice for `key` (token `tokenId` of `nfpm`) in `marketId`.
    function _checkNfpmParity(
        ILPVault vault,
        address nfpm,
        address pool,
        bytes32 key,
        uint256 tokenId,
        uint256 marketId
    ) internal {
        INfpmPositions.NfpmPositionData memory p = INfpmPositions(nfpm).positions(tokenId);
        (uint256 f0, uint256 f1) = vault.feesOf(key);
        uint160 s = _poolSqrtPrice(pool);
        Burned memory b = _burnAllAndRollBack(address(vault), nfpm, tokenId);

        assertEq(f0, b.fees0, "feesOf token0 differs from what the manager pays");
        assertEq(f1, b.fees1, "feesOf token1 differs from what the manager pays");

        (uint256 a0, uint256 a1) = LPPriceMath.amounts(
            s, ClTickMath.getSqrtPriceAtTick(p.tickLower), ClTickMath.getSqrtPriceAtTick(p.tickUpper), p.liquidity
        );
        assertEq(a0, b.principal0, "position amount0 differs from the pool's burn");
        assertEq(a1, b.principal1, "position amount1 differs from the pool's burn");

        _checkCreditWithin(vault, key, marketId, s, b.principal0, b.principal1);
    }

    /// @dev The band amounts of the record's credit are worth at most the principal `(p0, p1)` the pool pays for the
    /// whole position, at the pool's price `s`, with one wei of each token for the pool's own rounding.
    function _checkCreditWithin(
        ILPVault vault,
        bytes32 key,
        uint256 marketId,
        uint160 s,
        uint256 p0,
        uint256 p1
    ) internal view {
        ILPVault.Market memory m = vault.getMarket(marketId);
        uint128 credit = vault.getPosition(key).credit;
        (uint256 x0, uint256 x1) = LPPriceMath.amounts(
            s, ClTickMath.getSqrtPriceAtTick(m.bandLower), ClTickMath.getSqrtPriceAtTick(m.bandUpper), credit
        );
        assertLe(
            _valueIn1(x0, x1, s, Math.Rounding.Floor),
            _valueIn1(p0 + 1, p1 + 1, s, Math.Rounding.Ceil),
            "credit's band amounts worth more than the position at the pool price"
        );
    }

    /// @dev `a0 · s² / 2^192 + a1`, the value in token1 at the square-root price `s`.
    function _valueIn1(
        uint256 a0,
        uint256 a1,
        uint160 s,
        Math.Rounding r
    ) internal pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(a0, s, Q96, r), s, Q96, r) + a1;
    }
}
