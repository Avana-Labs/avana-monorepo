// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "../../src/custody/collateralization/ICollateralizationAdapter.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";

/// @dev The SpokeConfigurator call that adds a dynamic configuration key with a new collateral factor (aave-v4 a3ef63e).
interface IExampleSpokeConfigurator {
    function addCollateralFactor(
        address spoke,
        uint256 reserveId,
        uint16 collateralFactor
    ) external returns (uint32);
}

/// @title AaveAdapterExamplesUnitTest
/// @notice The worked examples of 2.6 on the real Aave V4 Spoke, with their exact numbers: the non-GHO borrow table
/// (market A, $50,000 at `CF = 3,120`), the two-reserve account (market B, $82,000 at `CF = 3,000`, 8,000 GHO and
/// USDC at $0.9999), the post-action health gate (SPEC-PROXY-001), the multi-reserve health factor (SPEC-PROXY-006), the
/// backing gap (SPEC-PROXY-008) and the repay rules whose figures depend on Aave's interest model (REQ-ADAPTER-071,
/// REQ-PROXY-083), which are asserted as relations.
/// @dev The fixture lists both vault-token reserves at `CF = 8,000`; each example first adds the example's collateral
/// factor as a new dynamic key, which the account's first pledge (enabling the reserve as collateral) takes.
/// forge-config: default.isolate = false
contract AaveAdapterExamplesUnitTest is AaveAdapterFixture {
    uint128 internal constant L_A = 25_000_000_000; // $50,000 at $2.00 per whole token
    uint128 internal constant L_B_HALF = 20_500_000_000; // records #12 and #13: $82,000 together

    function _setCf(
        uint256 reserveId,
        uint16 cf
    ) internal {
        vm.prank(aaveDao);
        IExampleSpokeConfigurator(aave.spokeConfigurator).addCollateralFactor(aave.cdpSpoke, reserveId, cf);
    }

    function _borrowTo(
        address wallet,
        uint256 marketId,
        uint256 reserveId,
        uint256 amount,
        uint256 minHf
    ) internal returns (uint256) {
        address proxy = adapterC.proxyOf(wallet, marketId);
        uint256 nonce = adapterC.borrowNonce(proxy);
        uint256 d = _deadline();
        vm.prank(wallet);
        return adapterC.borrow(marketId, reserveId, amount, wallet, d, minHf, nonce);
    }

    function _twoReserveAccount() internal returns (address proxy, bytes32 k12, bytes32 k13) {
        _setCf(vtReserveIdB, 3000);
        (k12, proxy) = _pledgeAs(alice, MARKET_B, L_B_HALF);
        (k13,) = _pledgeAs(alice, MARKET_B, L_B_HALF);
        _borrowTo(alice, MARKET_B, debtReserveId, 8000e18, 0);
    }

    // ─── Non-GHO borrow (market A) ───

    // TEST-027 verifies: REQ-PROXY-015, REQ-PROXY-024, SPEC-PROXY-001, SPEC-PROXY-006, SPEC-PROXY-004
    // Sources: 2.6 worked example "Non-GHO borrow", first row
    /// @notice `borrow(m_A, r_USDC, 10,000,000,000, W, t+600, 1.50e18, 4)` on $15,600 of CF-weighted collateral:
    /// `hf = floor(15,600 / 9,999 × 10^18) = 1,560,156,015,601,560,156`, the USDC reaches `W` through the proxy, nonce 4
    /// is consumed.
    function test_TEST_027_nonGhoBorrowExample() public {
        _setCf(vtReserveId, 3120);
        (, address proxy) = _pledgeAs(alice, MARKET_ID, L_A);
        // Four earlier borrows of one GHO wei each, repaid, bring the nonce to 4 as in the example.
        for (uint256 i = 0; i < 4; ++i) {
            _borrowTo(alice, MARKET_ID, debtReserveId, 1, 0);
        }
        _fund(alice, debtReserveId, 1e18);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 1e18, true, _deadline());
        assertEq(adapterC.borrowNonce(proxy), 4, "nonce 4");
        uint256 before = usdcDebt.balanceOf(alice);
        uint256 d = _deadline();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 10_000_000_000, alice, d, 1.5e18, 4);
        assertEq(_hf(proxy), 1_560_156_015_601_560_156, "hf of the example");
        assertEq(usdcDebt.balanceOf(alice) - before, 10_000_000_000, "10,000 USDC to W");
        assertEq(usdcDebt.balanceOf(proxy), 0, "proxy forwards everything");
        assertEq(adapterC.borrowNonce(proxy), 5, "borrowNonce = 5");
    }

    // TEST-278 verifies: REQ-PROXY-016, Q-381
    // Sources: 2.6 worked example "Non-GHO borrow", second row
    /// @notice The same call with 50 USDC passes: there is no minimum debt.
    function test_TEST_278_fiftyUsdcExample() public {
        _setCf(vtReserveId, 3120);
        _pledgeAs(alice, MARKET_ID, L_A);
        _borrowTo(alice, MARKET_ID, usdcReserveId, 50e6, 1.5e18);
        assertEq(usdcDebt.balanceOf(alice), 50e6, "50 USDC");
    }

    // TEST-027 verifies: REQ-PROXY-022, SPEC-PROXY-001, REQ-PROXY-067
    // Sources: 2.6 worked example "Non-GHO borrow", protocol maximum and recommended borrow
    /// @notice The recommended borrow at `hf = 1.10`: 14,183.23 USDC passes with `minHealthFactor = 1.10e18` and 14,183.24
    /// reverts `HealthFactorTooLow`; the protocol maximum at Aave's 1.00 is 15,601.56 USDC (15,601.57 is refused by
    /// Aave).
    function test_TEST_027_recommendedAndMaximumBorrow() public {
        _setCf(vtReserveId, 3120);
        (, address proxy) = _pledgeAs(alice, MARKET_ID, L_A);
        uint256 snap = vm.snapshotState();
        uint256 d = _deadline();
        uint256 hfAbove = uint256(15_600e26) * 1e18 / (14_183_240_000 * 99_990_000 * 1e12);
        // Aave's own value: the account's health factor right after the borrow, floored.
        vm.expectRevert();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 14_183_240_000, alice, d, 1.1e18, 0);
        assertLt(hfAbove, 1.1e18, "14,183.24 ends below 1.10");
        _borrowTo(alice, MARKET_ID, usdcReserveId, 14_183_230_000, 1.1e18);
        assertGe(_hf(proxy), 1.1e18, "14,183.23 ends at or above 1.10");
        vm.revertToState(snap);
        _borrowTo(alice, MARKET_ID, usdcReserveId, 15_601_560_000, 0);
        assertGe(_hf(proxy), 1e18, "protocol maximum at 1.00");
        vm.revertToState(snap);
        vm.expectRevert(bytes4(keccak256("HealthFactorBelowThreshold()")));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 15_601_570_000, alice, d, 0, 0);
    }

    // TEST-027 verifies: REQ-PROXY-017, REQ-PROXY-061
    // Sources: 2.6 worked example "Non-GHO borrow", receiver row
    /// @notice The same call with `receiver` = the USDC token reverts `InvalidReceiver(USDC)`; the nonce is unchanged.
    function test_TEST_027_receiverIsTokenExample() public {
        _setCf(vtReserveId, 3120);
        (, address proxy) = _pledgeAs(alice, MARKET_ID, L_A);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.InvalidReceiver.selector, address(usdcDebt)));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 10_000_000_000, address(usdcDebt), d, 1.5e18, 0);
        assertEq(adapterC.borrowNonce(proxy), 0, "nonce unchanged");
    }

    // ─── Two-reserve account (market B) ───

    // TEST-203 verifies: SPEC-PROXY-006, REQ-PROXY-018, REQ-ADAPTER-066
    // Sources: 2.6 worked example "Two-reserve account", rows 1-3; SPEC-PROXY-006 example
    /// @notice $82,000 at `CF = 3,000` gives $24,600; after 8,000 GHO `hf = 3,075,000,000,000,000,000`; after 5,000 USDC
    /// at $0.9999 `hf = floor(24,600 / 12,999.5 × 10^18) = 1,892,380,476,172,160,467`. Market A's account of the same
    /// wallet is untouched.
    function test_TEST_203_twoReserveHealthFactor() public {
        (, address pA) = _pledgeAs(alice, MARKET_ID, UNITS);
        uint256 hfA = _hf(pA);
        (address pB,,) = _twoReserveAccount();
        assertTrue(pA != pB, "second proxy for market B");
        assertEq(_hf(pB), 3_075_000_000_000_000_000, "after GHO");
        _borrowTo(alice, MARKET_B, usdcReserveId, 5_000_000_000, 0);
        assertEq(_hf(pB), 1_892_380_476_172_160_467, "after USDC");
        assertEq(_hf(pA), hfA, "market A account untouched");
    }

    // TEST-027 verifies: SPEC-PROXY-001, REQ-PROXY-022, REQ-PROXY-067, REQ-PROXY-015
    // Sources: 2.6 SPEC-PROXY-001 example, "Two-reserve account" row 4
    /// @notice A further 15,000 USDC with `minHealthFactor = 1.10e18` gives `hf = 1,069,634,976,194,099,615` and reverts
    /// `HealthFactorTooLow(1,069,634,976,194,099,615, 1.1e18)`; the USDC transfer to the receiver is undone.
    function test_TEST_027_healthGateExample() public {
        (address pB,,) = _twoReserveAccount();
        uint256 d = _deadline();
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 1_069_634_976_194_099_615, 1.1e18)
        );
        vm.prank(alice);
        adapterC.borrow(MARKET_B, usdcReserveId, 15_000_000_000, alice, d, 1.1e18, 1);
        assertEq(usdcDebt.balanceOf(alice), 0, "transfer undone");
        assertEq(_debtOf(pB, usdcReserveId), 0, "no USDC debt");
        assertEq(adapterC.borrowNonce(pB), 1, "nonce unchanged");
    }

    // TEST-203 verifies: REQ-ADAPTER-071, REQ-PROXY-071, REQ-ADAPTER-085, SPEC-PROXY-007
    // Sources: 2.6 worked example "Two-reserve account", rows 7-8; REQ-ADAPTER-071 example
    /// @notice After 30 days, naming only `r_GHO` (cap 8,040 GHO) reverts `DebtRemaining(r_USDC, d)` with `d` the live
    /// USDC debt and moves nothing; naming both with caps `[8,040e18, 5,030e6]` repays each, refunds `cap − live debt`
    /// of each to `W`, and returns record #12 debt-free. The example's 5,024,657,535 assumes a 6.00% USDC rate; the
    /// fixture's rate model differs, so the test asserts the relation.
    function test_TEST_203_repayAllAndWithdrawExample() public {
        (address pB, bytes32 k12,) = _twoReserveAccount();
        _borrowTo(alice, MARKET_B, usdcReserveId, 5_000_000_000, 0);
        vm.warp(block.timestamp + 30 days);
        uint256 g = _debtOf(pB, debtReserveId);
        uint256 u = _debtOf(pB, usdcReserveId);
        assertGt(u, 5_000_000_000, "USDC interest accrued");
        _fund(alice, debtReserveId, 8040e18);
        _fund(alice, usdcReserveId, 5030e6);
        uint256 ghoBefore = debt.balanceOf(alice);
        uint256 usdcBefore = usdcDebt.balanceOf(alice);
        uint256[] memory onlyGho = new uint256[](1);
        onlyGho[0] = debtReserveId;
        uint256[] memory onlyGhoCap = new uint256[](1);
        onlyGhoCap[0] = 8040e18;
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DebtRemaining.selector, usdcReserveId, u));
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_B, _ref(k12), L_B_HALF, onlyGho, onlyGhoCap, d);
        assertEq(debt.balanceOf(alice), ghoBefore, "nothing moved");
        uint256[] memory ids = new uint256[](2);
        ids[0] = debtReserveId;
        ids[1] = usdcReserveId;
        uint256[] memory caps = new uint256[](2);
        caps[0] = 8040e18;
        caps[1] = 5030e6;
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_B, _ref(k12), L_B_HALF, ids, caps, d);
        assertEq(ghoBefore - debt.balanceOf(alice), g, "Aave took the GHO debt");
        assertEq(usdcBefore - usdcDebt.balanceOf(alice), u, "Aave took the USDC debt");
        assertEq(debt.allowance(alice, adapter) + usdcDebt.allowance(alice, adapter), 0, "allowances 0");
        assertEq(_borrowCountOf(pB), 0, "debt-free");
        assertEq(lpVault.ownerOf(k12), alice, "position #12 to W");
    }

    // TEST-175 verifies: REQ-PROXY-083, REQ-ADAPTER-085, REQ-PROXY-069
    // Sources: 2.6 REQ-PROXY-083 example
    /// @notice A rescue service's partial repay of 2,000 USDC lands before the borrower's repay-all with cap 5,030e6:
    /// the borrower's call pulls the whole cap, Aave takes the remaining live debt and `cap − remaining` returns to the
    /// borrower; had the service repaid everything, the borrower's call returns 0 and moves nothing.
    function test_TEST_175_concurrentPayersExample() public {
        (address pB,,) = _twoReserveAccount();
        _borrowTo(alice, MARKET_B, usdcReserveId, 5_000_000_000, 0);
        vm.warp(block.timestamp + 30 days);
        address service = makeAddr("rescueService");
        _fund(service, usdcReserveId, 2000e6);
        uint256 d = _deadline();
        vm.prank(service);
        adapterC.repay(alice, MARKET_B, usdcReserveId, 2000e6, false, d);
        uint256 remaining = _debtOf(pB, usdcReserveId);
        uint256 snap = vm.snapshotState();
        _fund(alice, usdcReserveId, 5030e6);
        uint256 before = usdcDebt.balanceOf(alice);
        vm.prank(alice);
        uint256 spent = adapterC.repay(alice, MARKET_B, usdcReserveId, 5030e6, true, d);
        assertEq(spent, remaining, "Aave took the remaining debt");
        assertEq(usdcDebt.balanceOf(alice), before - remaining, "refund of cap - remaining");
        assertEq(_debtOf(pB, usdcReserveId), 0, "cleared");
        vm.revertToState(snap);
        _fund(service, usdcReserveId, remaining);
        vm.prank(service);
        adapterC.repay(alice, MARKET_B, usdcReserveId, remaining, true, d);
        _fund(alice, usdcReserveId, 5030e6);
        uint256 held = usdcDebt.balanceOf(alice);
        vm.prank(alice);
        assertEq(adapterC.repay(alice, MARKET_B, usdcReserveId, 5030e6, true, d), 0, "nothing left to repay");
        assertEq(usdcDebt.balanceOf(alice), held, "nothing pulled");
        assertEq(usdcDebt.allowance(alice, adapter), 5030e6, "allowance untouched");
    }

    // ─── Backing gap (SPEC-PROXY-008) ───

    // TEST-241 verifies: SPEC-PROXY-008, REQ-ADAPTER-069, REQ-ADAPTER-075, INV-080
    // Sources: 2.6 SPEC-PROXY-008 example
    /// @notice A faulty seizure burned 1,575,000,000 units without debiting them: `G = 1,575,000,000`. A pledge crediting
    /// 50,000,000,000 units keeps `G`; a mint of 50,000,000,001 against a credit of nothing reverts `BackingMismatch`.
    function test_TEST_241_gapExample() public {
        (, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowTo(alice, MARKET_ID, debtReserveId, 15_000e18, 0);
        vtPrice.set(1.2e8);
        uint256 seized = swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, p, 10_000e18);
        assertGe(seized, 1_575_000_000, "enough seized units");
        swap.burnUnderLock(MARKET_ID, vt, 1_575_000_000);
        vtPrice.set(2e8);
        assertEq(_gap(), 1_575_000_000, "G");
        _pledgeAs(bob, MARKET_ID, 50_000_000_000);
        assertEq(_gap(), 1_575_000_000, "pledge keeps G");
        bytes32 key = _newKey();
        lpVault.mintPosition(key, carol, MARKET_ID, 50_000_000_001);
        vm.mockCall(
            address(coll),
            abi.encodeWithSelector(ICollateralizationAdapter.pledge.selector),
            abi.encode(uint256(99), uint128(50_000_000_001))
        );
        uint256 supplyAfter = token.totalSupply() + 50_000_000_001;
        uint256 credited = coll.getTotalCredited(vt);
        uint256 pending = coll.getPending(vt).units;
        uint256 d = _deadline();
        vm.expectRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.BackingMismatch.selector, supplyAfter, credited, pending)
        );
        vm.prank(carol);
        adapterC.pledge(MARKET_ID, _ref(key), d);
    }
}
