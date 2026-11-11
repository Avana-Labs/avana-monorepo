// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {Market} from "../../src/types/Market.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleDriftUnitTest
/// @notice `checkAaveConfig`, `pokeConfig`, `isHubSharesEqualAssets` and `expectedCollateralFactorBps` against the
/// standard-Spoke settings, the debt-reserve set and the risk configuration.
contract RiskModuleDriftUnitTest is RiskModuleFixture {
    function setUp() public {
        _deployRiskWorld();
    }

    function _ids() internal view returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = mid;
    }

    function _expectDrift(
        uint256 marketId,
        DriftReason reason
    ) internal {
        uint256[] memory ids = _ids();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, marketId, reason));
        riskModule.checkAaveConfig(address(spoke), ids);
    }

    function _vtConfig(
        bool receiveShares,
        bool borrowable,
        bool paused
    ) internal {
        IAaveV4Spoke.ReserveConfig memory c;
        (c.receiveSharesEnabled, c.borrowable, c.paused) = (receiveShares, borrowable, paused);
        rSpoke.setConfig(VT_RESERVE, c);
    }

    function _key(
        uint16 cf,
        uint32 maxLb,
        uint16 fee
    ) internal {
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus, d.liquidationFee) = (cf, maxLb, fee);
        spoke.setDynamic(VT_RESERVE, d);
    }

    // TEST-268 verifies: REQ-RISK-078, REQ-ADAPTER-029, REQ-ADAPTER-030, REQ-ADAPTER-033, REQ-RISK-086, INV-029
    function test_TEST_268_standardSpokeSettings() public {
        riskModule.checkAaveConfig(address(spoke), _ids());
        _vtConfig(true, false, false);
        _expectDrift(mid, DriftReason.ReceiveSharesOn);
        // A borrowable vault-token reserve is outside the registry's debt set: the Spoke-wide check sees it first.
        _vtConfig(false, true, false);
        _expectDrift(0, DriftReason.DebtReserveSet);
        _vtConfig(false, false, false);
        _key(3000, 10_500, 1);
        _expectDrift(mid, DriftReason.LiquidationFeeNonZero);
        _key(3000, 10_500, 0);
        rHub.setReinvestment(VT_ASSET, makeAddr("controller"));
        _expectDrift(mid, DriftReason.ReinvestmentController);
    }

    // TEST-181 verifies: REQ-ADAPTER-031, REQ-ADAPTER-032, REQ-ADAPTER-034, REQ-RISK-088
    function test_TEST_181_hubAssetAndSources() public {
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (address(spoke), feeReceiver, makeAddr("secondSpoke"));
        rHub.setSpokes(VT_ASSET, three);
        _expectDrift(mid, DriftReason.ExtraSpoke);
        address[] memory two = new address[](2);
        (two[0], two[1]) = (address(spoke), makeAddr("secondSpoke"));
        rHub.setSpokes(VT_ASSET, two);
        _expectDrift(mid, DriftReason.ExtraSpoke);
        (two[0], two[1]) = (feeReceiver, address(spoke));
        rHub.setSpokes(VT_ASSET, two);
        hub.setSpokeConfig(VT_ASSET, address(spoke), 2_000_000, 1);
        _expectDrift(mid, DriftReason.DrawCapNonZero);
        hub.setSpokeConfig(VT_ASSET, address(spoke), 2_000_000, 0);
        rHub.setDrawn(VT_ASSET, 1);
        _expectDrift(mid, DriftReason.DrawnSharesNonZero);
        rHub.setDrawn(VT_ASSET, 0);
        hub.setSpokeConfig(VT_ASSET, feeReceiver, 1, 0);
        _expectDrift(mid, DriftReason.FeeReceiverAddCap);
        hub.setSpokeConfig(VT_ASSET, feeReceiver, 0, 0);
        aaveOracle.setSource(VT_RESERVE, makeAddr("otherSource"));
        _expectDrift(mid, DriftReason.PriceSource);
        aaveOracle.setSource(VT_RESERVE, address(oracle));
        rHub.setActive(VT_ASSET, address(spoke), true, true);
        _expectDrift(mid, DriftReason.SpokeHalted);
        rHub.setActive(VT_ASSET, address(spoke), true, false);
        _vtConfig(false, false, true);
        _expectDrift(mid, DriftReason.SpokeHalted);
    }

    // TEST-182 verifies: REQ-ADAPTER-063, REQ-ADAPTER-064, REQ-RISK-088
    function test_TEST_182_implementationAndOracle() public {
        rSpoke.setImplSlot(bytes32(uint256(uint160(makeAddr("upgraded")))));
        _expectDrift(0, DriftReason.SpokeImplementation);
        spoke.setImplementation(address(spokeImpl));
        spoke.setOracle(makeAddr("otherOracle"));
        _expectDrift(0, DriftReason.PriceSource);
    }

    // TEST-249 verifies: REQ-RISK-069, REQ-RISK-076, SPEC-CF-001, SPEC-CF-002
    // Sources: 2.7 REQ-RISK-069 example (CF 3,300 above 3,000; bonus 50 bps below 200; target 1.05e18)
    function test_TEST_249_riskConfiguration() public {
        _key(3300, 10_500, 0);
        _expectDrift(mid, DriftReason.CollateralFactorAboveExpected);
        _key(3000, 40_000, 0);
        _expectDrift(mid, DriftReason.BonusBoundViolated);
        _key(3000, 10_500, 0);
        spoke.setLiquidationConfig(1.1e18, 1000);
        _expectDrift(mid, DriftReason.BonusBoundViolated);
        spoke.setLiquidationConfig(1.05e18, 5000);
        _expectDrift(0, DriftReason.LiquidationConfigChanged);
        // While `deployCdpSpoke` runs the expectation is not written yet (0) and the target is not compared.
        store.setLiquidationExpectations(address(spoke), 0, 200);
        riskModule.checkAaveConfig(address(spoke), _ids());
    }

    // TEST-204 verifies: REQ-RISK-063, REQ-ADAPTER-034, PROP-061
    function test_TEST_204_debtReserveSet() public {
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (makeAddr("weth"), address(hub), 9, 18);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        spoke.setReserve(3, r, c, IAaveV4Spoke.DynamicReserveConfig(0, 0, 0));
        rSpoke.setReserveCount(4);
        _expectDrift(0, DriftReason.DebtReserveSet);
        c.borrowable = false;
        rSpoke.setConfig(3, c);
        aaveOracle.setSource(GHO_RESERVE, makeAddr("otherGhoSource"));
        _expectDrift(0, DriftReason.DebtPriceSource);
    }

    // TEST-112 verifies: REQ-ADAPTER-035
    function test_TEST_112_collateralRiskThreshold() public {
        rHub.setThreshold(GHO_ASSET, address(spoke), 500);
        rSpoke.setCollateralRisk(VT_RESERVE, 499);
        riskModule.checkAaveConfig(address(spoke), _ids());
        rSpoke.setCollateralRisk(VT_RESERVE, 500);
        _expectDrift(mid, DriftReason.CollateralRiskAboveThreshold);
    }

    // TEST-268 verifies: REQ-RISK-090, REQ-RISK-078, SPEC-BRK-008
    // Sources: 2.7 REQ-RISK-090 example (receiveSharesEnabled turned on)
    function test_TEST_268_pokeConfigEmitsAndLatches() public {
        assertEq(uint8(riskModule.pokeConfig(address(spoke))), uint8(DriftReason.None));
        _vtConfig(true, false, false);
        vm.expectEmit(address(riskModule));
        emit IRiskModuleChecks.ConfigDriftDetected(address(spoke), DriftReason.ReceiveSharesOn);
        assertEq(uint8(riskModule.pokeConfig(address(spoke))), uint8(DriftReason.ReceiveSharesOn));
        (uint32 latched,) = registry.marketBreaker(mid);
        assertEq(latched, BreakerReasons.CONFIG_DRIFT);
        // The setting restored, borrowing stays closed until an authorized reset.
        _vtConfig(false, false, false);
        _debt(1.5e18, 1000);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.CONFIG_DRIFT)
        );
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.prank(emergencyGuardian);
        registry.resetMarketBreaker(mid);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.UnknownSpoke.selector, address(this)));
        riskModule.pokeConfig(address(this));
    }

    // TEST-028 verifies: REQ-ADAPTER-037, SPEC-CF-001
    // Sources: 2.7 SPEC-CF-001 example (CF_USDC 7,800, CF_USDT 7,500, poolRiskFactor 4,000 give 3,000)
    function test_TEST_028_sharesAndExpectedFactor() public {
        assertTrue(riskModule.isHubSharesEqualAssets(mid));
        rHub.setAdded(VT_ASSET, 10, 11);
        assertFalse(riskModule.isHubSharesEqualAssets(mid));
        assertEq(riskModule.expectedCollateralFactorBps(mid), 3000);
    }

    // TEST-204 verifies: REQ-ADAPTER-022, REQ-ADAPTER-033, REQ-RISK-063
    function test_TEST_204_debtReserveIdentityAndController() public {
        // The enabled GHO reserve no longer matches its definition: a Spoke-wide reason, market 0.
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(gho), address(hub), uint16(GHO_ASSET), 6);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        spoke.setReserve(GHO_RESERVE, r, c, IAaveV4Spoke.DynamicReserveConfig(0, 0, 0));
        _expectDrift(0, DriftReason.DebtReserveMismatch);
        _setGhoReserve();
        riskModule.checkAaveConfig(address(spoke), _ids());
        // A reinvestment controller on the debt reserve's funding-Hub asset: Spoke-wide, market 0.
        rHub.setReinvestment(GHO_ASSET, makeAddr("controller"));
        _expectDrift(0, DriftReason.ReinvestmentController);
    }

    // TEST-181 verifies: REQ-ADAPTER-028, REQ-RISK-029
    function test_TEST_181_reserveIdentity() public {
        // A market that is not on the checked Spoke (here: no record at all) fails its reserve identity.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 999, DriftReason.ReserveIdentity)
        );
        riskModule.checkAaveConfig(address(spoke), ids);
        // The vault-token reserve reports other decimals than the vault token's.
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (vaultToken, address(hub), uint16(VT_ASSET), 6);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (3000, 10_500);
        spoke.setReserve(VT_RESERVE, r, c, d);
        _expectDrift(mid, DriftReason.ReserveIdentity);
        // Another underlying.
        (r.underlying, r.decimals) = (address(usdc), 18);
        spoke.setReserve(VT_RESERVE, r, c, d);
        _expectDrift(mid, DriftReason.ReserveIdentity);
        (r.underlying, r.hub) = (vaultToken, makeAddr("otherHub"));
        spoke.setReserve(VT_RESERVE, r, c, d);
        _expectDrift(mid, DriftReason.ReserveIdentity);
        r.hub = address(hub);
        spoke.setReserve(VT_RESERVE, r, c, d);
        riskModule.checkAaveConfig(address(spoke), _ids());
    }

    // TEST-181 verifies: REQ-ADAPTER-028, REQ-RISK-029
    function test_TEST_181_homeHubMismatch() public {
        // The registry refuses to list a market on a Spoke with another home Hub; a record that names another Hub
        // still fails closed.
        Market memory m = registry.getMarket(mid);
        m.hub = makeAddr("otherHub");
        vm.mockCall(address(registry), abi.encodeWithSelector(registry.getMarket.selector, mid), abi.encode(m));
        _expectDrift(mid, DriftReason.HomeHubMismatch);
    }

    // TEST-268 verifies: REQ-ADAPTER-029, REQ-RISK-063
    function test_TEST_268_borrowableVaultTokenReserve() public {
        // A vault-token reserve the registry also reports as an enabled debt reserve passes the Spoke-wide set
        // check, and the per-market flag check still refuses it.
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(registry.isApprovedDebtReserve.selector, address(spoke), VT_RESERVE),
            abi.encode(true)
        );
        _vtConfig(false, true, false);
        _expectDrift(mid, DriftReason.Borrowable);
    }

    // TEST-028 verifies: SPEC-CF-001
    function test_TEST_028_expectedFactorOfMarketWithoutTokens() public view {
        assertEq(riskModule.expectedCollateralFactorBps(999), 0);
    }

    // TEST-268 verifies: REQ-RISK-090, REQ-RISK-078, REQ-ADAPTER-063, SPEC-BRK-008
    function test_TEST_268_pokeConfigSpokeWideDrift() public {
        rSpoke.setImplSlot(bytes32(uint256(uint160(makeAddr("upgraded")))));
        vm.expectEmit(address(riskModule));
        emit IRiskModuleChecks.ConfigDriftDetected(address(spoke), DriftReason.SpokeImplementation);
        assertEq(uint8(riskModule.pokeConfig(address(spoke))), uint8(DriftReason.SpokeImplementation));
        (uint32 latched,) = registry.marketBreaker(mid);
        assertEq(latched, BreakerReasons.CONFIG_DRIFT);
        // The breaker poke sees the same drift as a live reason.
        assertEq(riskModule.liveBreakerReasons(mid), BreakerReasons.CONFIG_DRIFT);
    }

    // TEST-268 verifies: REQ-RISK-090, REQ-RISK-078, SPEC-BRK-008
    function test_TEST_268_pokeConfigSkipsMarketsNotLive() public {
        uint256 registered = _listRegisteredMarket();
        // Asked for explicitly, the Registered market fails: its reserve is not configured yet.
        uint256[] memory ids = new uint256[](1);
        ids[0] = registered;
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, registered, DriftReason.ReserveIdentity)
        );
        riskModule.checkAaveConfig(address(spoke), ids);
        // The poke checks only Active and Offboarding markets, so it finds no drift.
        assertEq(uint8(riskModule.pokeConfig(address(spoke))), uint8(DriftReason.None));
        (uint32 latched,) = registry.marketBreaker(registered);
        assertEq(latched, 0);
        // A drift on the Offboarding market latches it, and only it.
        vm.prank(address(timelock));
        registry.setMarketOffboarding(mid);
        _vtConfig(true, false, false);
        assertEq(uint8(riskModule.pokeConfig(address(spoke))), uint8(DriftReason.ReceiveSharesOn));
        (latched,) = registry.marketBreaker(mid);
        assertEq(latched, BreakerReasons.CONFIG_DRIFT);
        (latched,) = registry.marketBreaker(registered);
        assertEq(latched, 0);
    }
}
