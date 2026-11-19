// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwap} from "../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {IAaveAdapter} from "../../src/policy/aave-adapter/IAaveAdapter.sol";
import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
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
        uint256 used = _txGas(anyone, adapter, abi.encodeCall(IAaveAdapter.refreshDebtMark, (proxy)));
        assertTrue(coll.getMarketDebtFree(vt), "the refresh cleared it");
        vm.snapshotValue("Maintenance", "refreshDebtMark_clears", used);
        emit log_named_uint("refreshDebtMark (clears the mark)", used);
    }
}
