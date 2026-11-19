// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FlashloanRepayTestBase} from "../utils/FlashloanRepayTestBase.sol";

/// @notice Fuzzes the repay amount, the liquidity withdrawn, the swap rate and the flash premium. Either the call
/// reverts for a stated reason and nothing changes, or: the debt fell by the amount (capped at the debt), the health factor did not fall,
/// the wallet got back exactly the proceeds above the loan and its premium, and the helper holds nothing.
contract FlashloanRepayFuzzTest is FlashloanRepayTestBase {
    /// @dev The state before the call and what it should do.
    struct Expected {
        uint256 debt;
        uint256 health;
        uint256 wallet;
        uint256 repaid;
        uint256 premium;
        uint256 proceeds;
    }

    function testFuzz_repayWithCollateral(
        uint256 amount,
        uint128 liquidity,
        uint256 rateBps,
        uint256 premiumBps
    ) public {
        amount = bound(amount, 1, DEBT * 2);
        liquidity = uint128(bound(liquidity, 1, 1e18 - 1));
        rateBps = bound(rateBps, 5000, 20_000);
        premiumBps = bound(premiumBps, 0, 100);
        flashPool.setPremiumBps(premiumBps);

        Expected memory e;
        e.debt = _debt();
        e.health = _health();
        e.wallet = usdc.balanceOf(alice);
        e.repaid = amount < e.debt ? amount : e.debt;
        e.premium = (e.repaid * premiumBps + 9999) / 10_000;
        e.proceeds = 2 * (uint256(liquidity) * rateBps / 10_000);
        bytes memory data = _params(amount, liquidity, _sellBoth(rateBps));

        vm.prank(alice);
        try adapter.allowWithdraw(address(helper), key, liquidity, data) {
            _checkDone(e, liquidity);
        } catch {
            _checkReverted(e, liquidity);
        }
        _assertHelperEmpty();
    }

    function _checkDone(
        Expected memory e,
        uint128 liquidity
    ) internal view {
        assertEq(_debt(), e.debt - e.repaid, "debt");
        assertGe(_health(), e.health, "health");
        assertEq(usdc.balanceOf(alice) - e.wallet, e.proceeds - e.repaid - e.premium, "leftover");
        assertEq(_supplied(alice, FULL), 1e18 - liquidity, "supply");
    }

    function _checkReverted(
        Expected memory e,
        uint128 liquidity
    ) internal view {
        assertEq(_debt(), e.debt, "debt unchanged");
        assertEq(usdc.balanceOf(alice), e.wallet, "wallet unchanged");
        assertEq(_supplied(alice, FULL), 1e18, "supply unchanged");
        // The only reasons to revert: too little sold, a withdrawal that would leave the account unhealthy, or one
        // worth more borrowing power than the health factor times the repayment (the account would end less healthy).
        uint256 power = (1e18 - uint256(liquidity)) * CF_BPS / 10_000;
        uint256 owed = e.debt - e.repaid;
        bool short = e.proceeds < e.repaid + e.premium;
        bool unhealthy = power < owed;
        bool lowered = owed != 0 && power * 1e18 / owed < e.health;
        assertTrue(short || unhealthy || lowered, "unexpected revert");
    }
}
