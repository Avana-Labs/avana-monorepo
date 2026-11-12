// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

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
    function test_collateralExhaustedDeficitRecorded() public {
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
    function test_nothingLeftToSeize() public {
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
    function testFuzz_collapseSettlesEveryCall(
        uint256 price8
    ) public {
        price8 = bound(price8, 80_000_000, 180_000_000);
        uint256 deficitBefore = _deficit();
        _seizeEverything(price8);
        assertTrue(_suppliedUnits(proxy) == 0 || _hf(proxy) >= 1e18, "exhausted or restored");
        assertGe(_deficit(), deficitBefore, "the deficit never falls through a liquidation");
        assertEq(usdc.balanceOf(address(lvs)), 0, "LPVaultSwap neutral");
    }

    /// @notice A zero repayment is refused `InvalidAmount` even on an insolvent account.
    // TEST-055 verifies: REQ-SWAP-030, REQ-SWAP-077
    function test_zeroRepaymentRefused() public {
        lpOracle.setAnswer(100_000_000);
        _expectLiquidateRevert(keeper, _params(proxy, 0), _err(ILPVaultSwapErrors.InvalidAmount.selector));
    }
}
