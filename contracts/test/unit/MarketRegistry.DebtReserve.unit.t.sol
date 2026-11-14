// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryCreditLines} from "../../src/policy/market-registry/IMarketRegistryCreditLines.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {TokenDef} from "../../src/policy/market-registry/types/TokenDef.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryAaveOracleMock, RegistryHubMock, RegistrySpokeMock} from "../utils/mocks/MarketRegistryAaveMocks.sol";
import {
    RegistryAvanaFirstLossReserveMock,
    RegistryDebtOracleMock,
    RegistryFeedMock,
    RegistryTetherMock,
    RegistryTokenMock
} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice Debt reserves of a CDP Spoke and the credit-line registry.
contract MarketRegistryDebtReserveUnitTest is MarketRegistryFixture {
    uint256 internal constant USDC_RESERVE = 5;
    uint256 internal constant USDC_ASSET = 2;
    RegistryDebtOracleMock internal usdcOracle;
    RegistryAvanaFirstLossReserveMock internal usdcCoverage;
    uint256 internal marketId;

    function setUp() public {
        _setUpWorld();
        (marketId,,) = _activeMarket();
        usdcOracle = new RegistryDebtOracleMock(address(usdc), address(registry), address(ps));
        usdcCoverage = new RegistryAvanaFirstLossReserveMock(address(hub), address(usdc), USDC_ASSET);
        usdcCoverage.setFunded(2e12, false);
        hub.setAsset(address(usdc), USDC_ASSET);
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, 500_000);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(usdc), address(hub), uint16(USDC_ASSET), 6);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        spoke.setReserve(USDC_RESERVE, r, c, d);
        aaveOracle.setSource(USDC_RESERVE, address(usdcOracle));
        ps.setStressRise(address(usdc), 500);
        vm.startPrank(address(timelock));
        registry.setAvanaFirstLossReserve(address(hub), address(usdc), address(usdcCoverage));
        registry.recordCreditLine(address(hub), address(usdc), 1_000_000);
        vm.stopPrank();
    }

    function _usdcDef() internal view returns (DebtReserveDef memory) {
        return DebtReserveDef({
            reserveId: USDC_RESERVE,
            asset: address(usdc),
            decimals: 6,
            fundingHub: address(hub),
            hubAssetId: USDC_ASSET,
            priceSource: address(usdcOracle),
            fixedPrice: false,
            firstLossReserve: address(usdcCoverage),
            crossHub: false,
            approved: false
        });
    }

    function _enable(
        DebtReserveDef memory d
    ) internal {
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), d);
    }

    function _expectInvalid(
        DebtReserveDef memory d,
        bytes32 check
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidDebtReserve.selector, check));
        registry.enableDebtReserve(address(spoke), d);
    }

    // TEST-185 verifies: REQ-MREG-006, REQ-MREG-007, REQ-MREG-008, REQ-MREG-009, REQ-CONFIG-079, Q-233, Q-238
    // Sources: 5.1 TEST-185, TEST-139
    function test_TEST_185_enableUsdcWithItsDebtOracle() public {
        _setRoute(marketId, address(usdt), address(usdc), 0, "dexE");
        _setRoute(marketId, address(usdt), address(usdc), 1, "dexF");
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.DebtReserveApproved(
            address(spoke),
            USDC_RESERVE,
            address(usdc),
            address(hub),
            USDC_ASSET,
            address(usdcOracle),
            address(usdcCoverage)
        );
        vm.expectEmit(address(registry));
        emit IMarketRegistryCreditLines.CreditLineRecorded(
            address(hub), address(usdc), address(spoke), 500_000, 500_000
        );
        _enable(_usdcDef());
        assertTrue(registry.isApprovedDebtReserve(address(spoke), USDC_RESERVE));
        uint256[] memory ids = registry.getDebtReserveIds(address(spoke));
        assertEq(ids.length, 2);
        assertEq(ids[1], USDC_RESERVE);
        DebtReserveDef memory rec = registry.getDebtReserve(address(spoke), USDC_RESERVE);
        assertTrue(rec.approved);
        assertEq(rec.firstLossReserve, address(usdcCoverage));
        (uint256 line, uint256 sum) = registry.creditLine(address(hub), address(usdc));
        assertEq(line, 1_000_000);
        assertEq(sum, 500_000);
        // The DebtOracle and the First-Loss Reserve are now protected from the address freeze.
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, address(usdcOracle)));
        registry.freezeAddress(address(usdcOracle));
    }

    // TEST-185 verifies: REQ-MREG-006, REQ-MREG-008, REQ-MREG-027, REQ-CONFIG-017
    // Sources: MarketRegistry review 2026-11-10 finding 6 (a fixed-price debt asset must be listed with its probe)
    function test_TEST_185_fixedPriceAssetMustBeListed() public {
        uint256 reserveId = 7;
        uint256 assetId = 4;
        RegistryTokenMock dai = new RegistryTokenMock(18);
        RegistryFeedMock fixedSource = new RegistryFeedMock(8, 1e8);
        hub.setAsset(address(dai), assetId);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(dai), address(hub), uint16(assetId), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        spoke.setReserve(reserveId, r, c, d);
        aaveOracle.setSource(reserveId, address(fixedSource));
        DebtReserveDef memory def = DebtReserveDef({
            reserveId: reserveId,
            asset: address(dai),
            decimals: 18,
            fundingHub: address(hub),
            hubAssetId: assetId,
            priceSource: address(fixedSource),
            fixedPrice: true,
            firstLossReserve: address(0),
            crossHub: false,
            approved: false
        });
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TokenNotListed.selector, address(dai)));
        registry.enableDebtReserve(address(spoke), def);
        // GHO, the fixture's fixed-price reserve, was enabled only after its listing with an issuer probe.
        assertTrue(registry.getToken(address(gho)).listed);
        assertTrue(registry.getToken(address(gho)).issuerProbe == IssuerProbe.None);
    }

    // TEST-273 verifies: REQ-CONFIG-081
    // Sources: MarketRegistry review 2026-11-10 finding 9 (an event for the new credit line)
    function test_TEST_273_recordCreditLineEmitsTheLine() public {
        vm.expectEmit(address(registry));
        emit IMarketRegistryCreditLines.CreditLineSet(address(hub), address(gho), 15_000_000, 1_000_000);
        vm.prank(address(timelock));
        registry.recordCreditLine(address(hub), address(gho), 15_000_000);
        (uint256 line,) = registry.creditLine(address(hub), address(gho));
        assertEq(line, 15_000_000);
        // 15,000,000 GHO at 2,000 bps requires 3e24 base units; the fixture funds 4e24.
        (uint256 required, uint256 funded) = registry.creditLineCoverage(address(hub), address(gho));
        assertEq(required, 3e24);
        assertEq(funded, 4e24);
        // A pair with no line needs nothing.
        (required, funded) = registry.creditLineCoverage(address(hub), address(usdt));
        assertEq(required, 0);
        assertEq(funded, 0);
        // The USDC line of 1,000,000 at 2,000 bps requires 2e11 base units (6 decimals).
        (required,) = registry.creditLineCoverage(address(hub), address(usdc));
        assertEq(required, 2e11);
        // A line too large for 256-bit arithmetic requires the maximum, so the test fails closed.
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CoverageBelowRatio.selector,
                address(hub),
                address(gho),
                type(uint256).max,
                4e24
            )
        );
        registry.recordCreditLine(address(hub), address(gho), type(uint256).max / 1e18);
    }

    // TEST-185 verifies: REQ-MREG-006, REQ-MREG-008, REQ-MREG-018, ATTACK-121
    function test_TEST_185_definitionChecks() public {
        DebtReserveDef memory d = _usdcDef();
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, alice));
        registry.enableDebtReserve(alice, d);
        d.fundingHub = alice;
        _expectInvalid(d, "fundingHub");
        d = _usdcDef();
        d.crossHub = true;
        _expectInvalid(d, "crossHub");
        d = _usdcDef();
        d.hubAssetId = 3;
        _expectInvalid(d, "reserve");
        d = _usdcDef();
        d.decimals = 18;
        _expectInvalid(d, "reserve");
        d = _usdcDef();
        IAaveV4Spoke.ReserveConfig memory c;
        spoke.setConfig(USDC_RESERVE, c);
        _expectInvalid(d, "borrowable");
        c.borrowable = true;
        spoke.setConfig(USDC_RESERVE, c);
        IAaveV4Spoke.DynamicReserveConfig memory dyn;
        dyn.collateralFactor = 1;
        spoke.setDynamic(USDC_RESERVE, dyn);
        _expectInvalid(d, "collateralFactor");
        dyn.collateralFactor = 0;
        spoke.setDynamic(USDC_RESERVE, dyn);
        d.priceSource = address(ghoSource);
        _expectInvalid(d, "priceSource");
        d = _usdcDef();
        RegistryDebtOracleMock foreign = new RegistryDebtOracleMock(address(usdt), address(registry), address(ps));
        aaveOracle.setSource(USDC_RESERVE, address(foreign));
        d.priceSource = address(foreign);
        _expectInvalid(d, "debtOracle");
        aaveOracle.setSource(USDC_RESERVE, address(usdcOracle));
        d = _usdcDef();
        ps.setStressRise(address(usdc), 99);
        _expectInvalid(d, "stressRise");
        ps.setStressRise(address(usdc), 500);
        // Already enabled.
        _expectInvalid(_ghoDef(), "enabled");
    }

    // TEST-185 verifies: REQ-MREG-006, REQ-CONFIG-081, REQ-MREG-009
    function test_TEST_185_firstLossReserveChecks() public {
        DebtReserveDef memory d = _usdcDef();
        d.firstLossReserve = address(ghoCoverage);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.AvanaFirstLossReserveMismatch.selector,
                address(hub),
                address(usdc),
                address(ghoCoverage)
            )
        );
        registry.enableDebtReserve(address(spoke), d);
        usdcCoverage.setFunded(2e12, true);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryCreditLines.CoverageNotFunded.selector, address(hub), address(usdc))
        );
        registry.enableDebtReserve(address(spoke), _usdcDef());
    }

    // TEST-285 verifies: REQ-MREG-006, INV-095, Q-386, Q-388
    function test_TEST_285_flashSourceMustLendTheAsset() public {
        flash.setLiquidity(0, 5);
        _expectInvalid(_usdcDef(), "flash");
        flash.setLiquidity(1e30, 11);
        _expectInvalid(_usdcDef(), "flash");
        flash.setLiquidity(1e30, 10);
        flash.setLender(address(hub));
        _expectInvalid(_usdcDef(), "flash");
    }

    // TEST-287 verifies: REQ-MREG-006, REQ-SWAP-123, ATTACK-197, Q-390
    function test_TEST_287_transferFeeRefusedAtEnablement() public {
        RegistryTetherMock usdtLike = new RegistryTetherMock();
        (address[] memory p, address[] memory a, address[] memory s) = _routes("usdt2");
        TokenDef memory td = _tokenDef(p, a, s);
        td.issuerProbe = IssuerProbe.UsdtFeeRate;
        vm.prank(address(timelock));
        registry.listToken(address(usdtLike), td);
        DebtReserveDef memory d = _usdcDef();
        RegistryDebtOracleMock o = new RegistryDebtOracleMock(address(usdtLike), address(registry), address(ps));
        RegistryAvanaFirstLossReserveMock cs = new RegistryAvanaFirstLossReserveMock(address(hub), address(usdtLike), 3);
        cs.setFunded(1e13, false);
        hub.setAsset(address(usdtLike), 3);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(usdtLike), address(hub), 3, 6);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory dyn;
        spoke.setReserve(6, r, c, dyn);
        aaveOracle.setSource(6, address(o));
        ps.setStressRise(address(usdtLike), 500);
        vm.prank(address(timelock));
        registry.setAvanaFirstLossReserve(address(hub), address(usdtLike), address(cs));
        (d.reserveId, d.asset, d.hubAssetId, d.priceSource, d.firstLossReserve) =
        (6, address(usdtLike), 3, address(o), address(cs));
        usdtLike.setFee(1, false);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TransferFeeActive.selector, address(usdtLike)));
        registry.enableDebtReserve(address(spoke), d);
        usdtLike.setFee(0, true);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TransferFeeActive.selector, address(usdtLike)));
        registry.enableDebtReserve(address(spoke), d);
        usdtLike.setFee(0, false);
        _setRoute(marketId, address(usdc), address(usdtLike), 0, "dexG");
        _setRoute(marketId, address(usdc), address(usdtLike), 1, "dexH");
        _setRoute(marketId, address(usdt), address(usdtLike), 0, "dexI");
        _setRoute(marketId, address(usdt), address(usdtLike), 1, "dexJ");
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), d);
    }

    // TEST-245 verifies: REQ-MREG-032, REQ-CONFIG-039, Q-261, REQ-ACCESS-145, REQ-ACCESS-095
    // Sources: 5.1 TEST-245, MATH-ST-13
    function test_TEST_245_livenessAgainstLiveMarkets() public {
        // The Active market has no USDT -> USDC route yet.
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.LivenessBound.selector, address(spoke), marketId, USDC_RESERVE)
        );
        registry.enableDebtReserve(address(spoke), _usdcDef());
        _setRoute(marketId, address(usdt), address(usdc), 0, "dexE");
        _setRoute(marketId, address(usdt), address(usdc), 1, "dexF");
        ps.setLivenessFails(address(spoke), marketId, USDC_RESERVE, true);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.LivenessBound.selector, address(spoke), marketId, USDC_RESERVE)
        );
        registry.enableDebtReserve(address(spoke), _usdcDef());
        ps.setLivenessFails(address(spoke), marketId, USDC_RESERVE, false);
        _enable(_usdcDef());
    }

    // TEST-273 verifies: REQ-CONFIG-081, SPEC-CAP-010, ATTACK-163, Q-353, Q-391, REQ-ACCESS-145
    // Sources: 5.1 TEST-273, MATH-CAP-10
    function test_TEST_273_creditLineSumAndCoverage() public {
        _setRoute(marketId, address(usdt), address(usdc), 0, "dexE");
        _setRoute(marketId, address(usdt), address(usdc), 1, "dexF");
        // Draw cap above the line.
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, 1_000_001);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CreditLineExceeded.selector,
                address(hub),
                address(usdc),
                1_000_001,
                1_000_000
            )
        );
        registry.enableDebtReserve(address(spoke), _usdcDef());
        // MAX_ALLOWED_SPOKE_CAP counts as unbounded.
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, type(uint40).max);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CreditLineExceeded.selector, address(hub), address(usdc), 2 ** 128, 1_000_000
            )
        );
        registry.enableDebtReserve(address(spoke), _usdcDef());
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, 400_000);
        _enable(_usdcDef());
        // A line below the recorded sum is refused.
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CreditLineExceeded.selector, address(hub), address(usdc), 400_000, 399_999
            )
        );
        registry.recordCreditLine(address(hub), address(usdc), 399_999);
        // Coverage: 2e12 base units at 2,000 bps covers a 10,000,000 USDC line exactly.
        vm.prank(address(timelock));
        registry.recordCreditLine(address(hub), address(usdc), 10_000_000);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CoverageBelowRatio.selector, address(hub), address(usdc), 2.0000002e12, 2e12
            )
        );
        registry.recordCreditLine(address(hub), address(usdc), 10_000_001);
        // A raised draw cap is always synced; the sum may then exceed the line and is recorded.
        vm.prank(address(timelock));
        registry.recordCreditLine(address(hub), address(usdc), 500_000);
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, 600_000);
        vm.expectEmit(address(registry));
        emit IMarketRegistryCreditLines.CreditLineRecorded(
            address(hub), address(usdc), address(spoke), 600_000, 600_000
        );
        vm.prank(keeper);
        registry.syncDrawCap(address(spoke), USDC_RESERVE);
        (, uint256 sum) = registry.creditLine(address(hub), address(usdc));
        assertEq(sum, 600_000);
        // A raise while coverage is short is recorded too (never hidden); the coverage view reports the shortfall,
        // which the borrow gate reads separately.
        usdcCoverage.setFunded(1, false);
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, 700_000);
        vm.prank(keeper);
        registry.syncDrawCap(address(spoke), USDC_RESERVE);
        (, sum) = registry.creditLine(address(hub), address(usdc));
        assertEq(sum, 700_000);
        (uint256 required, uint256 funded) = registry.creditLineCoverage(address(hub), address(usdc));
        assertEq(required, 1e11);
        assertEq(funded, 1);
        // A cut is always recorded.
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, 100_000);
        registry.syncDrawCap(address(spoke), USDC_RESERVE);
        (, sum) = registry.creditLine(address(hub), address(usdc));
        assertEq(sum, 100_000);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownDebtReserve.selector, address(spoke), 9));
        registry.syncDrawCap(address(spoke), 9);
    }

    // TEST-273 verifies: REQ-CONFIG-081, SPEC-CAP-010, Q-378
    // Two CDP Spokes draw on the Hub's one USDC credit line (the second through a cross-Hub line): a sync replaces only
    // the synced reserve's share of the recorded sum.
    function test_TEST_273_syncReplacesOnlyItsOwnShareOfTheLine() public {
        _setRoute(marketId, address(usdt), address(usdc), 0, "dexE");
        _setRoute(marketId, address(usdt), address(usdc), 1, "dexF");
        RegistryHubMock hub2 = new RegistryHubMock();
        RegistrySpokeMock spoke2 = new RegistrySpokeMock();
        RegistryAaveOracleMock oracle2 = new RegistryAaveOracleMock();
        spoke2.setOracle(address(oracle2));
        spoke2.setImplementation(address(spokeImpl));
        oracle2.setSpoke(address(spoke2));
        vm.startPrank(address(timelock));
        registry.recordHub(address(hub2), RiskTier.Correlated);
        registry.deployCdpSpoke(
            SpokeDef(false, address(hub2), V3, RiskTier.Correlated, address(spokeImpl), address(oracle2))
        );
        registry.setCrossHubLinesEnabled(true);
        registry.setCrossHubLine(address(hub), address(usdc), address(spoke2), 300_000e6);
        vm.stopPrank();
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(usdc), address(hub), uint16(USDC_ASSET), 6);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        spoke2.setReserve(USDC_RESERVE, r, c, d);
        oracle2.setSource(USDC_RESERVE, address(usdcOracle));
        hub.setSpokeConfig(USDC_ASSET, address(spoke2), 0, 200_000);
        _enable(_usdcDef());
        DebtReserveDef memory cross = _usdcDef();
        cross.crossHub = true;
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke2), cross);
        (, uint256 sum) = registry.creditLine(address(hub), address(usdc));
        assertEq(sum, 700_000);
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, 600_000);
        registry.syncDrawCap(address(spoke), USDC_RESERVE);
        (, sum) = registry.creditLine(address(hub), address(usdc));
        assertEq(sum, 800_000, "700,000 - 500,000 + 600,000");
        hub.setSpokeConfig(USDC_ASSET, address(spoke2), 0, 50_000);
        registry.syncDrawCap(address(spoke2), USDC_RESERVE);
        (, sum) = registry.creditLine(address(hub), address(usdc));
        assertEq(sum, 650_000, "800,000 - 200,000 + 50,000");
    }

    // TEST-273 verifies: REQ-CONFIG-081
    function test_TEST_273_specExampleCoverageRatio() public {
        // 20,000,000 GHO at 2,000 bps needs 4,000,000 GHO; 3,900,000 GHO reverts with the spec's numbers.
        ghoCoverage.setFunded(3.9e24, false);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CoverageBelowRatio.selector, address(hub), address(gho), 4e24, 3.9e24
            )
        );
        registry.recordCreditLine(address(hub), address(gho), 20_000_000);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidHub.selector, alice));
        registry.recordCreditLine(alice, address(gho), 1);
    }

    // TEST-273 verifies: REQ-CONFIG-081, REQ-MREG-009, Q-378, REQ-ACCESS-145
    function test_TEST_273_crossHubReserveNeedsLineAndConsent() public {
        RegistryHubMock hub2 = new RegistryHubMock();
        RegistrySpokeMock spoke2 = new RegistrySpokeMock();
        RegistryAaveOracleMock oracle2 = new RegistryAaveOracleMock();
        spoke2.setOracle(address(oracle2));
        spoke2.setImplementation(address(spokeImpl));
        oracle2.setSpoke(address(spoke2));
        vm.startPrank(address(timelock));
        registry.recordHub(address(hub2), RiskTier.Correlated);
        registry.deployCdpSpoke(
            SpokeDef(false, address(hub2), V3, RiskTier.Correlated, address(spokeImpl), address(oracle2))
        );
        vm.stopPrank();
        DebtReserveDef memory d = _ghoDef();
        d.crossHub = true;
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryHubs.CrossHubLinesDisabled.selector);
        registry.enableDebtReserve(address(spoke2), d);
        vm.prank(address(timelock));
        registry.setCrossHubLinesEnabled(true);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryHubs.CrossHubLineClosed.selector, address(hub), address(gho), address(spoke2)
            )
        );
        registry.enableDebtReserve(address(spoke2), d);
        d.crossHub = false;
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidDebtReserve.selector, bytes32("crossHub")));
        registry.enableDebtReserve(address(spoke2), d);
    }

    // TEST-273 verifies: REQ-HUB-103, REQ-CONFIG-081, Q-378
    // A foreign Spoke's draw cap (whole units) must fit its cross-Hub line (base units): one unit above the line
    // reverts CrossHubCapExceeded(drawCap in base units, line); exactly the line passes.
    function test_TEST_273_crossHubDrawCapWithinItsLine() public {
        RegistryHubMock hub2 = new RegistryHubMock();
        RegistrySpokeMock spoke2 = new RegistrySpokeMock();
        RegistryAaveOracleMock oracle2 = new RegistryAaveOracleMock();
        spoke2.setOracle(address(oracle2));
        spoke2.setImplementation(address(spokeImpl));
        oracle2.setSpoke(address(spoke2));
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(usdc), address(hub), uint16(USDC_ASSET), 6);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory dyn;
        spoke2.setReserve(USDC_RESERVE, r, c, dyn);
        oracle2.setSource(USDC_RESERVE, address(usdcOracle));
        vm.startPrank(address(timelock));
        registry.recordHub(address(hub2), RiskTier.Correlated);
        registry.deployCdpSpoke(
            SpokeDef(false, address(hub2), V3, RiskTier.Correlated, address(spokeImpl), address(oracle2))
        );
        registry.setCrossHubLinesEnabled(true);
        registry.setCrossHubLine(address(hub), address(usdc), address(spoke2), 400_000e6);
        vm.stopPrank();
        DebtReserveDef memory d = _usdcDef();
        d.crossHub = true;
        hub.setSpokeConfig(USDC_ASSET, address(spoke2), 0, 400_001);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryHubs.CrossHubCapExceeded.selector, uint256(400_001e6), uint256(400_000e6)
            )
        );
        registry.enableDebtReserve(address(spoke2), d);
        hub.setSpokeConfig(USDC_ASSET, address(spoke2), 0, 400_000);
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke2), d);
        assertTrue(registry.isApprovedDebtReserve(address(spoke2), USDC_RESERVE));
    }

    // TEST-213 verifies: REQ-MREG-010, REQ-MREG-033, ATTACK-136, Q-233, Q-397, REQ-ACCESS-145
    // Sources: 5.1 TEST-213, TEST-185
    function test_TEST_213_removeOnlyWithNothingOwed() public {
        _setRoute(marketId, address(usdt), address(usdc), 0, "dexE");
        _setRoute(marketId, address(usdt), address(usdc), 1, "dexF");
        _enable(_usdcDef());
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownDebtReserve.selector, address(spoke), 9));
        registry.removeDebtReserve(address(spoke), 9);
        // GHO is the settlement reserve of the live market.
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.DebtReserveInUse.selector, address(spoke), GHO_RESERVE)
        );
        registry.removeDebtReserve(address(spoke), GHO_RESERVE);
        vm.stopPrank();
        hub.setOwed(USDC_ASSET, address(spoke), 1, 0);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.DebtReserveInUse.selector, address(spoke), USDC_RESERVE)
        );
        registry.removeDebtReserve(address(spoke), USDC_RESERVE);
        hub.setOwed(USDC_ASSET, address(spoke), 0, 1);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.DebtReserveInUse.selector, address(spoke), USDC_RESERVE)
        );
        registry.removeDebtReserve(address(spoke), USDC_RESERVE);
        hub.setOwed(USDC_ASSET, address(spoke), 0, 0);
        vm.prank(emergencyGuardian);
        registry.tripDebtBreaker(address(spoke), USDC_RESERVE);
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.DebtReserveRemoved(address(spoke), USDC_RESERVE);
        vm.prank(address(timelock));
        registry.removeDebtReserve(address(spoke), USDC_RESERVE);
        assertFalse(registry.isApprovedDebtReserve(address(spoke), USDC_RESERVE));
        uint256[] memory ids = registry.getDebtReserveIds(address(spoke));
        assertEq(ids.length, 1);
        assertEq(ids[0], GHO_RESERVE);
        (uint32 latched,) = registry.debtBreaker(address(spoke), USDC_RESERVE);
        assertEq(latched, 0);
        (, uint256 sum) = registry.creditLine(address(hub), address(usdc));
        assertEq(sum, 0);
    }

    // TEST-273 verifies: REQ-CONFIG-081, SPEC-CAP-010
    function testFuzz_TEST_273_coverageTestIsExact(
        uint64 line,
        uint128 funded,
        uint16 ratio
    ) public {
        ratio = uint16(bound(ratio, 1, 10_000));
        line = uint64(bound(line, 1, 1e12));
        ps.setCoverageRatioBps(ratio);
        usdcCoverage.setFunded(funded, false);
        bool covers = uint256(line) * 1e6 * ratio <= uint256(funded) * 1e4;
        vm.prank(address(timelock));
        if (!covers) vm.expectPartialRevert(IMarketRegistryCreditLines.CoverageBelowRatio.selector);
        registry.recordCreditLine(address(hub), address(usdc), line);
    }
}
