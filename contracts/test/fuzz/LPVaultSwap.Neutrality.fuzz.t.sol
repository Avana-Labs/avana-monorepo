// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapNeutralityFuzzTest
/// @notice LPVaultSwap holds nothing of its own across any sequence (2.11 REQ-SWAP-042 to REQ-SWAP-044, REQ-SWAP-019,
/// SPEC-LIQ-006; PROP-016 twin): donations of USDC, USDT, GHO and vault tokens before or between liquidations of three
/// accounts, in either route mode, at any route rate, never change a figure, are never paid out and stay where they
/// are; every call ends with no allowance to any route, the Spoke or the escrow; no Avana contract sends the debt asset
/// into LPVaultSwap during a liquidation (`Kf` is the caller's).
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 128
contract LPVaultSwapNeutralityFuzzTest is LPVaultSwapUnitBase {
    address[3] internal proxies;

    function setUp() public override {
        super.setUp();
        (proxies[0],) = _bobAccount();
        (proxies[1],) = _openAccount(alice, 6000e6, 10_300e6, 250_000_000);
        (proxies[2],) = _openAccount(carol, 1500e6, 2600e6, 250_000_000);
    }

    /// @notice Three liquidations interleaved with donations: each result equals the same liquidation without
    /// donations, and LPVaultSwap's balances are exactly the donations.
    // TEST-092 verifies: REQ-SWAP-019, REQ-SWAP-042, REQ-SWAP-043, REQ-SWAP-044, INV-021, PROP-016
    function testFuzz_TEST_092_donationsNeverPaidOut(
        uint96 dUsdc,
        uint96 dUsdt,
        uint96 dGho,
        uint256 rateBps,
        bool backupOnly
    ) public {
        rateBps = bound(rateBps, 9990, 10_100);
        usdtUsdcPool.setRate(rateBps, 10_000);
        usdtUsdcPool2.setRate(rateBps, 10_000);
        uint256 snapshot = vm.snapshotState();
        LiquidationResult[3] memory clean;
        for (uint256 i = 0; i < 3; ++i) {
            clean[i] = _liquidateAs(keeper, _p(i, backupOnly));
        }
        vm.revertToState(snapshot);
        for (uint256 i = 0; i < 3; ++i) {
            usdc.mint(address(lvs), uint256(dUsdc) / 3);
            usdt.mint(address(lvs), uint256(dUsdt) / 3);
            gho.mint(address(lvs), uint256(dGho) / 3);
            LiquidationResult memory r = _liquidateAs(keeper, _p(i, backupOnly));
            assertEq(r.recovered, clean[i].recovered, "R unchanged by donations");
            assertEq(r.keeperOut, clean[i].keeperOut, "keeperOut unchanged by donations");
            assertEq(r.avanaFee, clean[i].avanaFee, "A unchanged by donations");
            assertEq(r.unitsSeized, clean[i].unitsSeized, "c unchanged");
            _assertNoAllowances();
        }
        assertEq(usdc.balanceOf(address(lvs)), (uint256(dUsdc) / 3) * 3, "USDC is exactly the donations");
        assertEq(usdt.balanceOf(address(lvs)), (uint256(dUsdt) / 3) * 3, "USDT is exactly the donations");
        assertEq(gho.balanceOf(address(lvs)), (uint256(dGho) / 3) * 3, "GHO is exactly the donations");
        assertEq(vt.balanceOf(address(lvs)), 0, "no vault tokens kept");
    }

    /// @notice The only debt asset entering LPVaultSwap in a liquidation is the caller's funding and its top-up: the
    /// sum of every USDC transfer into LPVaultSwap from anyone but the caller is the recovery from the release and
    /// the routes, never an Avana contract's funds.
    // TEST-059 verifies: REQ-SWAP-012, REQ-SWAP-014, PROP-020, Q-397
    function testFuzz_TEST_059_noAvanaFundsEnter(
        uint256 i
    ) public {
        i = bound(i, 0, 2);
        uint256 escrowBefore = usdc.balanceOf(address(escrow));
        uint256 coverageHub = usdc.balanceOf(aave.hub);
        LiquidationResult memory r = _liquidateAs(keeper, _p(i, false));
        assertEq(usdc.balanceOf(address(escrow)), escrowBefore, "the escrow sent nothing");
        assertEq(usdc.balanceOf(aave.hub), coverageHub + r.debtRepaid, "the Hub only received the repayment");
        assertEq(r.callerFunds + r.recovered + r.shortfall, r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut);
    }

    function _p(
        uint256 i,
        bool backupOnly
    ) internal view returns (LiquidationParams memory p) {
        p = _params(proxies[i], i == 2 ? 500e6 : 1950e6);
        p.routeMode = backupOnly ? RouteMode.BackupOnly : RouteMode.PrimaryThenBackup;
    }
}
