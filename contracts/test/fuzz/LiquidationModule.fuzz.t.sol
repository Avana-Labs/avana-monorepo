// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";
import {LiquidationMath} from "../../src/libraries/LiquidationMath.sol";
import {LiquidationModuleTestBase} from "../utils/LiquidationModuleTestBase.sol";

/// @notice Partial liquidation over random positions, debts, price falls, repayments and bonuses: health improves, the
/// seized units are burned, the unwound tokens all reach the liquidator and the fee recipient in the fee share, the
/// borrower loses no more credit than was seized, and the module keeps nothing.
contract LiquidationModuleFuzzTest is LiquidationModuleTestBase {
    struct Snap {
        uint256 hf;
        uint256 supply;
        uint256 credit;
        uint256 debt;
        uint256 liquidity;
    }

    struct Case {
        uint256 marketId;
        address account;
        bytes32 key;
        uint256 toCover;
        uint256 bonusBps;
    }

    struct Input {
        uint128 liquidity;
        uint256 borrowBps;
        uint256 cfAfter;
        uint256 bonusBps;
        uint256 repayBps;
        bool custom;
        int24 narrowHalf;
    }

    function testFuzz_partialLiquidation(
        Input memory input
    ) public {
        Case memory c = _open(input);
        Snap memory b = _snap(c.account, c.marketId, c.key);
        ILiquidationModule.LiquidationResult memory r = _liquidate(c.marketId, c.account, c.toCover);
        _check(c, b, _snap(c.account, c.marketId, c.key), r);
    }

    /// @dev An unhealthy account with one position, Full range or a narrow Custom range one, and a repayment.
    function _open(
        Input memory input
    ) internal returns (Case memory c) {
        uint128 liquidity = uint128(bound(input.liquidity, 1e15, 1e30));
        uint256 borrowBps = bound(input.borrowBps, 5000, 10_000);
        c.bonusBps = bound(input.bonusBps, 10_000, 11_000);
        spoke.setBonus(c.bonusBps);
        int24 half = int24(bound(input.narrowHalf, 1, 100)) * SPACING;
        c.key = input.custom ? _mint(alice, -half, half, liquidity) : _mint(alice, FULL_LOWER, FULL_UPPER, liquidity);
        uint128 credit;
        (c.marketId, credit) = _pledge(alice, c.key);
        vm.assume(credit > 1e6);
        _borrow(alice, c.marketId, uint256(credit) * CF_BPS / 10_000 * borrowBps / 10_000);
        c.account = _account(alice, c.marketId);
        // Health below 1; `bonus · borrowBps < 1.25e8`, so each repayment cannot lower it.
        spoke.setCf(c.marketId, bound(input.cfAfter, 2000, (CF_BPS * borrowBps / 10_000) - 1));
        uint256 debt = spoke.debt(c.account, DEBT_RESERVE);
        c.toCover = bound(input.repayBps, 1, 10_000) * debt / 10_000;
        vm.assume(c.toCover * c.bonusBps / 10_000 != 0);
    }

    function _check(
        Case memory c,
        Snap memory b,
        Snap memory a,
        ILiquidationModule.LiquidationResult memory r
    ) internal view {
        // Health improves (or the account is closed out into a deficit).
        if (spoke.deficit(DEBT_RESERVE) == 0) {
            assertGe(a.hf, b.hf, "health improves");
            assertEq(b.debt - a.debt, r.debtRepaid, "debt falls by the repayment");
        }
        // Seized units are burned and leave the account's supply.
        assertEq(b.supply - a.supply, r.seized, "seized burned");
        // No value leaks: everything that left the position (the mock AMM pays one of each token per unit of
        // liquidity) reached the liquidator or the fee recipient.
        uint256 out = b.liquidity - a.liquidity;
        assertEq(out, r.amount0 + r.fee0, "token0 conserved");
        assertEq(out, r.amount1 + r.fee1, "token1 conserved");
        assertEq(token0.balanceOf(liquidator) + token0.balanceOf(feeRecipient), out);
        // The fee is Avana's share of the bonus, in the same proportion of both tokens.
        assertEq(r.feeUnits, LiquidationMath.feeUnits(r.seized, c.bonusBps, FEE_SHARE_BPS), "fee units");
        assertEq(r.fee0, out * r.feeUnits / r.seized, "fee0 share");
        assertLe(r.feeUnits * 10_000, r.seized * FEE_SHARE_BPS, "fee within its share");
        // The borrower loses no more credit than was seized, unless Aave emptied the account.
        if (a.supply != 0) assertLe(b.credit - a.credit, r.seized + 2, "credit loss <= seized");
        else assertEq(a.credit, 0, "an emptied account keeps no credit");
        _assertModuleEmpty();
    }

    function testFuzz_feeUnits(
        uint256 seized,
        uint256 bonusBps,
        uint256 shareBps
    ) public pure {
        seized = bound(seized, 0, 1e36);
        bonusBps = bound(bonusBps, 10_000, 20_000);
        shareBps = bound(shareBps, 0, 10_000);
        uint256 fee = LiquidationMath.feeUnits(seized, bonusBps, shareBps);
        uint256 bonus = seized * (bonusBps - 10_000) / bonusBps;
        assertLe(fee, bonus, "fee within the bonus");
        assertLe(fee * 10_000, bonus * shareBps, "fee within its share");
    }

    function testFuzz_creditFor(
        uint256 units,
        uint256 credit,
        uint256 cap
    ) public pure {
        credit = bound(credit, 1, type(uint128).max);
        cap = bound(cap, credit, uint256(type(uint128).max) * 4);
        units = bound(units, 0, cap);
        uint256 c = LiquidationMath.creditFor(units, credit, cap);
        assertLe(c, credit, "never more than the record");
        assertLe(c, units, "never more credit than units (cap >= credit)");
    }

    function _snap(
        address account,
        uint256 marketId,
        bytes32 key
    ) internal view returns (Snap memory s) {
        s.hf = spoke.healthFactor(account);
        s.supply = spoke.supplied(account, marketId);
        s.credit = vault.accountCredit(account, marketId);
        s.debt = spoke.debt(account, DEBT_RESERVE);
        s.liquidity = vault.getPosition(key).liquidity;
    }

    function _assertModuleEmpty() internal view {
        assertEq(token0.balanceOf(address(module)), 0);
        assertEq(token1.balanceOf(address(module)), 0);
        assertEq(usdc.balanceOf(address(module)), 0);
        assertEq(vtFull.balanceOf(address(module)) + vtCustom.balanceOf(address(module)), 0);
    }
}
