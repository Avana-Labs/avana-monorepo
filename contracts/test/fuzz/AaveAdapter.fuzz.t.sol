// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapter} from "../../src/interfaces/IAaveAdapter.sol";
import {AaveAdapterTestBase} from "../utils/AaveAdapterTestBase.sol";

/// @notice Fuzzes routing, and random sequences of pledges, top-ups, withdrawals, borrows and repays over several
/// wallets and NFTs. After every step: each account's supply equals its credit (never above it with share rounding),
/// vault-token supply equals what the Hub holds and never exceeds the markets' total credit, every pledged NFT is in
/// the LPVault under its wallet's account, and the adapter holds nothing.
contract AaveAdapterFuzzTest is AaveAdapterTestBase {
    uint256 internal constant WALLETS = 3;
    uint256 internal constant MAX_KEYS = 12;

    address[WALLETS] internal wallets;
    bytes32[] internal keys;
    mapping(bytes32 key => address wallet) internal ownerOfKey;

    function setUp() public override {
        super.setUp();
        wallets = [alice, bob, carol];
    }

    // ─── Routing ───

    /// @dev Full range goes to Full range, a position inside the band to Custom range, anything else is rejected.
    function testFuzz_routing(
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) public {
        lower = int24(bound(lower, FULL_LOWER / SPACING, FULL_UPPER / SPACING - 1)) * SPACING;
        upper = int24(bound(upper, lower / SPACING + 1, FULL_UPPER / SPACING)) * SPACING;
        liquidity = uint128(bound(liquidity, 1e9, 1e30));
        if (uint256(keccak256(abi.encode(lower, upper))) % 4 == 0) (lower, upper) = (FULL_LOWER, FULL_UPPER);
        bytes32 key = _mint(alice, lower, upper, liquidity);
        bool full = lower == FULL_LOWER && upper == FULL_UPPER;
        bool inside = lower >= BAND_LOWER && upper <= BAND_UPPER;
        if (!full && !inside) {
            vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.NoMarketFits.selector, POOL, lower, upper));
            _pledge(alice, key);
            return;
        }
        address predicted = adapter.predictAccount(alice, full ? FULL : CUSTOM);
        vm.prank(alice);
        try adapter.pledge(key) returns (uint256 marketId, uint128 credit) {
            assertEq(marketId, full ? FULL : CUSTOM);
            assertEq(adapter.accountOf(alice, marketId), predicted);
            assertEq(_supplied(alice, marketId), credit);
            if (full) assertEq(credit, liquidity);
            else assertLe(credit, liquidity);
        } catch (bytes memory err) {
            // A sliver of a band can floor to zero credit; the LPVault refuses it.
            assertEq(bytes4(err), bytes4(keccak256("ZeroCredit(bytes32)")));
        }
    }

    // ─── Sequences ───

    /// @param ops Each word picks an action, a wallet, a key and an amount.
    function testFuzz_sequence(
        uint256[24] calldata ops,
        bool rounding
    ) public {
        if (rounding) spoke.setSupplyHaircut(1);
        for (uint256 i; i < ops.length; ++i) {
            uint256 op = ops[i];
            address w = wallets[(op >> 8) % WALLETS];
            uint256 amount = bound(op >> 64, 1e12, 1e24);
            uint256 action = op % 7;
            if (action <= 1 || keys.length == 0) _doPledge(w, op, amount);
            else if (action == 2) _doAddLiquidity(op, amount);
            else if (action == 3) _doWithdraw(op, amount, false);
            else if (action == 4) _doWithdraw(op, amount, true);
            else if (action == 5) _doBorrow(w, op, amount);
            else _doRepay(w, op, amount);
            _checkInvariants(rounding);
        }
    }

    function _doPledge(
        address w,
        uint256 op,
        uint256 amount
    ) internal {
        if (keys.length >= MAX_KEYS) return;
        bool full = (op >> 16) % 2 == 0;
        int24 off = int24(uint24((op >> 24) % 99) + 1) * SPACING;
        bytes32 key = full
            ? _mint(w, FULL_LOWER, FULL_UPPER, uint128(amount))
            : _mint(w, BAND_LOWER + off, BAND_UPPER - off, uint128(amount));
        _pledge(w, key);
        keys.push(key);
        ownerOfKey[key] = w;
    }

    function _doAddLiquidity(
        uint256 op,
        uint256 amount
    ) internal {
        bytes32 key = keys[(op >> 32) % keys.length];
        address w = ownerOfKey[key];
        if (w == address(0)) return;
        token0.mint(w, amount);
        token1.mint(w, amount);
        vm.prank(w);
        adapter.addLiquidity(key, amount, amount, 0, 0);
    }

    function _doWithdraw(
        uint256 op,
        uint256 amount,
        bool whole
    ) internal {
        bytes32 key = keys[(op >> 32) % keys.length];
        address w = ownerOfKey[key];
        if (w == address(0)) return;
        uint128 recorded = vault.getPosition(key).liquidity;
        uint128 liquidity = whole ? 0 : uint128(bound(amount, 1, recorded));
        vm.prank(w);
        try adapter.withdraw(key, liquidity, 0, 0, w) {
            if (whole || liquidity >= recorded) {
                assertEq(pm.ownerOf(uint256(key)), w);
                ownerOfKey[key] = address(0);
            }
        } catch (bytes memory err) {
            // Only the health check, or a sliver whose credit floors to zero, may stop a withdrawal.
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == bytes4(keccak256("HealthFactorBelowOne()")) || sel == bytes4(keccak256("ZeroCredit(bytes32)"))
                    || sel == bytes4(keccak256("InvalidAmount(bytes32,uint256)"))
            );
        }
    }

    function _doBorrow(
        address w,
        uint256 op,
        uint256 amount
    ) internal {
        uint256 marketId = (op >> 40) % 2 == 0 ? FULL : CUSTOM;
        address account = adapter.accountOf(w, marketId);
        if (account == address(0)) return;
        (uint256 power, uint256 owed) = spoke.headroom(account);
        if (power <= owed) return;
        uint256 room = power - owed;
        vm.prank(w);
        adapter.borrow(marketId, DEBT_RESERVE, bound(amount, 1, room), w);
    }

    function _doRepay(
        address w,
        uint256 op,
        uint256 amount
    ) internal {
        uint256 marketId = (op >> 40) % 2 == 0 ? FULL : CUSTOM;
        address account = adapter.accountOf(w, marketId);
        if (account == address(0) || spoke.debt(account, DEBT_RESERVE) == 0) return;
        usdc.mint(w, amount);
        vm.prank(w);
        adapter.repay(marketId, DEBT_RESERVE, amount, w);
    }

    function _checkInvariants(
        bool rounding
    ) internal view {
        uint256[2] memory markets = [FULL, CUSTOM];
        for (uint256 m; m < 2; ++m) {
            uint256 sum;
            for (uint256 i; i < WALLETS; ++i) {
                address account = adapter.accountOf(wallets[i], markets[m]);
                if (account == address(0)) continue;
                uint256 supplied = spoke.supplied(account, markets[m]);
                uint256 credit = vault.accountCredit(account, markets[m]);
                if (rounding) assertLe(supplied, credit, "supply above credit");
                else assertEq(supplied, credit, "supply differs from credit");
                (uint256 power, uint256 owed) = spoke.headroom(account);
                assertLe(owed, power, "account below health");
                sum += supplied;
            }
            address vt = m == 0 ? address(vtFull) : address(vtCustom);
            assertEq(vtFull.balanceOf(address(adapter)) + vtCustom.balanceOf(address(adapter)), 0);
            assertLe(sum, _balance(vt, address(hub)));
            assertEq(_totalSupply(vt), _balance(vt, address(hub)), "vault tokens outside the Hub");
            // With share rounding the Hub keeps the lost units, as Aave does; without it supply never exceeds credit.
            if (!rounding) assertLe(_totalSupply(vt), vault.getMarket(markets[m]).totalCredit, "supply above credit");
        }
        for (uint256 i; i < keys.length; ++i) {
            address w = ownerOfKey[keys[i]];
            if (w == address(0)) continue;
            assertEq(pm.ownerOf(uint256(keys[i])), address(vault));
            address account = vault.getPosition(keys[i]).account;
            assertEq(account, adapter.accountOf(w, vault.getPosition(keys[i]).marketId));
        }
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }

    function _balance(
        address token,
        address who
    ) internal view returns (uint256) {
        return token == address(vtFull) ? vtFull.balanceOf(who) : vtCustom.balanceOf(who);
    }

    function _totalSupply(
        address token
    ) internal view returns (uint256) {
        return token == address(vtFull) ? vtFull.totalSupply() : vtCustom.totalSupply();
    }
}
