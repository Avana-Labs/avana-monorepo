// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapLiquidation} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {IFlashLiquidator} from "../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {OperatorFlashLiquidator} from "../../src/periphery/flash-liquidator/OperatorFlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {IAaveAdapterUser} from "../../src/policy/aave-adapter/IAaveAdapterUser.sol";
import {IMarketRegistryCreditLines} from "../../src/policy/market-registry/IMarketRegistryCreditLines.sol";
import {GasCalibration} from "../utils/GasCalibration.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MaintenanceGasTest
/// @notice Gas of the keeper's lazy maintenance jobs, and of the operator flash liquidation over a plain `liquidate`,
/// on the real stack (`RealStackFlows`): one market (a real LPOracleCL over the real Uniswap v3 USDC/USDT 0.01 % pool,
/// full range) on the CDP Spoke, with its GHO (fixed price) and USDC (real DebtOracle) debt reserves. Each figure is
/// its own transaction (`isolate = true`, `GasCalibration._txGas`: intrinsic gas included, every account and slot cold
/// at its first access), recorded with `vm.snapshotValue` (group `Maintenance`):
/// - `settlePending_1market`: `LPVaultSwap.settlePending(market, settlementReserve)` by any caller, one block after an
///   honest liquidation reconciled units LPVaultSwap kept from an earlier seizure into pending: the LPOracle poke, the
///   burn through the Adapter, the real unwind through the NonfungiblePositionManager, a real `DexPathRoute` swap of the
///   non-settlement token and the First-Loss Reserve funding.
/// - `refreshDebtMark_clears`: `AaveAdapter.refreshDebtMark(proxy)` for an account whose last debt was repaid while the
///   Spoke's `getUserAccountData` read failed, so the indebted mark was kept; the refresh reads the Spoke and clears it.
/// - `syncDrawCap_raise`: `MarketRegistry.syncDrawCap(cdpSpoke, ghoReserve)` after the Aave DAO raised the Spoke's GHO
///   draw cap: the registry reads the live cap and rewrites the recorded cap and the credit line's sum.
/// - `liquidate_direct_1market` and `flashLiquidate_operator_1market`: the same GHO liquidation of the same account
///   (from the same state, restored between them) by Avana's keeper funding `liquidate` itself, then through an
///   `OperatorFlashLiquidator` whose signer borrows the whole repayment (`F = X`) from the Aave V3 Pool stand-in
///   (`MockAaveV3Pool`, 5 bps); `flashLiquidate_overhead` is their difference.
/// @dev The flash-loan cost of the real Aave V3 Pool is not in the overhead: its stand-in moves the tokens and calls
/// back without the Pool's reserve accounting, so a fork run on the real Pool would add that part.
/// forge-config: default.isolate = true
contract MaintenanceGasTest is RealStackFlows, GasCalibration {
    uint256 internal mA;
    address internal vt;
    address internal anyone = makeAddr("anyone");

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        vt = mkt[mA].vaultToken;
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + BLOCK_TIME);
    }

    /// @dev `wallet` pledges `UNITS` and borrows 5,700 GHO (HF about 1.05); returns its proxy.
    function _edgeAccount(
        address wallet
    ) internal returns (address proxy) {
        (, proxy) = _pledgeAs(wallet, mA, UNITS);
        _borrowAs(wallet, mA, ghoReserveId, 5700e18);
    }

    // TEST-337 verifies: REQ-SWAP-066, TB-053
    /// @notice `settlePending` of a market's pending units, one block after they were reconciled.
    function test_TEST_337_settlePendingGas() public {
        address proxy = _edgeAccount(alice);
        _movePoolTokens(93_000_000);
        // LPVaultSwap keeps the units of a direct seizure, as an earlier non-conforming implementation would have.
        uint256 x = 50e18;
        gho.mint(lpVaultSwap, x);
        vm.startPrank(lpVaultSwap);
        gho.approve(aave.cdpSpoke, x);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(mkt[mA].reserveId, ghoReserveId, proxy, x, false);
        gho.approve(aave.cdpSpoke, 0);
        vm.stopPrank();
        uint256 kept = IERC20(vt).balanceOf(lpVaultSwap);
        assertGt(kept, 0, "LPVaultSwap kept the seized units");
        // The next honest liquidation reconciles them into pending.
        _liquidateAs(keeper, lens.previewLiquidation(proxy, ghoReserveId, block.timestamp + 120).params);
        assertEq(coll.getPending(vt).units, kept, "the kept units moved to pending");
        _nextBlock();
        uint256 reserve = registry.settlementReserve(mA);
        uint256 used = _txGas(anyone, lpVaultSwap, abi.encodeCall(ILPVaultSwapLiquidation.settlePending, (mA, reserve)));
        assertEq(coll.getPending(vt).units, 0, "pending cleared");
        vm.snapshotValue("Maintenance", "settlePending_1market", used);
        emit log_named_uint("settlePending (one market, two-token unwind and one swap)", used);
        assertLt(used, TX_GAS_CAP / 2, "within half the per-transaction gas limit");
    }

    // TEST-337 verifies: REQ-ADAPTER-104, REQ-COLL-040
    /// @notice `refreshDebtMark` clearing the mark of an account whose last debt left while the Spoke read failed.
    function test_TEST_337_refreshDebtMarkGas() public {
        (, address proxy) = _pledgeAs(alice, mA, UNITS);
        _borrowAs(alice, mA, ghoReserveId, 1000e18);
        uint256 owed = _debtOf(proxy, ghoReserveId);
        // The repay's own Spoke read fails, so the mark stays (REQ-COLL-040).
        vm.mockCallRevert(aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.getUserAccountData, (proxy)), "down");
        _repayVia(alice, alice, mA, ghoReserveId, owed + 1e18, true);
        vm.clearMockedCalls();
        assertEq(_debtOf(proxy, ghoReserveId), 0, "debt repaid");
        assertFalse(coll.getMarketDebtFree(vt), "the mark was kept");
        _nextBlock();
        uint256 used = _txGas(anyone, adapter, abi.encodeCall(IAaveAdapterUser.refreshDebtMark, (proxy)));
        assertTrue(coll.getMarketDebtFree(vt), "the refresh cleared it");
        vm.snapshotValue("Maintenance", "refreshDebtMark_clears", used);
        emit log_named_uint("refreshDebtMark (clears the mark)", used);
    }

    // TEST-337 verifies: REQ-CONFIG-081, SPEC-CAP-010
    /// @notice `syncDrawCap` after the Aave DAO raised the CDP Spoke's GHO draw cap.
    function test_TEST_337_syncDrawCapGas() public {
        vm.prank(aaveDao);
        (bool ok,) = aave.hubConfigurator
            .call(
                abi.encodeWithSignature(
                    "updateSpokeDrawCap(address,uint256,address,uint256)",
                    aave.hub,
                    ghoAssetId,
                    aave.cdpSpoke,
                    uint256(DEBT_DRAW_CAP) + 500_000
                )
            );
        assertTrue(ok, "the Aave DAO raised the draw cap");
        _nextBlock();
        uint256 used = _txGas(
            anyone,
            address(registry),
            abi.encodeCall(IMarketRegistryCreditLines.syncDrawCap, (aave.cdpSpoke, ghoReserveId))
        );
        vm.snapshotValue("Maintenance", "syncDrawCap_raise", used);
        emit log_named_uint("syncDrawCap (raised cap)", used);
    }

    // TEST-337 verifies: REQ-HELPER-011, REQ-HELPER-003
    /// @notice The operator flash liquidation over a plain `liquidate` of the same account from the same state.
    function test_TEST_337_flashLiquidateOverheadGas() public {
        address signer = makeAddr("operatorSigner");
        address safe = makeAddr("operatorSafe");
        OperatorFlashLiquidator op = new OperatorFlashLiquidator(
            address(v3Pool), lpVaultSwap, address(registry), address(store), signer, safe, 100
        );
        address proxy = _edgeAccount(bob);
        _movePoolTokens(93_000_000);
        _nextBlock();
        LiquidationParams memory p = lens.previewLiquidation(proxy, ghoReserveId, block.timestamp + 120).params;
        uint256 snap = vm.snapshotState();
        _fundCaller(keeper, p);
        uint256 direct = _txGas(keeper, lpVaultSwap, abi.encodeCall(ILPVaultSwapLiquidation.liquidate, (p)));
        uint256 debtAfter = _debtOf(proxy, ghoReserveId);
        vm.revertToStateAndDelete(snap);
        FlashLiquidationRequest memory q;
        q.params = p;
        q.flashAmount = p.debtToCover;
        q.maxPremium = type(uint128).max;
        uint256 loans = v3Pool.flashLoanCalls();
        uint256 flash = _txGas(signer, address(op), abi.encodeCall(IFlashLiquidator.flashLiquidate, (q)));
        assertEq(v3Pool.flashLoanCalls(), loans + 1, "one Pool loan");
        assertEq(_debtOf(proxy, ghoReserveId), debtAfter, "the same liquidation");
        assertGt(gho.balanceOf(safe), 0, "the payout went to the Safe");
        vm.snapshotValue("Maintenance", "liquidate_direct_1market", direct);
        vm.snapshotValue("Maintenance", "flashLiquidate_operator_1market", flash);
        vm.snapshotValue("Maintenance", "flashLiquidate_overhead", flash - direct);
        emit log_named_uint("liquidate (keeper funds it)", direct);
        emit log_named_uint("OperatorFlashLiquidator.flashLiquidate (F = X)", flash);
        emit log_named_uint("flash overhead", flash - direct);
    }
}
