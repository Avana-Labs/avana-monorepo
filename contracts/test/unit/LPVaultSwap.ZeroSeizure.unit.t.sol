// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title LPVaultSwapZeroSeizureUnitTest
/// @notice Zero and minimal seizures (2.11 REQ-SWAP-017, REQ-SWAP-056, REQ-SWAP-077): a `debtToCover` below one vault
/// unit's value makes Aave seize nothing, and LPVaultSwap reverts `NothingSeized` so it never repays debt without
/// seizing collateral and never asks the AaveAdapter to burn zero units; the smallest repayment that seizes one unit
/// settles.
/// forge-config: default.isolate = false
contract LPVaultSwapZeroSeizureUnitTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @notice One raw unit of USDC buys 0.5 raw vault units at $2.10 with a 5 % bonus: Aave seizes 0 and the call
    /// reverts `NothingSeized` with nothing burned, swapped or paid; the AaveAdapter's burn is never called.
    // TEST-160 verifies: REQ-SWAP-017, REQ-SWAP-056, REQ-SWAP-077, INV-030, Q-127
    function test_TEST_160_nothingSeizedRejected() public {
        uint256 burns = adapter.burnCalls();
        uint256 debt = _debtOf(proxy, usdcReserveId);
        _fund(usdc, keeper, 1);
        vm.prank(keeper);
        (bool ok, bytes memory ret) = address(lvs).call(abi.encodeCall(lvs.liquidate, (_params(proxy, 1))));
        assertFalse(ok, "refused");
        assertEq(keccak256(ret), keccak256(_err(ILPVaultSwapErrors.NothingSeized.selector)), "NothingSeized()");
        assertEq(adapter.burnCalls(), burns, "no burn");
        assertEq(_debtOf(proxy, usdcReserveId), debt, "no repayment without seizure");
    }

    /// @notice The smallest repayment that seizes at least one unit settles, with one or two units seized.
    // TEST-160 verifies: REQ-SWAP-017, INV-038
    function test_TEST_160_oneUnitSucceeds() public {
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 3));
        assertGe(r.unitsSeized, 1, "at least one unit");
        assertLe(r.debtRepaid, 3, "D <= Kf");
        assertEq(adapter.lastBurnUnits(), r.unitsSeized, "burned exactly c");
    }

    /// @notice `NothingSeized` when Aave transfers no vault token (a mocked Spoke call that repays nothing and seizes
    /// nothing): LPVaultSwap measures `c` by its own balance, not by a return value.
    // TEST-160 verifies: REQ-SWAP-017, REQ-SWAP-019, REQ-SWAP-056
    function test_TEST_160_measuredNotReported() public {
        vm.mockCall(
            aave.cdpSpoke,
            abi.encodeWithSignature(
                "liquidationCall(uint256,uint256,address,uint256,bool)",
                vtReserveId,
                usdcReserveId,
                proxy,
                1950e6,
                false
            ),
            ""
        );
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.NothingSeized.selector));
    }
}
