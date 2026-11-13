// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../src/custody/lp-vault/ILPVault.sol";
import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IAvanaTimelockErrors} from "../../src/governance/timelock/IAvanaTimelockErrors.sol";
import {ILPVaultSwap} from "../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {ILPVaultSwapAdmin} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapAdmin.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LPVaultSwap} from "../../src/liquidation/lp-vault-swap/LPVaultSwap.sol";
import {LPVaultSwapImmutables} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {LPVaultSwapLogics} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapLogics.sol";
import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {IMarketRegistryApprovals} from "../../src/policy/market-registry/IMarketRegistryApprovals.sol";
import {IMarketRegistryBreakers} from "../../src/policy/market-registry/IMarketRegistryBreakers.sol";
import {IMarketRegistryFreeze} from "../../src/policy/market-registry/IMarketRegistryFreeze.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {IMarketRegistryListing} from "../../src/policy/market-registry/IMarketRegistryListing.sol";
import {IMarketRegistryPause} from "../../src/policy/market-registry/IMarketRegistryPause.sol";
import {IMarketRegistryRoutes} from "../../src/policy/market-registry/IMarketRegistryRoutes.sol";
import {IMarketRegistryStandby} from "../../src/policy/market-registry/IMarketRegistryStandby.sol";
import {IParameterStoreAdmin} from "../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {IParameterStoreBreakers} from "../../src/policy/parameter-store/IParameterStoreBreakers.sol";
import {IParameterStoreLiquidation} from "../../src/policy/parameter-store/IParameterStoreLiquidation.sol";
import {IParameterStoreListing} from "../../src/policy/parameter-store/IParameterStoreListing.sol";
import {IParameterStoreLoosen} from "../../src/policy/parameter-store/IParameterStoreLoosen.sol";
import {IParameterStoreSpeed} from "../../src/policy/parameter-store/IParameterStoreSpeed.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {IVaultTokenFactory} from "../../src/vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {TimelockFixture} from "../utils/fixtures/TimelockFixture.sol";
import {TimelockLaunchLists} from "../utils/fixtures/TimelockLaunchLists.sol";
import {LVSMarketRegistryMock} from "../utils/mocks/LPVaultSwapMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title AvanaTimelockMatrixUnitTest
/// @notice The timelock half of the restricted-function matrix of 2.15: for every selector the matrix lists, the
/// delay class (Short or Normal) the AvanaTimelock built with the launch lists requires, and who can cancel a queued
/// call of it (any canceller, or the Aave governance executor only for restoring and role-change operations). Also
/// the cancel coverage of every operation type by each canceller, the removal of a guardian, the handover to the Aave
/// DAO and operations outliving the governance multisig. The role half of each row (which role the target contract
/// checks) is tested on the target contract.
contract AvanaTimelockMatrixUnitTest is TimelockFixture {
    struct Row {
        address target;
        bytes4 selector;
        bool short;
        bool daoOnly;
    }

    Row[] internal rows;
    address internal daoSecond = makeAddr("daoSecondHolder");

    function setUp() public {
        vm.warp(1_780_000_000);
        _deployTimelock();
        _marketRegistryRows(address(marketRegistry));
        _parameterStoreRows(address(parameterStore));
        _otherRows(address(other));
        // LPVaultSwap keeper registry: the delay and cancel classes here; the same selectors executed through the
        // timelock on the real LPVaultSwap in test_TEST_063_lpVaultSwapKeeperRegistryThroughTimelock.
        rows.push(Row(address(lpVaultSwap), ILPVaultSwapAdmin.addKeeper.selector, false, true));
        rows.push(Row(address(lpVaultSwap), ILPVaultSwapAdmin.removeKeeper.selector, true, false));
    }

    // ─── Matrix rows ───

    function _marketRegistryRows(
        address mr
    ) internal {
        // Short delay, any canceller.
        rows.push(Row(mr, IMarketRegistryRoutes.disableRoute.selector, true, false));
        rows.push(Row(mr, IMarketRegistryListing.setMarketOffboarding.selector, true, false));
        rows.push(Row(mr, IMarketRegistryListing.activateMarket.selector, true, false));
        rows.push(Row(mr, IMarketRegistryListing.cancelRegistration.selector, true, false));
        rows.push(Row(mr, IMarketRegistryPause.freeze.selector, true, false));
        rows.push(Row(mr, IMarketRegistryPause.pause.selector, true, false));
        rows.push(Row(mr, IMarketRegistryFreeze.freezeAddress.selector, true, false));
        rows.push(Row(mr, IMarketRegistryBreakers.tripMarketBreaker.selector, true, false));
        rows.push(Row(mr, IMarketRegistryBreakers.tripDebtBreaker.selector, true, false));
        // Short delay, DAO-only cancel (restoring).
        rows.push(Row(mr, IMarketRegistryRoutes.restoreRoute.selector, true, true));
        rows.push(Row(mr, IMarketRegistryStandby.useStandbyRoute.selector, true, true));
        // Normal delay, DAO-only cancel (restoring).
        rows.push(Row(mr, IMarketRegistryFreeze.unfreezeAddress.selector, false, true));
        // Normal delay, any canceller.
        rows.push(Row(mr, IMarketRegistryListing.listCollateralMarket.selector, false, false));
        rows.push(Row(mr, IMarketRegistryListing.setPriceSource.selector, false, false));
        rows.push(Row(mr, IMarketRegistryRoutes.setRoute.selector, false, false));
        rows.push(Row(mr, IMarketRegistryApprovals.recordIntegrationContracts.selector, false, false));
        rows.push(Row(mr, IMarketRegistryApprovals.finalizeIntegrationContracts.selector, false, false));
        rows.push(Row(mr, IMarketRegistryApprovals.approveSpokeCodeHash.selector, false, false));
        rows.push(Row(mr, IMarketRegistryListing.deployCdpSpoke.selector, false, false));
        rows.push(Row(mr, IMarketRegistryListing.listToken.selector, false, false));
        rows.push(Row(mr, IMarketRegistryListing.enableDebtReserve.selector, false, false));
        rows.push(Row(mr, IMarketRegistryListing.removeDebtReserve.selector, false, false));
        rows.push(Row(mr, IMarketRegistryHubs.setCrossHubLinesEnabled.selector, false, false));
        rows.push(Row(mr, IMarketRegistryHubs.setCrossHubLine.selector, false, false));
        rows.push(Row(mr, IMarketRegistryHubs.setFlashSource.selector, false, false));
        rows.push(Row(mr, IMarketRegistryPause.unpause.selector, false, false));
        rows.push(Row(mr, IMarketRegistryPause.unfreeze.selector, false, false));
        // The chain-wide stops wait the normal delay from the admin: the guardians already stop every Hub at once.
        rows.push(Row(mr, IMarketRegistryPause.freezeAll.selector, false, false));
        rows.push(Row(mr, IMarketRegistryPause.pauseAll.selector, false, false));
        rows.push(Row(mr, IMarketRegistryBreakers.resetMarketBreaker.selector, false, false));
        rows.push(Row(mr, IMarketRegistryBreakers.resetDebtBreaker.selector, false, false));
        rows.push(Row(mr, IMarketRegistryStandby.restorePriceRoute.selector, false, false));
        rows.push(Row(mr, UUPSUpgradeable.upgradeToAndCall.selector, false, false));
    }

    function _parameterStoreRows(
        address ps
    ) internal {
        bytes4[22] memory tighten = [
            IParameterStoreTighten.tightenHardHealthFloor.selector,
            IParameterStoreTighten.tightenSlippageAllowanceBps.selector,
            IParameterStoreTighten.tightenFloorRoundingAllowance.selector,
            IParameterStoreTighten.tightenBorrowPriceMaxAge.selector,
            IParameterStoreTighten.tightenConsistencyToleranceBps.selector,
            IParameterStoreTighten.tightenFeedAgreementToleranceBps.selector,
            IParameterStoreTighten.tightenPoolRiskFactor.selector,
            IParameterStoreTighten.tightenRouteDepthThreshold.selector,
            IParameterStoreTighten.tightenMarketUsdCap.selector,
            IParameterStoreTighten.tightenTopUpSliceUsd.selector,
            IParameterStoreTighten.tightenTokenUsdCap.selector,
            IParameterStoreTighten.tightenDepositorUsdCap.selector,
            IParameterStoreTighten.tightenPoolShareMaxBps.selector,
            IParameterStoreTighten.tightenPoolShareMaxBpsOf.selector,
            IParameterStoreTighten.tightenMinPledgeUsd.selector,
            IParameterStoreBreakers.tightenBreakerDeficitMax.selector,
            IParameterStoreBreakers.tightenGateRecoverySeconds.selector,
            IParameterStoreLiquidation.tightenMaxShortfallBps.selector,
            IParameterStoreLiquidation.tightenDebtStressRiseBps.selector,
            IParameterStoreAdmin.tightenMaxFlashFeeBps.selector,
            IParameterStoreSpeed.tightenMarketSpeedLimits.selector,
            IParameterStoreSpeed.tightenDebtSpeedLimit.selector
        ];
        for (uint256 i; i < tighten.length; ++i) {
            rows.push(Row(ps, tighten[i], true, false));
        }
        bytes4[47] memory normal = [
            IParameterStoreLoosen.loosenHardHealthFloor.selector,
            IParameterStoreLoosen.loosenSlippageAllowanceBps.selector,
            IParameterStoreLoosen.loosenFloorRoundingAllowance.selector,
            IParameterStoreLoosen.loosenRouteDepthThreshold.selector,
            IParameterStoreLoosen.loosenMarketUsdCap.selector,
            IParameterStoreLoosen.loosenTopUpSliceUsd.selector,
            IParameterStoreLoosen.loosenTokenUsdCap.selector,
            IParameterStoreLoosen.loosenDepositorUsdCap.selector,
            IParameterStoreLoosen.loosenPoolShareMaxBps.selector,
            IParameterStoreLoosen.loosenMinPledgeUsd.selector,
            IParameterStoreLoosen.loosenPoolShareMaxBpsOf.selector,
            IParameterStoreBreakers.loosenBreakerDeficitMax.selector,
            IParameterStoreBreakers.loosenGateRecoverySeconds.selector,
            IParameterStoreLiquidation.loosenMaxShortfallBps.selector,
            IParameterStoreLiquidation.loosenDebtStressRiseBps.selector,
            IParameterStoreSpeed.loosenMarketSpeedLimits.selector,
            IParameterStoreSpeed.loosenDebtSpeedLimit.selector,
            IParameterStoreAdmin.setBorrowPriceMaxAge.selector,
            IParameterStoreAdmin.setConsistencyToleranceBps.selector,
            IParameterStoreAdmin.setFeedAgreementToleranceBps.selector,
            IParameterStoreAdmin.setPoolRiskFactor.selector,
            IParameterStoreAdmin.setAvanaFeeShareBps.selector,
            IParameterStoreAdmin.setFeeRecipient.selector,
            IParameterStoreAdmin.setMaxFlashFeeBps.selector,
            IParameterStoreAdmin.setCachedWindow.selector,
            IParameterStoreAdmin.setDisagreementPauseMax.selector,
            IParameterStoreAdmin.setTwapWindow.selector,
            IParameterStoreAdmin.setUsdBand.selector,
            IParameterStoreAdmin.setLiquidationPriceMaxAge.selector,
            IParameterStoreAdmin.setFeedMaxAge.selector,
            IParameterStoreAdmin.setGraceDuration.selector,
            IParameterStoreAdmin.setGraceHealthFactor.selector,
            IParameterStoreAdmin.setFeedAgreementMarginBps.selector,
            IParameterStoreAdmin.setSlippageAllowanceMinBps.selector,
            IParameterStoreAdmin.setTokenCollateralFactorBps.selector,
            IParameterStoreAdmin.setStressFloorUsd.selector,
            IParameterStoreAdmin.setSecondSource.selector,
            IParameterStoreAdmin.restoreSecondSource.selector,
            IParameterStoreListing.setInitialMarketParams.selector,
            IParameterStoreListing.setInitialMarketCaps.selector,
            IParameterStoreListing.setInitialTokenCap.selector,
            IParameterStoreListing.setFeed.selector,
            IParameterStoreLiquidation.setLiquidationExpectations.selector,
            UUPSUpgradeable.upgradeToAndCall.selector,
            IAccessControl.grantRole.selector,
            IAccessControl.revokeRole.selector,
            IAccessControl.renounceRole.selector
        ];
        for (uint256 i; i < normal.length; ++i) {
            rows.push(Row(ps, normal[i], false, false));
        }
    }

    function _otherRows(
        address o
    ) internal {
        rows.push(Row(o, ILPOracle.setPokeMinGas.selector, false, false));
        rows.push(Row(o, IDebtOracle.setPokeMinGas.selector, false, false));
        rows.push(Row(o, ILPVault.returnStray.selector, false, false));
        rows.push(Row(o, IVaultTokenFactory.deployVaultToken.selector, false, false));
        rows.push(Row(o, UUPSUpgradeable.upgradeToAndCall.selector, false, false));
        rows.push(Row(o, IAccessControl.grantRole.selector, false, false));
        rows.push(Row(o, IAccessControl.revokeRole.selector, false, false));
    }

    function _isRole(
        bytes4 s
    ) internal pure returns (bool) {
        return s == IAccessControl.grantRole.selector || s == IAccessControl.revokeRole.selector
            || s == IAccessControl.renounceRole.selector;
    }

    // ─── Delay class of every matrix selector ───

    /// @notice Each matrix selector, alone in an operation, needs exactly its matrix delay: 43,200 s for the short
    /// list, the normal delay (432,000 s) for every other call; scheduling one second below reverts
    /// `DelayBelowRequired`; a batch of every short selector stays short and one normal call makes it normal.
    // TEST-063 verifies: SPEC-GOV-001, REQ-ACCESS-141, REQ-ACCESS-031, REQ-ACCESS-033, REQ-ACCESS-034, REQ-ACCESS-045, REQ-ACCESS-046, REQ-ACCESS-047, REQ-ACCESS-048, REQ-ACCESS-184, REQ-ACCESS-133, REQ-ACCESS-134, REQ-ACCESS-036, REQ-ACCESS-145, REQ-ACCESS-175, REQ-ACCESS-062, REQ-ACCESS-063, REQ-ACCESS-158, REQ-ACCESS-159, REQ-ACCESS-037, REQ-ACCESS-038, REQ-ACCESS-039, REQ-ACCESS-040, REQ-ACCESS-041, REQ-ACCESS-043, REQ-ACCESS-186, REQ-ACCESS-044, REQ-ACCESS-131, REQ-ACCESS-132, REQ-ACCESS-138, REQ-ACCESS-049, REQ-ACCESS-050, REQ-ACCESS-135, REQ-ACCESS-146, REQ-ACCESS-165, REQ-ACCESS-179, REQ-ACCESS-051, REQ-ACCESS-174, REQ-ACCESS-060, REQ-ACCESS-061, REQ-ACCESS-064, REQ-ACCESS-088, REQ-ACCESS-091, REQ-ACCESS-148, REQ-ROUTE-017, REQ-ROUTE-018, REQ-ROUTE-019, REQ-ROUTE-020, REQ-ACCESS-172, REQ-ACCESS-128, REQ-ORACLE-079
    // Sources: 2.15 "Restricted-function matrix", "Delay classes and timing"; MATH-GOV-01
    function test_TEST_063_everyMatrixSelectorNeedsItsDelayClass() public {
        uint256 shortCount;
        for (uint256 i; i < rows.length; ++i) {
            Row memory r = rows[i];
            Call[] memory calls = _one(r.target, abi.encodePacked(r.selector, uint256(i)));
            uint256 expected = r.short ? SHORT_DELAY : NORMAL_DELAY;
            assertEq(_required(calls), expected, "matrix delay class");
            assertEq(timelock.isShortDelaySelector(r.target, r.selector), r.short, "short-delay list");
            // Below 43,200 s OpenZeppelin's own minimum-delay check answers first.
            vm.expectRevert(
                abi.encodeWithSelector(
                    r.short
                        ? TimelockController.TimelockInsufficientDelay.selector
                        : IAvanaTimelockErrors.DelayBelowRequired.selector,
                    expected - 1,
                    expected
                )
            );
            this.scheduleAs(governanceMultisig, calls, expected - 1, bytes32(i));
            if (r.short) ++shortCount;
        }
        // Every short call together is still short; one normal call makes the whole batch normal.
        Call[] memory batch = new Call[](shortCount + 1);
        uint256 k;
        bytes4 normalSelector;
        address normalTarget;
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].short) batch[k++] = Call(rows[i].target, abi.encodePacked(rows[i].selector));
            else (normalTarget, normalSelector) = (rows[i].target, rows[i].selector);
        }
        Call[] memory onlyShort = new Call[](shortCount);
        for (uint256 i; i < shortCount; ++i) {
            onlyShort[i] = batch[i];
        }
        assertEq(_required(onlyShort), SHORT_DELAY, "all-short batch");
        batch[shortCount] = Call(normalTarget, abi.encodePacked(normalSelector));
        assertEq(_required(batch), NORMAL_DELAY, "one normal call makes the batch normal");
    }

    /// @notice External wrapper so `expectRevert` sees the schedule call at the right depth.
    function scheduleAs(
        address proposer,
        Call[] memory calls,
        uint256 delay,
        bytes32 salt
    ) external {
        _schedule(proposer, calls, delay, salt);
    }

    // ─── Who can cancel each matrix selector ───

    /// @notice A queued call of each matrix selector: the Emergency Guardian cancels it unless the row is restoring
    /// (`RestoringCancelRestricted`) or a role change (`RoleChangeCancelRestricted`); the Aave governance executor
    /// cancels every one; a cancelled operation never executes.
    // TEST-067 verifies: SPEC-GOV-005, REQ-ACCESS-156, REQ-ACCESS-032, REQ-ACCESS-033, REQ-ACCESS-034, REQ-ACCESS-045, REQ-ACCESS-046, REQ-ACCESS-047, REQ-ACCESS-048, REQ-ACCESS-184, REQ-ACCESS-133, REQ-ACCESS-134, REQ-ACCESS-036, REQ-ACCESS-145, REQ-ACCESS-175, REQ-ACCESS-062, REQ-ACCESS-063, REQ-ACCESS-158, REQ-ACCESS-159, REQ-ACCESS-037, REQ-ACCESS-038, REQ-ACCESS-039, REQ-ACCESS-040, REQ-ACCESS-041, REQ-ACCESS-043, REQ-ACCESS-186, REQ-ACCESS-044, REQ-ACCESS-131, REQ-ACCESS-132, REQ-ACCESS-138, REQ-ACCESS-049, REQ-ACCESS-050, REQ-ACCESS-135, REQ-ACCESS-146, REQ-ACCESS-165, REQ-ACCESS-179, REQ-ACCESS-051, REQ-ACCESS-174, REQ-ACCESS-060, REQ-ACCESS-061, REQ-ACCESS-064, REQ-ACCESS-088, REQ-ROUTE-019, REQ-ACCESS-172
    // Sources: 2.15 "Restricted-function matrix" (canceller column), 5.1 TEST-067
    function test_TEST_067_everyMatrixSelectorHasItsCancelClass() public {
        for (uint256 i; i < rows.length; ++i) {
            Row memory r = rows[i];
            Call[] memory calls = _one(r.target, abi.encodePacked(r.selector, uint256(i)));
            bytes32 salt = bytes32(i);
            bytes32 id = _schedule(governanceMultisig, calls, _required(calls), salt);
            bool roleChange = _isRole(r.selector);
            assertEq(timelock.isRoleChangeOperation(id), roleChange, "role-change mark");
            assertEq(timelock.isRestoringOperation(id), r.daoOnly, "restoring mark");
            if (roleChange) {
                vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.RoleChangeCancelRestricted.selector, id));
                vm.prank(emergencyGuardian);
                timelock.cancel(id);
            } else if (r.daoOnly) {
                vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.RestoringCancelRestricted.selector, id));
                vm.prank(emergencyGuardian);
                timelock.cancel(id);
            }
            vm.prank(roleChange || r.daoOnly ? aaveGovernanceExecutor : emergencyGuardian);
            timelock.cancel(id);
            assertFalse(timelock.isOperation(id), "cancelled");
        }
        // A cancelled operation can never run, even after its delay.
        vm.warp(block.timestamp + NORMAL_DELAY + 1);
        Call[] memory last = _one(rows[0].target, abi.encodePacked(rows[0].selector, uint256(0)));
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(last);
        vm.expectRevert();
        timelock.executeBatch(t, v, p, bytes32(0), bytes32(0));
    }

    // ─── Every operation type, every canceller ───

    /// @notice Short, normal, mixed and timelock self-call operations, and a role change mixed with any other call,
    /// are cancellable by each of the four `CANCELLER_ROLE` holders; an operation whose every call is `grantRole`,
    /// `revokeRole` or `renounceRole` (on an Avana contract or on the timelock) and a restoring operation only by the
    /// Aave governance executor; an account without `CANCELLER_ROLE` cancels nothing; a cancelled operation never
    /// executes; neither guardian can schedule; a holder may renounce its own role.
    // TEST-067 verifies: SPEC-GOV-005, REQ-ACCESS-005, REQ-ACCESS-006, REQ-ACCESS-026, REQ-ACCESS-032, REQ-ACCESS-094, REQ-ACCESS-112, REQ-ACCESS-156
    // Sources: 5.1 TEST-067
    function test_TEST_067_everyOperationTypeByEveryCanceller() public {
        address[4] memory cancellers = [governanceMultisig, emergencyGuardian, aaveGuardian, aaveGovernanceExecutor];
        Call[][7] memory ops;
        ops[0] = _one(address(marketRegistry), abi.encodeCall(IMarketRegistryPause.freeze, (address(1))));
        ops[1] = _one(
            address(marketRegistry),
            abi.encodeCall(IMarketRegistryRoutes.setRoute, (1, address(2), address(3), 0, address(4)))
        );
        ops[2] = _two(ops[0][0], ops[1][0]);
        ops[3] = _self(abi.encodeWithSignature("setNormalDelay(uint256)", MIN_NORMAL_DELAY));
        ops[4] = _two(
            Call(
                address(marketRegistry),
                abi.encodeCall(IAccessControl.revokeRole, (AvanaRoles.APPLICATION_ADMIN, address(timelock)))
            ),
            Call(address(timelock), abi.encodeCall(IAccessControl.renounceRole, (keccak256("ANY"), address(timelock))))
        );
        ops[5] = _one(
            address(marketRegistry),
            abi.encodeCall(IMarketRegistryRoutes.restoreRoute, (1, address(2), address(3), 0, address(4)))
        );
        ops[6] = _two(ops[4][0], ops[0][0]);
        for (uint256 g; g < 2; ++g) {
            address guardian = g == 0 ? emergencyGuardian : aaveGuardian;
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, timelock.PROPOSER_ROLE()
                )
            );
            this.scheduleAs(guardian, ops[0], SHORT_DELAY, bytes32("guardian"));
        }
        for (uint256 o; o < ops.length; ++o) {
            bool daoOnly = o == 4 || o == 5;
            for (uint256 c; c < cancellers.length; ++c) {
                bytes32 salt = keccak256(abi.encode(o, c));
                bytes32 id = _schedule(governanceMultisig, ops[o], _required(ops[o]), salt);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, timelock.CANCELLER_ROLE()
                    )
                );
                vm.prank(attacker);
                timelock.cancel(id);
                if (daoOnly && cancellers[c] != aaveGovernanceExecutor) {
                    vm.expectRevert(
                        abi.encodeWithSelector(
                            o == 4
                                ? IAvanaTimelockErrors.RoleChangeCancelRestricted.selector
                                : IAvanaTimelockErrors.RestoringCancelRestricted.selector,
                            id
                        )
                    );
                    vm.prank(cancellers[c]);
                    timelock.cancel(id);
                    assertTrue(timelock.isOperationPending(id), "still queued");
                    continue;
                }
                vm.prank(cancellers[c]);
                timelock.cancel(id);
                assertFalse(timelock.isOperation(id), "cancelled");
                uint256 t0 = block.timestamp;
                vm.warp(t0 + NORMAL_DELAY);
                (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(ops[o]);
                vm.expectRevert();
                timelock.executeBatch(t, v, p, bytes32(0), salt);
                vm.warp(t0);
            }
        }
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        vm.prank(aaveGuardian);
        timelock.renounceRole(cancellerRole, aaveGuardian);
        assertFalse(timelock.hasRole(cancellerRole, aaveGuardian), "renounced");
    }

    // ─── Removal of a guardian (SPEC-GOV-006) ───

    /// @notice Revoking a guardian role on the MarketRegistry is a role-change operation: it needs the normal delay
    /// (a short schedule reverts `DelayBelowRequired`), neither guardian can cancel it, it cannot run before
    /// `readyAt`, and anyone executes it at `readyAt`, the guardian's last moment of power.
    // TEST-244 verifies: SPEC-GOV-006, SPEC-GOV-005, REQ-ACCESS-112, REQ-ACCESS-091, REQ-ACCESS-149, SPEC-GOV-014
    // Sources: 2.15 SPEC-GOV-006
    function test_TEST_244_guardianRemovalIsARoleChangeTheGuardiansCannotStop() public {
        Call[] memory calls = _one(
            address(marketRegistry),
            abi.encodeCall(IAccessControl.revokeRole, (AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian))
        );
        assertEq(_required(calls), NORMAL_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(IAvanaTimelockErrors.DelayBelowRequired.selector, SHORT_DELAY, NORMAL_DELAY)
        );
        this.scheduleAs(governanceMultisig, calls, SHORT_DELAY, bytes32(0));
        uint256 ts = block.timestamp;
        bytes32 id = _schedule(governanceMultisig, calls, NORMAL_DELAY, bytes32(0));
        assertTrue(timelock.isRoleChangeOperation(id));
        address[2] memory guardians = [emergencyGuardian, aaveGuardian];
        for (uint256 g; g < guardians.length; ++g) {
            vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.RoleChangeCancelRestricted.selector, id));
            vm.prank(guardians[g]);
            timelock.cancel(id);
        }
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.warp(ts + NORMAL_DELAY - 1);
        vm.expectRevert();
        timelock.executeBatch(t, v, p, bytes32(0), bytes32(0));
        vm.warp(ts + NORMAL_DELAY);
        _execute(attacker, calls, bytes32(0));
        assertEq(marketRegistry.callCount(), 1);
        assertEq(marketRegistry.callAt(0).caller, address(timelock));
    }

    // ─── Handover to the Aave DAO (REQ-ACCESS-105) ───

    /// @notice The handover is one operation of `grantRole` and `revokeRole` calls on the timelock, so it is a
    /// role-change operation: normal delay, only the Aave governance executor cancels it. After it runs, the Aave
    /// governance executor and a second DAO-named holder schedule and execute, and the governance multisig no longer
    /// proposes.
    // TEST-242 verifies: REQ-ACCESS-105, REQ-ACCESS-032, REQ-ACCESS-004, REQ-ACCESS-007, SPEC-GOV-005
    // Sources: 2.15 "DAO handover and wind-down"
    function test_TEST_242_handoverToTheDaoIsOneRoleChangeOperation() public {
        bytes32 proposer = timelock.PROPOSER_ROLE();
        bytes32 executor = timelock.EXECUTOR_ROLE();
        Call[] memory calls = new Call[](5);
        calls[0] = Call(address(timelock), abi.encodeCall(IAccessControl.grantRole, (executor, aaveGovernanceExecutor)));
        calls[1] = Call(address(timelock), abi.encodeCall(IAccessControl.grantRole, (proposer, daoSecond)));
        calls[2] = Call(address(timelock), abi.encodeCall(IAccessControl.grantRole, (executor, daoSecond)));
        calls[3] = Call(address(timelock), abi.encodeCall(IAccessControl.revokeRole, (proposer, governanceMultisig)));
        calls[4] = Call(address(timelock), abi.encodeCall(IAccessControl.revokeRole, (executor, governanceMultisig)));
        assertEq(_required(calls), NORMAL_DELAY, "never short");
        bytes32 id = _schedule(governanceMultisig, calls, NORMAL_DELAY, bytes32(0));
        assertTrue(timelock.isRoleChangeOperation(id));
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.RoleChangeCancelRestricted.selector, id));
        vm.prank(emergencyGuardian);
        timelock.cancel(id);
        vm.warp(block.timestamp + NORMAL_DELAY);
        _execute(attacker, calls, bytes32(0));
        assertTrue(timelock.hasRole(executor, aaveGovernanceExecutor));
        assertTrue(timelock.hasRole(proposer, daoSecond) && timelock.hasRole(executor, daoSecond));
        assertFalse(timelock.hasRole(proposer, governanceMultisig) || timelock.hasRole(executor, governanceMultisig));
        Call[] memory next = _one(address(parameterStore), abi.encodeWithSignature("setFeeRecipient(address)", alice));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, governanceMultisig, proposer
            )
        );
        this.scheduleAs(governanceMultisig, next, NORMAL_DELAY, bytes32(0));
        _schedule(daoSecond, next, NORMAL_DELAY, bytes32(0));
        vm.warp(block.timestamp + NORMAL_DELAY);
        _execute(daoSecond, next, bytes32(0));
        assertEq(parameterStore.callCount(), 1);
    }

    // ─── Operations outlive the governance multisig (REQ-ACCESS-107, REQ-ACCESS-129) ───

    /// @notice With the governance multisig gone: an operation it scheduled stays executable by anyone through the
    /// public path within its window and cancellable by a canceller; the Aave governance executor, the second
    /// proposer, schedules a repair at the same delays (here the revocation of the multisig's proposer role) that
    /// anyone executes.
    // TEST-194 verifies: REQ-ACCESS-107, REQ-ACCESS-129, REQ-ACCESS-160, REQ-ACCESS-144, REQ-ACCESS-012
    // Sources: 2.15 REQ-ACCESS-107, REQ-ACCESS-129
    function test_TEST_194_operationsOutliveTheGovernanceMultisig() public {
        Call[] memory queued = _one(address(parameterStore), abi.encodeWithSignature("setFeeRecipient(address)", bob));
        Call[] memory other_ = _one(
            address(marketRegistry),
            abi.encodeCall(IMarketRegistryRoutes.setRoute, (1, address(2), address(3), 0, address(4)))
        );
        _schedule(governanceMultisig, queued, NORMAL_DELAY, bytes32(0));
        bytes32 otherId = _schedule(governanceMultisig, other_, NORMAL_DELAY, bytes32(0));
        // From here on the multisig never acts again.
        Call[] memory repair = _one(
            address(timelock), abi.encodeCall(IAccessControl.revokeRole, (timelock.PROPOSER_ROLE(), governanceMultisig))
        );
        assertEq(_required(repair), NORMAL_DELAY);
        _schedule(aaveGovernanceExecutor, repair, NORMAL_DELAY, bytes32(0));
        vm.prank(aaveGuardian);
        timelock.cancel(otherId);
        vm.warp(block.timestamp + NORMAL_DELAY);
        _execute(attacker, queued, bytes32(0));
        _execute(attacker, repair, bytes32(0));
        assertEq(parameterStore.callCount(), 1);
        assertEq(marketRegistry.callCount(), 0, "cancelled operation never ran");
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), governanceMultisig));
        // The executor keeps proposing at the same delays.
        Call[] memory more = _one(
            address(marketRegistry), abi.encodeCall(IMarketRegistryRoutes.disableRoute, (1, address(2), address(3), 0))
        );
        assertEq(_required(more), SHORT_DELAY);
        _schedule(aaveGovernanceExecutor, more, SHORT_DELAY, bytes32(0));
        vm.warp(block.timestamp + SHORT_DELAY);
        _execute(attacker, more, bytes32(0));
        assertEq(marketRegistry.callCount(), 1);
    }

    /// @notice The real LPVaultSwap's keeper registry through the timelock: `addKeeper` runs only after the normal
    /// delay and `removeKeeper` after the short delay, both executed by anyone once ready; a removal that would leave
    /// fewer active committed operators than `keeperFloor` (1) reverts `KeeperFloor` inside the execution, so the
    /// operation stays unexecuted; a direct call by any account other than the timelock reverts with the missing
    /// `APPLICATION_ADMIN` role.
    // TEST-063 verifies: REQ-ACCESS-011, REQ-ACCESS-053, REQ-ACCESS-054, REQ-ACCESS-100, REQ-ACCESS-121, SPEC-GOV-008
    // TEST-045 verifies: REQ-ACCESS-053, REQ-ACCESS-054; shared: TEST-045's keeper registry through the real AvanaTimelock, addKeeper at the normal delay, removeKeeper at the short delay, KeeperFloor
    function test_TEST_063_lpVaultSwapKeeperRegistryThroughTimelock() public {
        ILPVaultSwap lvs = _realLPVaultSwap();
        address second = makeAddr("secondKeeper");
        assertEq(_required(_one(address(lvs), abi.encodeCall(ILPVaultSwapAdmin.addKeeper, (second)))), NORMAL_DELAY);
        assertEq(_required(_one(address(lvs), abi.encodeCall(ILPVaultSwapAdmin.removeKeeper, (keeper)))), SHORT_DELAY);
        _run(_one(address(lvs), abi.encodeCall(ILPVaultSwapAdmin.addKeeper, (second))), bytes32("add"));
        assertTrue(lvs.isApprovedKeeper(second), "added after the normal delay");
        assertEq(lvs.activeKeeperCount(), 2);
        _run(_one(address(lvs), abi.encodeCall(ILPVaultSwapAdmin.removeKeeper, (keeper))), bytes32("remove"));
        assertFalse(lvs.isApprovedKeeper(keeper), "removed after the short delay");
        Call[] memory last = _one(address(lvs), abi.encodeCall(ILPVaultSwapAdmin.removeKeeper, (second)));
        _schedule(governanceMultisig, last, SHORT_DELAY, bytes32("floor"));
        vm.warp(block.timestamp + SHORT_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(last);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.KeeperFloor.selector, 0, 1));
        timelock.executeBatch(t, v, p, bytes32(0), bytes32("floor"));
        assertTrue(lvs.isApprovedKeeper(second), "the floor keeps the last committed operator");
        vm.prank(governanceMultisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                governanceMultisig,
                AvanaRoles.APPLICATION_ADMIN
            )
        );
        ILPVaultSwapAdmin(address(lvs)).addKeeper(makeAddr("direct"));
    }

    /// @dev Deploys the real LPVaultSwap (three logic contracts, the implementation, the proxy initialised with this
    /// timelock and one keeper) and a timelock whose launch lists name it, and makes that timelock the fixture's.
    function _realLPVaultSwap() internal returns (ILPVaultSwap lvs) {
        LPVaultSwapImmutables memory im = LPVaultSwapImmutables({
            lock: makeAddr("lock"),
            aaveAdapter: makeAddr("aaveAdapter"),
            collateralization: makeAddr("collateralization"),
            marketRegistry: address(new LVSMarketRegistryMock()), // freeze reads of addKeeper and activeKeeperCount
            parameterStore: makeAddr("store"),
            payoutEscrow: makeAddr("escrow"),
            keeperFloor: 1
        });
        LPVaultSwapLogics memory logics = LPVaultSwapLogics({
            liquidation: deployCode("LPVaultSwapLiquidationLogic.sol:LPVaultSwapLiquidationLogic", abi.encode(im)),
            pending: deployCode("LPVaultSwapPendingLogic.sol:LPVaultSwapPendingLogic", abi.encode(im)),
            deleverage: deployCode("LPVaultSwapDeleverageLogic.sol:LPVaultSwapDeleverageLogic", abi.encode(im))
        });
        LPVaultSwap implementation = new LPVaultSwap(im, logics);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        timelock = _newTimelock(
            NORMAL_DELAY,
            true,
            TimelockLaunchLists.shortEligible(address(parameterStore), address(marketRegistry), predicted),
            TimelockLaunchLists.daoOnlyCancel(address(marketRegistry), predicted)
        );
        address[] memory keepers = new address[](1);
        keepers[0] = keeper;
        lvs = ILPVaultSwap(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(LPVaultSwap.initialize, (address(timelock), keepers))
                )
            )
        );
        assertEq(address(lvs), predicted, "the timelock's lists name the deployed LPVaultSwap");
    }
}
