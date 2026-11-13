// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

interface ILVSDriftConfigurator {
    function updateLiquidationFee(
        address spoke,
        uint256 reserveId,
        uint32 dynamicConfigKey,
        uint256 liquidationFee
    ) external;

    function updateReceiveSharesEnabled(
        address spoke,
        uint256 reserveId,
        bool receiveSharesEnabled
    ) external;

    function updateBorrowable(
        address spoke,
        uint256 reserveId,
        bool borrowable
    ) external;
}

/// @title LPVaultSwapOpenUnderHaltsUnitTest
/// @notice LPVaultSwap's liquidation and pending settlement under Avana's pause states (5.1 TEST-192) and under each
/// drift of the standard CDP Spoke settings the Aave DAO executor can make (5.1 TEST-268), on the real local Aave V4,
/// the real LPVaultSwap, Collateralization and vault token.
/// forge-config: default.isolate = false
contract LPVaultSwapOpenUnderHaltsUnitTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @notice In None, Frozen, Paused(General) and Paused(MintPathSuspect) a liquidation settles and `settlePending`
    /// clears the pending balance: neither reads the pause state.
    // TEST-192 verifies: REQ-ACCESS-068, REQ-SWAP-065, INV-045
    function test_TEST_192_liquidationAndPendingOpenInEveryPauseState() public {
        uint8[2][4] memory cells = [[uint8(0), 0], [uint8(1), 0], [uint8(2), 1], [uint8(2), 2]];
        for (uint256 i = 0; i < cells.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            registry.setPause(cells[i][0], cells[i][1]);
            _seizeAndKeep(proxy, 1000e6);
            LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 500e6));
            assertGt(r.unitsSeized, 0, "liquidated");
            assertGt(coll.getPending(address(vt)).units, 0, "pending balance");
            vm.prank(makeAddr("anyone"));
            lvs.settlePending(MARKET_ID, usdcReserveId);
            assertEq(coll.getPending(address(vt)).units, 0, "pending settled");
            vm.revertToState(snapshot);
        }
    }

    /// @notice Before any change, `liquidationCall` with `receiveShares = true` reverts on the Avana reserve. Then, for
    /// each standard setting the DAO executor turns (`receiveSharesEnabled = true`, a 10 % liquidation fee, `borrowable
    /// = true`), a third party's `liquidationCall(…, false)` seizing at least one unit still reverts on the vault-token
    /// transfer, one sized so its seizure rounds to zero shares moves no vault token and takes no collateral while it
    /// repays part of the debt at the caller's expense, and LPVaultSwap's liquidation still settles.
    // TEST-268 verifies: REQ-SWAP-084, INV-013, Q-362
    function test_TEST_268_liquidationSettlesUnderEachSettingDrift() public {
        usdc.mint(attacker, 1_000_000e6);
        vm.prank(attacker);
        usdc.approve(aave.cdpSpoke, type(uint256).max);
        vm.prank(attacker);
        vm.expectRevert();
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, usdcReserveId, proxy, 1950e6, true);

        for (uint256 i = 0; i < 3; ++i) {
            uint256 snapshot = vm.snapshotState();
            _drift(i);

            vm.prank(attacker);
            vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, aave.hub, attacker));
            IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, usdcReserveId, proxy, 1950e6, false);

            uint256 supply = vt.totalSupply();
            uint256 debt = _debtOf(proxy, usdcReserveId);
            uint256 attackerUsdc = usdc.balanceOf(attacker);
            vm.prank(attacker);
            IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, usdcReserveId, proxy, 1, false);
            assertEq(vt.balanceOf(attacker), 0, "no vault token to the caller");
            assertEq(vt.totalSupply(), supply, "no vault token moved out of the Hub");
            assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, attacker), 0, "no collateral taken");
            assertLt(_debtOf(proxy, usdcReserveId), debt, "part of the debt repaid");
            assertLt(usdc.balanceOf(attacker), attackerUsdc, "at the caller's expense");

            LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
            assertGt(r.unitsSeized, 0, "LPVaultSwap still liquidates");
            vm.revertToState(snapshot);
        }
    }

    function _drift(
        uint256 i
    ) internal {
        ILVSDriftConfigurator cfg = ILVSDriftConfigurator(aave.spokeConfigurator);
        vm.startPrank(aaveDao);
        if (i == 0) {
            cfg.updateReceiveSharesEnabled(aave.cdpSpoke, vtReserveId, true);
        } else if (i == 1) {
            uint32 key = IAaveV4Spoke(aave.cdpSpoke).getUserPosition(vtReserveId, proxy).dynamicConfigKey;
            cfg.updateLiquidationFee(aave.cdpSpoke, vtReserveId, key, 1000);
        } else {
            cfg.updateBorrowable(aave.cdpSpoke, vtReserveId, true);
        }
        vm.stopPrank();
    }
}
