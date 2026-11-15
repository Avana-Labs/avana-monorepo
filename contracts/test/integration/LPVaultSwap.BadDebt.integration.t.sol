// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A First-Loss Reserve stand-in whose `fund` always reverts.
contract RevertingReserve {
    function fund(
        uint256
    ) external pure returns (uint256) {
        revert("fund");
    }
}

/// @dev A First-Loss Reserve stand-in that takes the amount it is funded with, then returns a 2 MiB buffer: copying it
/// would cost the caller about 8.8M gas of memory expansion.
contract HugeReturnReserve {
    IERC20 internal immutable ASSET;

    constructor(
        IERC20 asset
    ) {
        ASSET = asset;
    }

    function fund(
        uint256 amount
    ) external returns (uint256) {
        require(ASSET.transferFrom(msg.sender, address(this), amount), "pull");
        // solhint-disable-next-line no-inline-assembly
        assembly {
            return(0, 0x200000)
        }
    }
}

/// @title LPVaultSwapBadDebtIntegrationTest
/// @notice An account whose collateral is worth less than its debt, on the local Aave V4 (2.11 SPEC-LIQ-005,
/// SPEC-LIQ-010, REQ-SWAP-121, INV-076; 2.14 deficit reporting): LPVaultSwap seizes every unit in calls sized by the
/// keeper, each settling at the oracle floor with the caller bearing any rounding gap; once no collateral remains the
/// Hub records the leftover debt as the Spoke's deficit, Collateralization's credit is zero, and LPVaultSwap refuses
/// a further liquidation with `NothingSeized` or Aave's own refusal without moving funds.
/// forge-config: default.isolate = false
contract LPVaultSwapBadDebtIntegrationTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @dev Records `reserve` as the USDC debt reserve's First-Loss Reserve, as the MarketRegistry's record would.
    function _recordReserve(
        address reserve
    ) internal {
        DebtReserveDef memory d = registry.getDebtReserve(aave.cdpSpoke, usdcReserveId);
        d.firstLossReserve = reserve;
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, d, true);
    }

    function _ghoDeficit() internal view returns (uint256) {
        return IAaveV4Hub(aave.hub).getSpokeDeficitRay(ghoAssetId, aave.cdpSpoke);
    }

    function _deficit() internal view returns (uint256) {
        return IAaveV4Hub(aave.hub).getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke);
    }

    function _seizeEverything(
        uint256 price8
    ) internal returns (uint256 calls) {
        lpOracle.setAnswer(int256(price8));
        for (uint256 i = 0; i < 30 && _suppliedUnits(proxy) != 0; ++i) {
            uint256 debt = _debtOf(proxy, usdcReserveId);
            LiquidationParams memory p = _params(proxy, debt);
            p.maxShortfall = debt / 5;
            LiquidationResult memory r = _liquidateAs(keeper, p);
            assertEq(
                r.callerFunds + r.recovered + r.shortfall, r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut
            );
            assertGe(r.recovered + r.shortfall, r.minOut, "floor met");
            ++calls;
        }
    }

    /// @notice At $1.00 Bob's 10,000 units are worth 10,000 USDC against 18,000 USDC of debt: every unit is seized,
    /// the Spoke's USDC deficit rises, Collateralization credits nothing and LPVaultSwap holds nothing.
    // TEST-216 verifies: SPEC-LIQ-005, SPEC-LIQ-010, REQ-SWAP-121, INV-076
    function test_TEST_216_collateralExhaustedDeficitRecorded() public {
        uint256 deficitBefore = _deficit();
        uint256 calls = _seizeEverything(100_000_000);
        assertGt(calls, 0, "liquidated");
        assertEq(_suppliedUnits(proxy), 0, "every unit seized");
        assertEq(coll.getAccountCredited(proxy, address(vt)), 0, "no credit left");
        assertGt(_deficit(), deficitBefore, "the leftover debt became the Spoke's deficit");
        assertEq(vt.balanceOf(address(lvs)), 0, "no vault tokens kept");
        assertEq(usdc.balanceOf(address(lvs)), 0, "no USDC kept");
    }

    /// @notice After the collateral is gone, a further liquidation is refused before any funds move.
    // TEST-216 verifies: REQ-SWAP-077, REQ-SWAP-121
    function test_TEST_216_nothingLeftToSeize() public {
        _seizeEverything(100_000_000);
        uint256 callerBefore = usdc.balanceOf(keeper);
        _fund(usdc, keeper, 100e6);
        vm.prank(keeper);
        (bool ok,) = address(lvs).call(abi.encodeCall(lvs.liquidate, (_params(proxy, 100e6))));
        assertFalse(ok, "refused");
        assertEq(usdc.balanceOf(keeper), callerBefore + 100e6, "the caller keeps its funding");
    }

    /// @notice Any collapse price from $0.80 to $1.80: every call conserves the debt asset and meets its floor, the
    /// account ends with no collateral or restored, and the deficit never falls.
    // TEST-216 verifies: SPEC-LIQ-010, INV-035, INV-076
    function testFuzz_TEST_216_collapseSettlesEveryCall(
        uint256 price8
    ) public {
        price8 = bound(price8, 80_000_000, 180_000_000);
        uint256 deficitBefore = _deficit();
        _seizeEverything(price8);
        assertTrue(_suppliedUnits(proxy) == 0 || _hf(proxy) >= 1e18, "exhausted or restored");
        assertGe(_deficit(), deficitBefore, "the deficit never falls through a liquidation");
        assertEq(usdc.balanceOf(address(lvs)), 0, "LPVaultSwap neutral");
    }

    /// @notice Audit finding L-01 (fresh audit 2026-11-15): on the call that seizes the last unit and books the leftover
    /// debt as the Hub's deficit, the borrower surplus `B` funds the First-Loss Reserve of the debt asset's funding Hub
    /// instead of going to the defaulted borrower, so the reserve that covers the deficit keeps those proceeds.
    // TEST-216 verifies: SPEC-LIQ-022, REQ-SWAP-027
    function test_TEST_216_deficitSurplusFundsTheFirstLossReserve() public {
        lpOracle.setAnswer(int256(100_000_000));
        uint256 deficitSurplus = 0;
        for (uint256 i = 0; i < 30 && _suppliedUnits(proxy) != 0; ++i) {
            uint256 debt = _debtOf(proxy, usdcReserveId);
            LiquidationParams memory p = _params(proxy, debt);
            p.maxShortfall = debt / 5;
            uint256 deficitBefore = _deficit();
            uint256 walletBefore = usdc.balanceOf(bob) + escrow.claimable(address(usdc), bob);
            uint256 reserveBefore = usdcCoverage.fundedBalance();
            LiquidationResult memory r = _liquidateAs(keeper, p);
            if (_deficit() > deficitBefore) {
                assertEq(_suppliedUnits(proxy), 0, "a deficit is booked only once the collateral is gone");
                assertEq(
                    usdc.balanceOf(bob) + escrow.claimable(address(usdc), bob), walletBefore, "borrower paid nothing"
                );
                assertEq(usdcCoverage.fundedBalance(), reserveBefore + r.borrowerSurplus, "surplus funded the reserve");
                assertEq(usdc.allowance(address(lvs), address(usdcCoverage)), 0, "reserve allowance reset");
                assertEq(usdc.balanceOf(address(lvs)), 0, "LPVaultSwap holds no USDC");
                deficitSurplus += r.borrowerSurplus;
            } else {
                assertEq(usdcCoverage.fundedBalance(), reserveBefore, "no deficit, reserve untouched");
            }
        }
        assertGt(deficitSurplus, 0, "the deficit call carried a borrower surplus");
    }

    /// @notice A reserve that cannot take the surplus never blocks the settlement: with a recorded reserve that holds
    /// no code (its `fund` moves nothing and returns no data), the deficit call settles and pays `B` to the borrower.
    // TEST-216 verifies: SPEC-LIQ-022, REQ-SWAP-027
    function test_TEST_216_unusableReserveLeavesTheSurplusWithTheBorrower() public {
        _surplusStaysWithTheBorrower(makeAddr("codelessReserve"));
    }

    /// @notice The same with a recorded reserve whose `fund` reverts: the deficit call settles and pays `B` to the
    /// borrower.
    // TEST-216 verifies: SPEC-LIQ-022, REQ-SWAP-027
    function test_TEST_216_revertingReserveLeavesTheSurplusWithTheBorrower() public {
        _surplusStaysWithTheBorrower(address(new RevertingReserve()));
    }

    function _surplusStaysWithTheBorrower(
        address reserve
    ) internal {
        _recordReserve(reserve);
        lpOracle.setAnswer(int256(100_000_000));
        uint256 deficitSurplus = 0;
        for (uint256 i = 0; i < 30 && _suppliedUnits(proxy) != 0; ++i) {
            uint256 debt = _debtOf(proxy, usdcReserveId);
            LiquidationParams memory p = _params(proxy, debt);
            p.maxShortfall = debt / 5;
            uint256 deficitBefore = _deficit();
            uint256 walletBefore = usdc.balanceOf(bob) + escrow.claimable(address(usdc), bob);
            LiquidationResult memory r = _liquidateAs(keeper, p);
            assertEq(
                usdc.balanceOf(bob) + escrow.claimable(address(usdc), bob),
                walletBefore + r.borrowerSurplus,
                "borrower paid B"
            );
            if (_deficit() > deficitBefore) deficitSurplus += r.borrowerSurplus;
        }
        assertGt(deficitSurplus, 0, "the deficit call carried a borrower surplus");
        assertEq(usdc.balanceOf(address(lvs)), 0, "LPVaultSwap neutral");
    }

    /// @notice A reserve that returns a huge buffer cannot make the deficit call revert: LPVaultSwap copies no return
    /// data beyond the 32-byte shares word from `fund`, so each call settles within 16M gas, which the reserve's own
    /// 8.6M of memory, a liquidation and a 2 MiB copy (about 8.8M more) together would exceed, unoptimized builds included.
    // TEST-216 verifies: SPEC-LIQ-022, REQ-SWAP-027
    function test_TEST_216_hugeReserveReturnDoesNotBlockTheSettlement() public {
        HugeReturnReserve reserve = new HugeReturnReserve(IERC20(address(usdc)));
        _recordReserve(address(reserve));
        lpOracle.setAnswer(int256(100_000_000));
        uint256 funded = 0;
        for (uint256 i = 0; i < 30 && _suppliedUnits(proxy) != 0; ++i) {
            uint256 debt = _debtOf(proxy, usdcReserveId);
            LiquidationParams memory p = _params(proxy, debt);
            p.maxShortfall = debt / 5;
            uint256 deficitBefore = _deficit();
            uint256 heldBefore = usdc.balanceOf(address(reserve));
            usdc.mint(keeper, p.debtToCover + p.maxShortfall);
            vm.startPrank(keeper);
            usdc.approve(address(lvs), p.debtToCover + p.maxShortfall);
            LiquidationResult memory r = lvs.liquidate{gas: 16_000_000}(p);
            vm.stopPrank();
            if (_deficit() > deficitBefore) {
                assertEq(usdc.balanceOf(address(reserve)), heldBefore + r.borrowerSurplus, "reserve took B");
                funded += r.borrowerSurplus;
            }
        }
        assertGt(funded, 0, "the deficit call funded the reserve");
    }

    /// @notice An account owing USDC and GHO whose last collateral a USDC liquidation seizes while repaying all of the
    /// USDC: Aave books the GHO as deficit and the USDC deficit does not move, and `B` still funds the USDC First-Loss
    /// Reserve rather than the borrower (re-review of audit finding L-01). The borrower reaches this state by sizing
    /// the USDC debt to the collateral at the bonus; the test finds that size by adjusting the USDC borrow until the
    /// call empties both the collateral and the USDC debt.
    // TEST-216 verifies: SPEC-LIQ-022, REQ-SWAP-027
    function test_TEST_216_otherDebtDeficitFundsTheRepaidAssetReserve() public {
        uint256 snap = vm.snapshotState();
        uint256 d = 9523e6;
        bool found;
        for (uint256 i = 0; i < 16 && !found; ++i) {
            vm.revertToState(snap);
            (found, d) = _twoDebtAttempt(makeAddr("carol"), d);
        }
        assertTrue(found, "a call emptied the collateral and the USDC debt together");
    }

    /// @dev Bob's state with `d` of USDC and 9,000 GHO at $1 a unit, then one USDC liquidation of the whole USDC debt.
    /// Returns whether it emptied both the collateral and the USDC debt (asserting the funding if so), else the next
    /// USDC borrow to try.
    function _twoDebtAttempt(
        address carol,
        uint256 d
    ) internal returns (bool found, uint256 next) {
        (address p,) = _openAccount(carol, 10_000e6, d, 250_000_000);
        lpOracle.setAnswer(250_000_000);
        adapter.borrow(p, ghoReserveId, address(gho), 9000e18, carol);
        lpOracle.setAnswer(100_000_000);
        uint256[4] memory s0 = [
            _deficit(),
            _ghoDeficit(),
            usdc.balanceOf(carol) + escrow.claimable(address(usdc), carol),
            usdcCoverage.fundedBalance()
        ];
        LiquidationParams memory lp = _params(p, _debtOf(p, usdcReserveId));
        lp.maxShortfall = lp.debtToCover / 5;
        LiquidationResult memory r = _liquidateAs(keeper, lp);
        uint256 left = _suppliedUnits(p);
        uint256 usdcRise = _deficit() - s0[0];
        // Collateral left over: the USDC debt was below the collateral at the bonus (10,500, $1 a unit).
        if (left != 0) return (false, d + left * 10_000 / 10_500 + 1);
        // USDC debt left over and booked as deficit: the USDC debt was above it.
        if (usdcRise != 0) return (false, d - usdcRise / 1e27 - 1);
        assertGt(_ghoDeficit(), s0[1], "the GHO debt became the deficit");
        assertGt(r.borrowerSurplus, 0, "the call carried a borrower surplus");
        assertEq(usdc.balanceOf(carol) + escrow.claimable(address(usdc), carol), s0[2], "borrower paid nothing");
        assertEq(usdcCoverage.fundedBalance(), s0[3] + r.borrowerSurplus, "surplus funded the USDC reserve");
        assertEq(usdc.allowance(address(lvs), address(usdcCoverage)), 0, "reserve allowance reset");
        assertEq(usdc.balanceOf(address(lvs)), 0, "LPVaultSwap holds no USDC");
        return (true, d);
    }

    /// @notice A zero repayment is refused `InvalidAmount` even on an insolvent account.
    // TEST-055 verifies: REQ-SWAP-030, REQ-SWAP-077
    function test_TEST_055_zeroRepaymentRefused() public {
        lpOracle.setAnswer(100_000_000);
        _expectLiquidateRevert(keeper, _params(proxy, 0), _err(ILPVaultSwapErrors.InvalidAmount.selector));
    }
}
