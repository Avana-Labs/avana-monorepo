// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DeleverageRepayHfOrderIntegrationTest
/// @notice Repay with collateral reads `hfBefore` after LPVaultSwap pokes both oracles. Kept on the IntegrationFlows
/// stand-in oracle, which can move its answer on `poke` (`setAnswerOnPoke`); the other repay-with-collateral tests run
/// on the real stack in `Deleverage.RepayWithCollateral.integration.t.sol`.
/// @dev Bob: 10,000 vault tokens at $2.10 ($21,000, CF 80 %) against 10,000 USDC (HF 1.68).
/// forge-config: default.isolate = false
contract DeleverageRepayHfOrderIntegrationTest is IntegrationFlows {
    uint128 internal constant UNITS = 1500e6;

    address internal proxy;
    bytes32 internal key;

    function setUp() public {
        _deployIntegration();
        (proxy, key) = _openAccount(bob, MARKET_ID, 10_000e6, 10_000e6, P_VAULT);
    }

    function _rwc(
        uint128 units,
        uint256 reserveId
    ) internal view returns (RepayWithCollateralParams memory p) {
        p = _rwcParams(MARKET_ID, key, units, reserveId);
    }

    /// @notice `hfBefore` is the health factor at the price Aave applies after LPVaultSwap's pokes. A poke that clears a
    /// token-decimals mark moves the price Aave reads within the block (REQ-ORACLE-107, `LPOraclePokeInvarianceUnitTest`):
    /// the market serves its accepted $2.10 (Cached) until the poke, then its fresh $1.50 (Live). At $1.50 Bob's HF is
    /// 1.20 and releasing 1,500 units raises it to about 1.31; compared with the pre-poke 1.68 the call would revert
    /// `HealthFactorNotImproved` although it improves the account at the price Aave applies, and with the prices the
    /// other way round it would let a call that lowers the health factor through. Regression for `hfBefore` read
    /// before the pokes.
    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-081, SPEC-PROXY-009, REQ-ORACLE-107
    function test_TEST_239_hfBeforeIsReadAfterThePokes() public {
        uint256 snap = vm.snapshotState();
        _setPrice(MARKET_ID, 150_000_000);
        uint256 hfFresh = _hf(proxy);
        vm.revertToState(snap);
        uint256 hfAccepted = _hf(proxy);
        _lpoOf(MARKET_ID).setState(PriceState.Cached, 0, false);
        _lpoOf(MARKET_ID).setAnswerOnPoke(150_000_000);
        vm.recordLogs();
        vm.prank(bob);
        (uint256 repaid,) = adapterC.repayWithCollateral(_rwc(UNITS, usdcReserveId));
        (uint256 hfBefore, uint256 hfAfter) = _hfLog(vm.getRecordedLogs());
        assertGt(repaid, 0, "settled");
        assertLt(hfFresh, hfAccepted, "the poke lowered the health factor Aave reads");
        assertEq(hfBefore, hfFresh, "hfBefore is the post-poke health factor");
        assertGt(hfAfter, hfBefore, "the call improved the account at the price Aave applies");
        assertLt(hfAfter, hfAccepted, "below the pre-poke health factor the old check compared with");
        assertEq(hfAfter, _hf(proxy), "hfAfter is Aave's");
    }

    function _hfLog(
        Vm.Log[] memory logs
    ) internal view returns (uint256 hfBefore, uint256 hfAfter) {
        bytes32 sig = IAaveAdapterEvents.RepaidWithCollateral.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == adapter && logs[i].topics[0] == sig) {
                (,,,,, hfBefore, hfAfter) =
                    abi.decode(logs[i].data, (bytes32, uint128, uint256, uint256, uint256, uint256, uint256));
                return (hfBefore, hfAfter);
            }
        }
        revert("no RepaidWithCollateral");
    }

    /// @notice A GHO-debt account deleverages with every leg swapped into GHO.
}
