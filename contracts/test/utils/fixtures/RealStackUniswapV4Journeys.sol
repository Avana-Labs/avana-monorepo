// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {UniswapV4State} from "../../../src/amm/uniswap-v4/UniswapV4State.sol";
import {IUniswapV4PoolManager} from "../../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {LiquidationResult} from "../../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {PositionRef} from "../../../src/types/PositionTypes.sol";
import {ClTestToken, IClPool} from "./ClPoolFixture.sol";
import {RealStackUniswapV4} from "./RealStackUniswapV4.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title RealStackUniswapV4Journeys
/// @notice The shared journeys' stack for Uniswap v4 markets: `RealStackUniswapV4` with a USDC/USDT v4 market `mS` on
/// the Stable Hub's v4 Spoke (fee 100, spacing 1, outside LPs' full-range liquidity 1e15) and a native ETH/USDC v4
/// market `mE` on the Volatile Hub's v4 Spoke (fee 500, spacing 10), each priced by the real `LPOracleV4` against its
/// Uniswap v3 reference pool, plus helpers that work on any Spoke: repay, liquidate, fees owed, a wash through the v4
/// pool, a USDT depeg that moves the v4 pools with the feeds, and the settlement identities of a liquidation.
/// @dev A $20,000 full-range USDC/USDT position (`_v4PledgeUsd`) with 5,880 USDC of debt is at HF 1.020 (CF 30 %);
/// USDT at $0.93 takes it below 1, as for the Uniswap v3 journeys.
abstract contract RealStackUniswapV4Journeys is RealStackUniswapV4 {
    uint256 internal constant USD = 20_000;
    uint256 internal constant DEBT_USDC = 5880e6;
    uint256 internal constant DEBT_GHO = 5880e18;

    uint256 internal mA;
    uint256 internal mS;
    uint256 internal mE;
    address internal vtS;
    address internal vtE;

    function _setUpV4Journeys() internal {
        _setUpFullStack();
        mA = _addMarket(poolA);
        _setUpUniswapV4();
        (address s0, address s1) =
            address(usdc) < address(usdt) ? (address(usdc), address(usdt)) : (address(usdt), address(usdc));
        (PoolKey memory stableKey, IClPool stableRef) = _newV4Pool(s0, s1, 100, 1, 1e15);
        (PoolKey memory ethKey, IClPool ethRef) = _newV4Pool(address(0), address(usdc), 500, 10, 1e18);
        IClPool[] memory refs = new IClPool[](2);
        (refs[0], refs[1]) = (stableRef, ethRef);
        _ageNewPools(refs);
        mS = _addV4Market(stableKey, stableRef, VT_CF);
        mE = _addV4Market(ethKey, ethRef, VT_CF);
        _pokeAll();
        for (uint256 k = 0; k < 2; ++k) {
            IClPool r = routePoolOf[address(weth)][address(gho)][k];
            (int24 lower, int24 upper) = _fullRange(r);
            actor.mint(r, lower, upper, 1e22);
        }
        (vtS, vtE) = (mkt[mS].vaultToken, mkt[mE].vaultToken);
    }

    // ─── Accounts ───

    function _ref4(
        bytes32 key
    ) internal pure returns (PositionRef memory) {
        return PositionRef(V4, key);
    }

    function _credited4(
        bytes32 key
    ) internal view returns (uint256) {
        return coll.getRecord(coll.recordIdOf(V4, key)).credited;
    }

    function _spokeOf(
        uint256 marketId
    ) internal view returns (address) {
        return registry.getMarket(marketId).spoke;
    }

    /// @dev A $20,000 position in `mS` pledged by `wallet` with `debt` borrowed from `reserveId` of the Stable v4 Spoke.
    function _stableAccount(
        address wallet,
        uint256 reserveId,
        uint256 debt
    ) internal returns (address proxy, bytes32 key) {
        (key, proxy) = _v4PledgeUsd(wallet, mS, USD);
        if (debt != 0) _borrowAs(wallet, mS, reserveId, debt);
    }

    function _assetOn(
        address spoke,
        uint256 reserveId
    ) internal view returns (ClTestToken) {
        return ClTestToken(registry.getDebtReserve(spoke, reserveId).asset);
    }

    /// @dev `_repayVia` for a debt reserve of any Spoke.
    function _repayOn(
        address payer,
        address wallet,
        uint256 marketId,
        uint256 reserveId,
        uint256 maxSpend,
        bool repayAll
    ) internal returns (uint256 spent) {
        ClTestToken asset = _assetOn(_spokeOf(marketId), reserveId);
        asset.mint(payer, maxSpend);
        vm.startPrank(payer);
        asset.approve(adapter, maxSpend);
        spent = adapterC.repay(wallet, marketId, reserveId, maxSpend, repayAll, _deadline());
        asset.approve(adapter, 0);
        vm.stopPrank();
    }

    // ─── Prices and fees ───

    /// @dev USDT alone at `price8` on every feed, every v4 pool swapped to the published rates, then the reference
    /// pools, the TWAP wait, the feeds, the routes and the pokes (`_repriceV4Markets`).
    function _depegUsdt4(
        uint256 price8
    ) internal {
        _publish(address(usdt), price8);
        _repriceV4Markets();
    }

    /// @dev `amount` of token0 sold into market `marketId`'s v4 pool, then the pool swapped back to its price in the
    /// same block: in-range positions accrue fees in both tokens and the reference TWAP is unmoved.
    function _washV4Market(
        uint256 marketId,
        uint256 amount
    ) internal {
        PoolKey memory pk = v4KeyOf[marketId];
        (uint160 start,) = UniswapV4State.slot0(IUniswapV4PoolManager(address(v4pm)), keccak256(abi.encode(pk)));
        v4actor.swap(pk, true, -int256(amount), ClPriceMath.MIN_SQRT_RATIO + 1);
        v4actor.swap(pk, false, -int256(uint256(type(uint128).max)), start);
    }

    /// @dev The fees the PoolManager would credit position `key` of `marketId` on its next liquidity change.
    function _feesOwed4(
        uint256 marketId,
        bytes32 key
    ) internal view returns (uint256 f0, uint256 f1) {
        PoolKey memory pk = v4KeyOf[marketId];
        IUniswapV4PoolManager m = IUniswapV4PoolManager(address(v4pm));
        bytes32 id = keccak256(abi.encode(pk));
        (int24 lower, int24 upper) = _v4FullRange(pk.tickSpacing);
        UniswapV4State.PositionState memory p =
            UniswapV4State.position(m, id, UniswapV4State.positionId(address(v4posm), lower, upper, key));
        (uint256 in0, uint256 in1) = UniswapV4State.feeGrowthInside(m, id, lower, upper);
        (f0, f1) = UniswapV4State.feesOwed(p, in0, in1);
    }

    /// @dev Balances of market `marketId`'s two tokens (WETH for native ETH).
    function _pair4(
        uint256 marketId,
        address who
    ) internal view returns (uint256 b0, uint256 b1) {
        PoolKey memory pk = v4KeyOf[marketId];
        address t0 = Currency.unwrap(pk.currency0) == address(0) ? address(weth) : Currency.unwrap(pk.currency0);
        b0 = IERC20(t0).balanceOf(who);
        b1 = IERC20(Currency.unwrap(pk.currency1)).balanceOf(who);
    }

    // ─── Settlement ───

    /// @dev The settlement identities of `TEST-047` on one result, and nothing left in LPVaultSwap, the LPVault or the
    /// Lock.
    function _checkSettlement4(
        LiquidationResult memory r,
        uint256 x,
        ClTestToken asset,
        address vt
    ) internal view {
        assertEq(r.debtAsset, address(asset), "settled in the repaid debt asset");
        assertEq(r.callerFunds, x, "Kf = the pulled funding");
        assertLe(r.debtRepaid, r.callerFunds, "D <= Kf");
        assertEq(
            r.callerFunds + r.recovered + r.shortfall,
            r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut,
            "Kf + R + shortfall = D + A + B + keeperOut"
        );
        assertGe(r.recovered + r.shortfall, r.minOut, "R + shortfall >= minRec");
        ClTestToken[5] memory ts = [usdc, usdt, gho, weth, wbtc];
        for (uint256 k = 0; k < ts.length; ++k) {
            assertEq(ts[k].balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no token");
        }
        assertEq(IERC20(vt).balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps no vault token");
        assertEq(v4Vault.balance, 0, "the LPVault never holds ETH");
        assertFalse(lock.isLocked(), "Lock released");
    }

    /// @dev Supply equals credited plus pending for vault token `vt`.
    function _assertBacked(
        address vt
    ) internal view {
        assertEq(IERC20(vt).totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "supply backed");
    }
}
