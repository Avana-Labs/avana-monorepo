// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title AaveAdapterFuzzTest
/// @notice Fuzzed AaveAdapter flows on the real local Aave V4 Spoke and Hub with the real Collateralization, vault
/// tokens, ProxyManager and PositionProxies: tiny positions, borrow and repay with interest per debt reserve, repay
/// sizing, the single-use nonce, the backing gap across random sequences, and the receiver rule over random receivers.
/// forge-config: default.isolate = false
contract AaveAdapterFuzzTest is AaveAdapterFixture {
    address internal sink = makeAddr("sink");

    // ─── Tiny positions (TEST-073) ───

    // TEST-073 verifies: REQ-ADAPTER-005, REQ-ADAPTER-068, REQ-PROXY-016, REQ-PROXY-031, SPEC-PROXY-003, Q-153
    // Sources: 5.1 TEST-073, HYP-40
    /// @notice A pledge of 1 to 10^6 units mints and supplies exactly the credited units; a GHO and a USDC loan of one
    /// base unit each record at least their amount as debt and a repay-all clears each.
    function testFuzz_TEST_073_tinyPositions(
        uint256 unitsSeed
    ) public {
        uint128 units = uint128(bound(unitsSeed, 1, 1e6));
        (, address p) = _pledgeAs(alice, MARKET_ID, units);
        assertEq(token.totalSupply(), units, "minted the credit");
        assertEq(_sharesOf(p, vtReserveId), units, "supplied the credit");
        assertEq(coll.getTotalCredited(vt), units, "credited");
        // One base unit of each asset: far below the CF-weighted value of even one unit at $2.00 (8e-7 USD).
        uint256 usdcAmount = 1;
        uint256 ghoAmount = units >= 1000 ? 1e9 : 1;
        _borrowAs(alice, MARKET_ID, debtReserveId, ghoAmount);
        _borrowAs(alice, MARKET_ID, usdcReserveId, usdcAmount);
        assertGe(_debtOf(p, debtReserveId), ghoAmount, "GHO debt at least the amount");
        assertGe(_debtOf(p, usdcReserveId), usdcAmount, "USDC debt at least the amount");
        _repayAllOf(alice, p, debtReserveId);
        _repayAllOf(alice, p, usdcReserveId);
        assertEq(_debtOf(p, debtReserveId), 0, "GHO cleared");
        assertEq(_debtOf(p, usdcReserveId), 0, "USDC cleared");
        assertEq(_borrowCountOf(p), 0, "debt-free");
    }

    function _repayAllOf(
        address wallet,
        address proxy,
        uint256 reserveId
    ) internal returns (uint256 spent) {
        uint256 d = _debtOf(proxy, reserveId);
        if (d == 0) return 0;
        _fund(wallet, reserveId, d);
        uint256 deadline = _deadline();
        vm.prank(wallet);
        spent = adapterC.repay(wallet, MARKET_ID, reserveId, d, true, deadline);
    }

    // ─── Borrow and repay with interest (TEST-075) ───

    // TEST-075 verifies: REQ-PROXY-021, REQ-PROXY-028, REQ-PROXY-029, REQ-PROXY-030, SPEC-PROXY-003, SPEC-PROXY-004, SPEC-PROXY-006, INV-043
    // Sources: 5.1 TEST-075, MATH-AR-03, MATH-AR-07, MATH-AR-18, HYP-47
    /// @notice Over a random sequence of borrows and partial repays on GHO (18 decimals) and USDC (6 decimals) with
    /// time passing: each borrow raises that reserve's debt by at least the amount, each repay lowers it by at most the
    /// amount (exactly what Aave took), no operation on one reserve changes the other's debt, and in the end the total
    /// repaid on each reserve is at least the total borrowed.
    function testFuzz_TEST_075_borrowRepayPerReserve(
        uint256 seed
    ) public {
        (, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        uint256 steps = bound(seed, 3, 10);
        for (uint256 i = 0; i < steps; ++i) {
            _step075(p, uint256(keccak256(abi.encode(seed, i))));
        }
        vm.warp(block.timestamp + 30 days);
        for (uint256 k = 0; k < 2; ++k) {
            uint256 reserve = k == 0 ? debtReserveId : usdcReserveId;
            repaid075[k] += _repayAllOf(alice, p, reserve);
            assertGe(repaid075[k], borrowed075[k], "total repaid at least total borrowed");
            assertEq(_debtOf(p, reserve), 0, "cleared");
        }
    }

    uint256[2] internal borrowed075;
    uint256[2] internal repaid075;

    function _step075(
        address p,
        uint256 r
    ) internal {
        uint256 which = r % 2;
        uint256 reserve = which == 0 ? debtReserveId : usdcReserveId;
        uint256 otherReserve = which == 0 ? usdcReserveId : debtReserveId;
        vm.warp(block.timestamp + (r >> 8) % 20 days);
        uint256 before = _debtOf(p, reserve);
        uint256 otherBefore = _debtOf(p, otherReserve);
        if ((r >> 64) % 3 != 0 || before == 0) {
            uint256 amount = bound(r >> 96, 1, 600) * (which == 0 ? 1e18 : 1e6);
            _borrowAs(alice, MARKET_ID, reserve, amount);
            borrowed075[which] += amount;
            assertGe(_debtOf(p, reserve), before + amount, "borrow raises debt by at least the amount");
        } else {
            uint256 cap = bound(r >> 96, 1, before);
            _fund(alice, reserve, cap);
            uint256 d = _deadline();
            vm.prank(alice);
            uint256 spent = adapterC.repay(alice, MARKET_ID, reserve, cap, false, d);
            repaid075[which] += spent;
            assertLe(spent, cap, "spent at most the pull");
            assertLe(before - _debtOf(p, reserve), cap, "repay lowers debt by at most the amount");
        }
        assertEq(_debtOf(p, otherReserve), otherBefore, "other reserve untouched");
    }

    // ─── Repay sizing (SPEC-PROXY-003, SPEC-PROXY-007) ───

    // TEST-248 verifies: REQ-PROXY-028, REQ-PROXY-029, REQ-PROXY-030, REQ-PROXY-031, REQ-ADAPTER-085, SPEC-PROXY-003, SPEC-PROXY-007
    // Sources: MATH-AR-16, MATH-AR-17, HYP-16, HYP-17
    /// @notice For a random debt, time and cap: a partial repay takes `min(cap, D)` from the payer and nothing more; a
    /// repay-all reverts `RepayExceedsMax` below the debt and otherwise pulls the cap, refunds `cap − D` and leaves 0;
    /// the payer's allowance ends at 0 when it approved the cap.
    function testFuzz_TEST_248_repaySizing(
        uint256 amountSeed,
        uint256 warpSeed,
        uint256 capSeed,
        bool all,
        bool usdc
    ) public {
        (, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        uint256 reserve = usdc ? usdcReserveId : debtReserveId;
        _borrowAs(alice, MARKET_ID, reserve, bound(amountSeed, 1, 12_000) * (usdc ? 1e6 : 1e18));
        vm.warp(block.timestamp + bound(warpSeed, 0, 365 days));
        uint256 debtNow = _debtOf(p, reserve);
        uint256 cap = bound(capSeed, 1, debtNow * 2);
        _fund(carol, reserve, cap);
        if (all && cap < debtNow) {
            uint256 d = _deadline();
            vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.RepayExceedsMax.selector, debtNow, cap));
            vm.prank(carol);
            adapterC.repay(alice, MARKET_ID, reserve, cap, true, d);
            return;
        }
        _checkSizing(p, reserve, cap, debtNow, all);
    }

    function _checkSizing(
        address p,
        uint256 reserve,
        uint256 cap,
        uint256 debtNow,
        bool all
    ) internal {
        CollPoolToken asset = _assetOf(reserve);
        uint256 d = _deadline();
        vm.prank(carol);
        uint256 spent = adapterC.repay(alice, MARKET_ID, reserve, cap, all, d);
        uint256 x = cap < debtNow ? cap : debtNow;
        assertEq(cap - asset.balanceOf(carol), spent, "the payer pays exactly what Aave took");
        assertEq(asset.allowance(carol, adapter), all ? 0 : cap - x, "allowance");
        assertEq(asset.balanceOf(p), 0, "proxy keeps nothing");
        if (all) {
            assertEq(spent, debtNow, "repay-all takes the live debt");
            assertEq(_debtOf(p, reserve), 0, "cleared");
        } else {
            assertEq(spent, x, "partial takes min(cap, D)");
            assertLe(_debtOf(p, reserve), debtNow - x + 1, "debt after within one unit of D - x");
        }
    }

    // TEST-165 verifies: REQ-PROXY-028, REQ-PROXY-068, REQ-PROXY-069, REQ-PROXY-084
    /// @notice At zero debt any non-zero cap, either flag, pulls nothing and returns 0.
    function testFuzz_TEST_165_zeroDebtPullsNothing(
        uint256 capSeed,
        bool all
    ) public {
        _pledgeAs(alice, MARKET_ID, UNITS);
        uint256 cap = bound(capSeed, 1, 1e30);
        _fund(carol, debtReserveId, cap);
        uint256 d = _deadline();
        vm.prank(carol);
        assertEq(adapterC.repay(alice, MARKET_ID, debtReserveId, cap, all, d), 0, "returns 0");
        assertEq(debt.balanceOf(carol), cap, "nothing pulled");
        assertEq(debt.allowance(carol, adapter), cap, "allowance untouched");
    }

    // ─── Nonce (REQ-PROXY-015) ───

    // TEST-096 verifies: REQ-PROXY-015, REQ-PROXY-059, INV-019, ATTACK-036
    // Sources: QNT-21, HYP-15
    /// @notice Over a random sequence of borrows carrying the right nonce or a wrong one, every wrong nonce reverts
    /// `BadNonce` and the stored nonce always equals the number of successful borrows.
    function testFuzz_TEST_096_nonceCountsSuccesses(
        uint256 seed
    ) public {
        (, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        uint256 successes = 0;
        uint256 steps = bound(seed, 1, 12);
        for (uint256 i = 0; i < steps; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 current = adapterC.borrowNonce(p);
            uint256 offset = r % 4 == 0 ? (r >> 8) % 5 + 1 : 0;
            bool backwards = (r >> 16) % 2 == 0 && current >= offset;
            uint256 expected = backwards ? current - offset : current + offset;
            uint256 reserve = (r >> 24) % 2 == 0 ? debtReserveId : usdcReserveId;
            uint256 amount = reserve == debtReserveId ? 1e18 : 1e6;
            uint256 d = _deadline();
            if (expected != current) {
                vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.BadNonce.selector, current, expected));
            } else {
                ++successes;
            }
            vm.prank(alice);
            adapterC.borrow(MARKET_ID, reserve, amount, alice, d, 0, expected);
            assertEq(adapterC.borrowNonce(p), successes, "nonce = successful borrows");
        }
    }

    // ─── Backing gap (SPEC-PROXY-008) ───

    // TEST-241 verifies: REQ-ADAPTER-069, REQ-ADAPTER-005, SPEC-PROXY-008, INV-001, INV-066, INV-080, INV-088
    // Sources: QNT-03, HYP-44
    /// @notice A random sequence of pledges, partial removals, re-credits and withdrawals (after an optional orphan
    /// burn that opens a gap) keeps the backing gap `G = totalCredited + pending − totalSupply` at its starting value
    /// and `totalSupply <= totalCredited + pending` after every call.
    function testFuzz_TEST_241_gapConstantAcrossSequences(
        uint256 seed,
        bool orphan
    ) public {
        (bytes32 first, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        if (orphan) {
            _borrowAs(alice, MARKET_ID, debtReserveId, 15_000e18);
            vtPrice.set(1.5e8);
            uint256 seized = swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, p, 1000e18);
            swap.burnUnderLock(MARKET_ID, vt, seized);
            vtPrice.set(2e8);
        }
        orphan241 = orphan;
        int256 g0 = _gap();
        keys241.push(first);
        uint256 steps = bound(seed, 2, 10);
        for (uint256 i = 0; i < steps; ++i) {
            _step241(uint256(keccak256(abi.encode(seed, i))));
            assertEq(_gap(), g0, "gap unchanged");
            assertLe(token.totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "supply backed");
        }
    }

    bytes32[] internal keys241;
    bool internal orphan241;

    function _step241(
        uint256 r
    ) internal {
        uint256 op = r % 4;
        uint256 n = keys241.length;
        uint256 d = _deadline();
        if (op == 0 && n < 8) {
            (bytes32 k,) = _pledgeAs(alice, MARKET_ID, uint128(bound(r >> 8, 2_000_000, 3_000_000_000)));
            keys241.push(k);
            return;
        }
        if (n < 2) return;
        bytes32 key = keys241[1 + (r >> 8) % (n - 1)];
        if (lpVault.depositorOf(key) != alice) return;
        if (op == 1) {
            uint256 credited = coll.previewRelease(INTEGRATION, key);
            if (credited < 2) return;
            vm.prank(alice);
            adapterC.removeLiquidity(MARKET_ID, _ref(key), uint128(bound(r >> 16, 1, credited - 1)), _mins(), d, 0);
        } else if (op == 2) {
            lpVault.addUnits(key, uint128(bound(r >> 16, 1, 1e9)));
            vm.prank(alice);
            adapterC.recredit(MARKET_ID, _ref(key), "", d);
        } else if (op == 3 && !orphan241) {
            uint256 units = coll.previewRelease(INTEGRATION, key);
            vm.prank(alice);
            adapterC.withdraw(MARKET_ID, _ref(key), units, d, 0);
        }
    }

    // ─── Receiver rule (REQ-PROXY-017) ───

    // TEST-027 verifies: REQ-PROXY-017, REQ-PROXY-061, REQ-PROXY-023, INV-020
    /// @notice A random receiver, or one drawn from the refused set, is refused with `InvalidReceiver` exactly when it
    /// is in the set of REQ-PROXY-017; otherwise it receives exactly the borrowed amount.
    function testFuzz_TEST_027_receiverRule(
        address candidate,
        uint256 pick
    ) public {
        (, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (, address bobProxy) = _pledgeAs(bob, MARKET_B, UNITS);
        address[18] memory known = [
            address(0),
            p,
            bobProxy,
            adapter,
            address(coll),
            address(swap),
            timelock,
            address(registry),
            address(pstore),
            address(risk),
            address(proxyManager),
            address(lpVault),
            registry.payoutEscrow(),
            registry.flashSourceAddr(),
            aave.hub,
            aave.cdpSpoke,
            aave.lendSpoke,
            address(debt)
        ];
        address receiver = pick % 3 == 0 ? known[(pick >> 8) % known.length] : candidate;
        vm.assume(receiver != address(vm) && receiver != CONSOLE);
        bool refused = _refused(receiver);
        uint256 nonce = adapterC.borrowNonce(p);
        uint256 d = _deadline();
        uint256 before = debt.balanceOf(receiver);
        if (refused) vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.InvalidReceiver.selector, receiver));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 10e18, receiver, d, 0, nonce);
        if (!refused) assertEq(debt.balanceOf(receiver) - before, 10e18, "receiver paid exactly");
        assertEq(adapterC.borrowNonce(p), refused ? nonce : nonce + 1, "nonce moves only on success");
    }

    function _refused(
        address a
    ) internal view returns (bool) {
        if (
            a == address(0) || adapterC.walletOf(a) != address(0) || a == adapter || a == address(coll)
                || a == address(swap) || a == timelock || a == address(registry) || a == address(pstore)
                || a == address(risk) || a == address(proxyManager)
        ) return true;
        if (
            registry.integrationIdOf(a) != 0 || a == registry.payoutEscrow() || a == registry.flashSourceAddr()
                || registry.isRecordedHub(a) || registry.getSpoke(a).approved
        ) return true;
        IAaveV4Hub hub = IAaveV4Hub(aave.hub);
        return hub.isSpokeListed(ghoAssetId, a) || hub.isUnderlyingListed(a);
    }

    // ─── Withdrawal units (REQ-PROXY-082) ───

    // TEST-018 verifies: REQ-PROXY-038, REQ-PROXY-082, REQ-ADAPTER-005
    /// @notice A withdrawal succeeds exactly with the record's credited units; any other count reverts and nothing
    /// moves.
    function testFuzz_TEST_018_withdrawNeedsExactUnits(
        uint256 unitsSeed,
        uint256 askSeed
    ) public {
        uint128 units = uint128(bound(unitsSeed, 1, 1e12));
        (bytes32 k, address p) = _pledgeAs(alice, MARKET_ID, units);
        uint256 ask = bound(askSeed, 1, uint256(units) * 2);
        uint256 d = _deadline();
        if (ask != units) vm.expectRevert();
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k), ask, d, 0);
        if (ask == units) {
            assertEq(lpVault.ownerOf(k), alice, "returned");
            assertEq(token.totalSupply(), 0, "burned");
        } else {
            assertEq(_sharesOf(p, vtReserveId), units, "unchanged");
        }
    }
}
