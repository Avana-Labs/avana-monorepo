// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {DebtReserveParams} from "../../src/policy/parameter-store/types/DebtReserveParams.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {BytecodeInspector} from "../utils/BytecodeInspector.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice The blast radius of the ParameterStore (REQ-PSTORE-001, REQ-PSTORE-003): no setter, view or guardian
/// switch writes any storage but the store's own, makes a state-changing call, moves value or creates a contract;
/// the store and its logic contracts refuse ETH; and the parameters the specification removed have no selector in
/// any of their bytecodes (REQ-PSTORE-007, REQ-PSTORE-008, REQ-PSTORE-019, REQ-PSTORE-025, REQ-CONFIG-057).
contract ParameterStoreBlastRadiusUnitTest is ParameterStoreFixture {
    MockAggregator internal netA;
    MockAggregator internal netB;

    function setUp() public {
        _deployStore(false);
        _listMarket();
        netA = new MockAggregator(8, 1e6, 1e12);
        netB = new MockAggregator(8, 1e6, 1e12);
        vm.startPrank(address(timelock));
        store.setFeed(address(netA), _feedDef(86_400, 1800));
        store.setFeed(address(netB), _feedDef(86_400, 1800));
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        vm.stopPrank();
    }

    function _isLogic(
        address a
    ) internal view returns (bool) {
        // The proxy delegatecalls its implementation, which delegatecalls the five logic contracts.
        return a == address(implementation) || a == logics.tighten || a == logics.loosen || a == logics.listing
            || a == logics.adminOracle || a == logics.adminRisk;
    }

    /// @dev Runs `data` from `caller` with state-diff recording and checks every access of the call tree.
    function _contained(
        address caller,
        bytes memory data
    ) internal {
        vm.startStateDiffRecording();
        vm.prank(caller);
        (bool ok,) = address(store).call(data);
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        assertTrue(ok, "setter refused");
        uint256 calls = 0;
        for (uint256 i = 0; i < acc.length; ++i) {
            VmSafe.AccountAccess memory a = acc[i];
            assertEq(a.value, 0, "value moved");
            assertTrue(
                a.kind != VmSafe.AccountAccessKind.Create && a.kind != VmSafe.AccountAccessKind.SelfDestruct
                    && a.kind != VmSafe.AccountAccessKind.CallCode,
                "create, selfdestruct or callcode"
            );
            if (a.kind == VmSafe.AccountAccessKind.Call) {
                // The only state-changing call is the caller's own call into the store.
                assertEq(a.account, address(store), "state-changing external call");
                assertEq(a.accessor, caller);
                ++calls;
            }
            if (a.kind == VmSafe.AccountAccessKind.DelegateCall) {
                assertTrue(_isLogic(a.account), "delegatecall target");
            }
            for (uint256 j = 0; j < a.storageAccesses.length; ++j) {
                if (a.storageAccesses[j].isWrite) {
                    assertEq(a.storageAccesses[j].account, address(store), "foreign storage written");
                }
            }
        }
        assertEq(calls, 1);
    }

    // TEST-133 verifies: REQ-PSTORE-001, REQ-PSTORE-003, INV-018
    function test_TEST_133_tighteningsTouchOnlyTheStore() public {
        address tl = address(timelock);
        _contained(tl, abi.encodeCall(store.tightenHardHealthFloor, (M, 1.1e18)));
        _contained(tl, abi.encodeCall(store.tightenSlippageAllowanceBps, (M, 50)));
        _contained(tl, abi.encodeCall(store.tightenBorrowPriceMaxAge, (address(fUsdc), 4200)));
        _contained(tl, abi.encodeCall(store.tightenConsistencyToleranceBps, (M, 40)));
        _contained(tl, abi.encodeCall(store.tightenFeedAgreementToleranceBps, (usdc, 120)));
        _contained(tl, abi.encodeCall(store.tightenPoolRiskFactor, (M, 3000)));
        _contained(tl, abi.encodeCall(store.tightenRouteDepthThreshold, (M, usdc, gho, 0, 1)));
        _contained(tl, abi.encodeCall(store.tightenMarketUsdCap, (M, 4_000_000e8)));
        _contained(tl, abi.encodeCall(store.tightenTopUpSliceUsd, (M, 400_000e8)));
        _contained(tl, abi.encodeCall(store.tightenTokenUsdCap, (address(hub), usdc, 1e8)));
        _contained(tl, abi.encodeCall(store.tightenDepositorUsdCap, (address(hub), 1e8)));
        _contained(tl, abi.encodeCall(store.tightenPoolShareMaxBps, (5000)));
        _contained(tl, abi.encodeCall(store.tightenPoolShareMaxBpsOf, (M, 100)));
        _contained(tl, abi.encodeCall(store.tightenMinPledgeUsd, (M, 20e8)));
        _contained(tl, abi.encodeCall(store.tightenMaxFlashFeeBps, (5)));
        _contained(tl, abi.encodeCall(store.tightenGateRecoverySeconds, (3600)));
        _contained(tl, abi.encodeCall(store.tightenMaxShortfallBps, (50)));
        _contained(tl, abi.encodeCall(store.tightenDebtStressRiseBps, (usdc, 500)));
    }

    // TEST-133 verifies: REQ-PSTORE-001, REQ-PSTORE-003, INV-018
    function test_TEST_133_loosenAndListingTouchOnlyTheStore() public {
        address tl = address(timelock);
        _contained(tl, abi.encodeCall(store.loosenMarketUsdCap, (M, 6_000_000e8)));
        _contained(tl, abi.encodeCall(store.loosenTopUpSliceUsd, (M, 600_000e8)));
        _contained(tl, abi.encodeCall(store.loosenTokenUsdCap, (address(hub), usdc, 21_000_000e8)));
        _contained(tl, abi.encodeCall(store.loosenDepositorUsdCap, (address(hub), 1_100_000e8)));
        _contained(tl, abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 110)));
        _contained(tl, abi.encodeCall(store.loosenMinPledgeUsd, (M, 1e8)));
        _contained(tl, abi.encodeCall(store.loosenMaxShortfallBps, (2000)));
        _contained(tl, abi.encodeCall(store.loosenGateRecoverySeconds, (900)));
        _contained(tl, abi.encodeCall(store.loosenBreakerDeficitMax, (address(hub), gho, 1e18)));
        _contained(tl, abi.encodeCall(store.setDebtAssetParams, (gho, DebtReserveParams(1e18))));
        _contained(tl, abi.encodeCall(store.setInitialMarketParams, (M, store.getMarketParams(M))));
        _contained(tl, abi.encodeCall(store.setInitialMarketCaps, (M, 5_000_000e8, 500_000e8, 1e8)));
        _contained(tl, abi.encodeCall(store.setInitialTokenCap, (address(hub), usdt, 1e8)));
        _contained(tl, abi.encodeCall(store.setFeed, (address(fUsdc), _feedDef(86_400, 1800))));
        _contained(tl, abi.encodeCall(store.setLiquidationExpectations, (address(spoke), 1.1e18, 200)));
        _contained(tl, abi.encodeCall(store.setSequencer, (address(0), 0)));
        _contained(tl, abi.encodeCall(store.setCoverageRatioBps, (2000)));
    }

    // TEST-133 verifies: REQ-PSTORE-001, REQ-PSTORE-003, REQ-CONFIG-056, INV-018
    function test_TEST_133_structuralSettersTouchOnlyTheStore() public {
        address tl = address(timelock);
        _contained(tl, abi.encodeCall(store.setBorrowPriceMaxAge, (address(fUsdc), 5000)));
        _contained(tl, abi.encodeCall(store.setConsistencyToleranceBps, (M, 60)));
        _contained(tl, abi.encodeCall(store.setFeedAgreementToleranceBps, (usdc, 200)));
        _contained(tl, abi.encodeCall(store.setPoolRiskFactor, (M, 3000)));
        _contained(tl, abi.encodeCall(store.setAvanaFeeShareBps, (1000)));
        // The recipient check probes the candidate and the registry with views only.
        _contained(tl, abi.encodeCall(store.setFeeRecipient, (address(new MockAggregator(8, 1, 2)))));
        _contained(tl, abi.encodeCall(store.setMaxFlashFeeBps, (20)));
        _contained(tl, abi.encodeCall(store.setCachedWindow, (1800)));
        _contained(tl, abi.encodeCall(store.setDisagreementPauseMax, (1800)));
        _contained(tl, abi.encodeCall(store.setTwapWindow, (M, 2400)));
        _contained(tl, abi.encodeCall(store.setUsdBand, (0.95e8, 1.05e8)));
        _contained(tl, abi.encodeCall(store.setLiquidationPriceMaxAge, (address(fUsdc), 88_200)));
        _contained(tl, abi.encodeCall(store.setFeedMaxAge, (address(fUsdc), 88_200)));
        _contained(tl, abi.encodeCall(store.setGraceDuration, (900)));
        _contained(tl, abi.encodeCall(store.setGraceHealthFactor, (0.92e18)));
        _contained(tl, abi.encodeCall(store.setFeedAgreementMarginBps, (40)));
        _contained(tl, abi.encodeCall(store.setSlippageAllowanceMinBps, (M, 40)));
        _contained(tl, abi.encodeCall(store.setTokenCollateralFactorBps, (usdc, 7000)));
        _contained(tl, abi.encodeCall(store.setStressFloorUsd, (M, 2e8)));
    }

    // TEST-133 verifies: REQ-PSTORE-003, REQ-PSTORE-029, INV-018
    function test_TEST_133_secondSourceSwitchesTouchOnlyTheStore() public {
        SecondSource memory a = SecondSource(SecondSourceKind.OracleNetwork, address(netA), bytes32(0), 88_200, 0, 100);
        SecondSource memory b = SecondSource(SecondSourceKind.OracleNetwork, address(netB), bytes32(0), 88_200, 0, 100);
        _contained(address(timelock), abi.encodeCall(store.setSecondSource, (usdc, a, b)));
        _contained(emergencyGuardian, abi.encodeCall(store.useStandbySecondSource, (usdc)));
        _contained(address(timelock), abi.encodeCall(store.restoreSecondSource, (usdc)));
    }

    // TEST-133 verifies: REQ-PSTORE-011, REQ-PSTORE-003, REQ-CONFIG-072
    function test_TEST_133_viewsRunUnderStaticcall() public {
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (usdc, usdt);
        bytes[5] memory views = [
            abi.encodeCall(store.getOracleConfig, (address(lpOracle))),
            abi.encodeCall(store.getOracleInputs, (address(lpOracle), toks, true)),
            abi.encodeCall(store.liquidationLivenessHolds, (address(spoke), M, 1)),
            abi.encodeCall(store.feedAgreementToleranceMinBps, (usdc)),
            abi.encodeCall(store.poolShareMaxBpsOf, (bytes32(0)))
        ];
        for (uint256 i = 0; i < views.length; ++i) {
            vm.startStateDiffRecording();
            (bool ok,) = address(store).staticcall(views[i]);
            VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
            assertTrue(ok, "view failed under staticcall");
            for (uint256 j = 0; j < acc.length; ++j) {
                for (uint256 k = 0; k < acc[j].storageAccesses.length; ++k) {
                    assertFalse(acc[j].storageAccesses[k].isWrite, "view wrote storage");
                }
            }
        }
    }

    // TEST-133 verifies: REQ-PSTORE-001, REQ-PSTORE-003
    function test_TEST_133_storeAndLogicsRefuseEth() public {
        vm.deal(alice, 10 ether);
        address[7] memory targets = [
            address(store),
            address(implementation),
            logics.tighten,
            logics.loosen,
            logics.listing,
            logics.adminOracle,
            logics.adminRisk
        ];
        for (uint256 i = 0; i < targets.length; ++i) {
            vm.prank(alice);
            (bool ok,) = targets[i].call{value: 1}("");
            assertFalse(ok, "accepted bare ETH");
            assertEq(targets[i].balance, 0);
        }
        // A setter is not payable either, even for the timelock.
        vm.deal(address(timelock), 1 ether);
        vm.prank(address(timelock));
        (bool sent,) = address(store).call{value: 1}(abi.encodeCall(store.setCoverageRatioBps, (1)));
        assertFalse(sent, "setter accepted ETH");
        assertEq(store.coverageRatioBps(), 0);
        // An unknown selector has no fallback to land in.
        (bool unknown, bytes memory ret) = address(store).call(abi.encodeWithSignature("sweep(address)", alice));
        assertFalse(unknown);
        assertEq(ret.length, 0);
    }

    // TEST-278 verifies: REQ-PSTORE-025, REQ-PSTORE-019, REQ-PSTORE-008, REQ-PSTORE-007, REQ-CONFIG-057, REQ-PSTORE-016, REQ-ACCESS-057, REQ-ACCESS-076, REQ-ACCESS-077, REQ-ACCESS-137, REQ-ACCESS-165, REQ-ACCESS-180, REQ-ACCESS-065, SPEC-GOV-010
    function test_TEST_278_removedParametersHaveNoSelector() public view {
        string[18] memory removed = [
            "minDebtUsd()",
            "setMinDebtUsd(uint256)",
            "inKindAutoDelay()",
            "setInKindAutoDelay(uint64)",
            "inKindExpiry()",
            "setInKindExpiry(uint64)",
            "buySlippageAllowanceBps(uint256)",
            "setBuySlippageAllowanceBps(uint256,uint16)",
            "buyRouteDepthThreshold(uint256)",
            "breakerPriceDropBps()",
            "breakerSeizureBps()",
            "breakerRouteFailureCount()",
            "breakerCooldown()",
            "breakerPoolShareBps()",
            "minOpeningHealthFactor()",
            "PROXY_HEALTH_FACTOR_FLOOR()",
            "setTemporaryOverride(bytes32,uint256)",
            "restoreParameter(bytes32)"
        ];
        address[6] memory codes = [
            address(implementation), logics.tighten, logics.loosen, logics.listing, logics.adminOracle, logics.adminRisk
        ];
        bytes4[] memory sels = new bytes4[](removed.length);
        for (uint256 i = 0; i < removed.length; ++i) {
            sels[i] = bytes4(keccak256(bytes(removed[i])));
            (bool ok,) = address(store).staticcall(abi.encodePacked(sels[i], new bytes(64)));
            assertFalse(ok, removed[i]);
        }
        // One pass over each code for all the removed selectors (the store's code grew with the speed limits, and a
        // pass per selector ran out of the block gas limit in the unoptimized coverage build).
        for (uint256 j = 0; j < codes.length; ++j) {
            bytes memory code = codes[j].code;
            (bool found, bytes4 which) = BytecodeInspector.pushesAnySelector(code, 0, code.length, sels);
            assertFalse(found, vm.toString(abi.encodePacked(which)));
        }
    }

    // TEST-133 verifies: REQ-PSTORE-003, REQ-PSTORE-014
    function test_TEST_133_brokenStoreConfigReadFailsOnlyTheRead() public {
        // A reverting registry read makes the configuration views revert, which an LPOracle reads as a failed
        // configuration; no state of the store changes and its setters that do not read the registry still run.
        vm.mockCallRevert(address(registry), abi.encodeWithSignature("marketOfLpOracle(address)"), "down");
        (bool ok,) = address(store).staticcall(abi.encodeCall(store.getOracleConfig, (address(lpOracle))));
        assertFalse(ok);
        address[] memory toks = new address[](0);
        (ok,) = address(store).staticcall(abi.encodeCall(store.getOracleInputs, (address(lpOracle), toks, false)));
        assertFalse(ok);
        _tl();
        store.setAvanaFeeShareBps(100);
        assertEq(store.avanaFeeShareBps(), 100);
        MarketParams memory p = store.getMarketParams(M);
        assertEq(p.poolRiskFactor, 4000);
    }
}
