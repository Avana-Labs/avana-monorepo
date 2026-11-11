// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {IRiskModuleViews} from "../../src/policy/risk-module/IRiskModuleViews.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModulePauseIndependenceUnitTest
/// @notice No RiskModule check reads a Hub's pause state, its reason or the address freeze (REQ-ADAPTER-018, PROP-066
/// RiskModule half): every check and view returns the same data or the same revert under `None`, `Frozen`, `Paused`
/// with each reason, and with the wallet, the proxy and the Hub frozen as addresses, on a passing and on a refused
/// account. The status view changes only its two pause fields (TEST-028).
contract RiskModulePauseIndependenceUnitTest is RiskModuleFixture {
    uint128 internal constant UNITS = 10_000e18;

    function setUp() public {
        _deployRiskWorld();
        _enableUsdcDebt();
        _debt(1.5e18, 1000);
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
    }

    /// @dev Every RiskModule call an Avana entry point makes, by calldata.
    function _calls() internal view returns (bytes[] memory c) {
        PledgeCounters memory k = _counters();
        uint256[] memory ids = new uint256[](1);
        ids[0] = mid;
        c = new bytes[](12);
        c[0] = abi.encodeCall(
            IRiskModuleChecks.checkPledge, (wallet, address(proxy), mid, V3, bytes32(uint256(1)), UNITS, k, false)
        );
        c[1] = abi.encodeCall(
            IRiskModuleChecks.checkPledge, (wallet, address(proxy), mid, V3, bytes32(uint256(1)), UNITS, k, true)
        );
        c[2] = abi.encodeCall(IRiskModuleChecks.preBorrowCheck, (address(proxy), GHO_RESERVE, 1));
        c[3] = abi.encodeCall(IRiskModuleChecks.preBorrowCheck, (address(proxy), USDC_RESERVE, 1));
        c[4] = abi.encodeCall(IRiskModuleChecks.preWithdrawCheck, (address(proxy)));
        c[5] = abi.encodeCall(IRiskModuleChecks.postHealthCheck, (address(proxy), 1.2e18));
        c[6] = abi.encodeCall(IRiskModuleChecks.checkAaveConfig, (address(spoke), ids));
        c[7] = abi.encodeCall(IRiskModuleChecks.checkRemainingRecord, (mid, UNITS));
        c[8] = abi.encodeCall(IRiskModuleViews.getBreakerStatus, (mid));
        c[9] = abi.encodeCall(IRiskModuleViews.getDebtBreakerStatus, (address(spoke), USDC_RESERVE));
        c[10] = abi.encodeCall(IRiskModuleViews.usdToRestore, (address(proxy)));
        c[11] = abi.encodeCall(IRiskModuleViews.debtValueUsd, (address(proxy)));
    }

    /// @dev Outcome of every call: success flag and return or revert data, hashed.
    function _outcomes() internal returns (bytes32[] memory h) {
        bytes[] memory c = _calls();
        h = new bytes32[](c.length);
        for (uint256 i = 0; i < c.length; ++i) {
            (bool ok, bytes memory ret) = address(riskModule).call(c[i]);
            h[i] = keccak256(abi.encode(ok, ret));
        }
    }

    function _assertSame(
        bytes32[] memory a,
        bytes32[] memory b,
        string memory what
    ) internal pure {
        for (uint256 i = 0; i < a.length; ++i) {
            assertEq(a[i], b[i], string.concat(what, " changed call ", vm.toString(i)));
        }
    }

    /// @dev Runs every pause and freeze configuration and compares each outcome with `base`.
    function _sweep(
        bytes32[] memory base
    ) internal {
        uint256 snap = vm.snapshotState();
        vm.prank(emergencyGuardian);
        registry.freeze(address(hub));
        _assertSame(base, _outcomes(), "Frozen");
        vm.prank(emergencyGuardian);
        registry.pause(address(hub), PauseReason.General);
        _assertSame(base, _outcomes(), "Paused General");
        vm.prank(emergencyGuardian);
        registry.pause(address(hub), PauseReason.MintPathSuspect);
        _assertSame(base, _outcomes(), "Paused MintPathSuspect");
        vm.revertToState(snap);
        vm.startPrank(emergencyGuardian);
        registry.freezeAddress(wallet);
        registry.freezeAddress(address(proxy));
        vm.stopPrank();
        _assertSame(base, _outcomes(), "address freeze");
        vm.revertToState(snap);
    }

    // TEST-228 verifies: REQ-ADAPTER-018, REQ-RISK-038, INV-045, INV-081
    function test_TEST_228_checksIgnorePauseOnAPassingAccount() public {
        bytes32[] memory base = _outcomes();
        _sweep(base);
    }

    // TEST-228 verifies: REQ-ADAPTER-018, REQ-RISK-038, INV-045, INV-081
    function test_TEST_228_checksIgnorePauseOnARefusedAccount() public {
        // A refused account: no keeper, a stale USDC price and a health factor under the caller's minimum.
        swap.setKeepers(0);
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp - 100_000), true);
        _debt(1.05e18, 1000);
        bytes32[] memory base = _outcomes();
        _sweep(base);
    }

    // TEST-228 verifies: REQ-ADAPTER-018, REQ-RISK-038
    function test_TEST_228_checksIgnorePauseOnADriftedSpoke() public {
        oracle.setState(PriceState.Cached, 0, false);
        rHub.setAdded(VT_ASSET, 10, 9);
        bytes32[] memory base = _outcomes();
        _sweep(base);
    }
}
