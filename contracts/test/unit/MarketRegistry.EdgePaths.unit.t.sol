// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryCreditLines} from "../../src/policy/market-registry/IMarketRegistryCreditLines.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryAaveOracleMock, RegistryHubMock, RegistrySpokeMock} from "../utils/mocks/MarketRegistryAaveMocks.sol";
import {
    RegistryCoverageSpokeMock,
    RegistryFeedMock,
    RegistryFlashSourceMock,
    RegistryLPOracleMock,
    RegistryLPVaultMock,
    RegistryTokenMock
} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice Paths the other suites leave out: a debt reserve before any flash source is set, a credit line with no
/// Coverage Spoke, a cross-Hub reserve whose funding Hub never consented, and a primary route whose answer reaches
/// 2^96 at its own decimals.
contract MarketRegistryEdgePathsUnitTest is MarketRegistryFixture {
    // TEST-285 verifies: REQ-MREG-006, INV-095, Q-386
    // Sources: 5.1 TEST-285
    // Before the chain's flash source is set no debt reserve can be enabled: "flash".
    function test_TEST_285_noFlashSourceNoDebtReserve() public {
        _deployRegistry();
        hub = new RegistryHubMock();
        spoke = new RegistrySpokeMock();
        aaveOracle = new RegistryAaveOracleMock();
        spoke.setOracle(address(aaveOracle));
        spoke.setImplementation(address(spokeImpl));
        aaveOracle.setSpoke(address(spoke));
        lpVault = new RegistryLPVaultMock(V3, address(collat), lockAddr);
        lpVault.setRegistry(address(registry));
        gho = new RegistryTokenMock(18);
        ghoSource = new RegistryFeedMock(8, 1e8);
        ghoCoverage = new RegistryCoverageSpokeMock(address(hub), address(gho), GHO_ASSET);
        ghoCoverage.setFunded(4e24, false);
        vm.startPrank(address(timelock));
        factory.registerIntegration(V3, address(lpVault));
        registry.recordHub(address(hub), RiskTier.Stable);
        registry.registerIntegration(V3, address(lpVault), makeAddr("clPricing"));
        registry.deployCdpSpoke(_spokeDef());
        hub.setAsset(address(gho), GHO_ASSET);
        registry.setCoverageSpoke(address(hub), address(gho), address(ghoCoverage));
        registry.recordCreditLine(address(hub), address(gho), 20_000_000);
        vm.stopPrank();
        _setGhoReserve();
        _listTokenWithProbe(address(gho), "gho", IssuerProbe.None);
        assertEq(registry.flashSource(), address(0));
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidDebtReserve.selector, bytes32("flash")));
        registry.enableDebtReserve(address(spoke), _ghoDef());
        // Once a source lends GHO, the same definition is accepted.
        flash = new RegistryFlashSourceMock(aaveV3Pool, address(lpVaultSwap));
        vm.startPrank(address(timelock));
        registry.setFlashSource(address(flash));
        registry.enableDebtReserve(address(spoke), _ghoDef());
        vm.stopPrank();
        assertTrue(registry.isApprovedDebtReserve(address(spoke), GHO_RESERVE));
    }

    // TEST-273 verifies: REQ-CONFIG-081, SPEC-CAP-010, REQ-MREG-009
    // Sources: 5.1 TEST-273
    // A line on an asset with no Coverage Spoke counts as unfunded: any line above 0 is refused with funded 0; a line
    // of 0 needs nothing.
    function test_TEST_273_lineWithoutCoverageSpokeIsUnfunded() public {
        _setUpWorld();
        // ceil(1 x 10^6 x 2,000 / 10^4) = 200,000 base units required, none funded.
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CoverageBelowRatio.selector, address(hub), address(usdt), 200_000, 0
            )
        );
        registry.recordCreditLine(address(hub), address(usdt), 1);
        vm.prank(address(timelock));
        registry.recordCreditLine(address(hub), address(usdt), 0);
        (uint256 required, uint256 funded) = registry.creditLineCoverage(address(hub), address(usdt));
        assertEq(required + funded, 0);
    }

    // TEST-273 verifies: REQ-CONFIG-081, REQ-MREG-009, ATTACK-163, Q-378
    // A cross-Hub reserve needs the funding Hub's own credit line for the asset, even when the line to the Spoke is
    // open: FundingHubConsentMissing(fundingHub, asset).
    function test_TEST_273_crossHubReserveWithoutFundingHubLine() public {
        _setUpWorld();
        RegistryHubMock hub2 = new RegistryHubMock();
        RegistrySpokeMock spoke2 = new RegistrySpokeMock();
        RegistryAaveOracleMock oracle2 = new RegistryAaveOracleMock();
        spoke2.setOracle(address(oracle2));
        spoke2.setImplementation(address(spokeImpl));
        oracle2.setSpoke(address(spoke2));
        RegistryTokenMock dai = new RegistryTokenMock(18);
        _listToken(address(dai), "dai");
        hub.setAsset(address(dai), 4);
        RegistryCoverageSpokeMock daiCoverage = new RegistryCoverageSpokeMock(address(hub), address(dai), 4);
        daiCoverage.setFunded(1e30, false);
        vm.startPrank(address(timelock));
        registry.recordHub(address(hub2), RiskTier.Correlated);
        registry.deployCdpSpoke(
            SpokeDef(false, address(hub2), V3, RiskTier.Correlated, address(spokeImpl), address(oracle2))
        );
        registry.setCoverageSpoke(address(hub), address(dai), address(daiCoverage));
        registry.setCrossHubLinesEnabled(true);
        registry.setCrossHubLine(address(hub), address(dai), address(spoke2), 1e24);
        vm.stopPrank();
        DebtReserveDef memory d = DebtReserveDef({
            reserveId: 3,
            asset: address(dai),
            decimals: 18,
            fundingHub: address(hub),
            hubAssetId: 4,
            priceSource: address(ghoSource),
            fixedPrice: true,
            coverageSpoke: address(daiCoverage),
            crossHub: true,
            approved: false
        });
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.FundingHubConsentMissing.selector, address(hub), address(dai)
            )
        );
        registry.enableDebtReserve(address(spoke2), d);
        // The closed line is reported before the missing consent.
        vm.prank(address(timelock));
        registry.setCrossHubLine(address(hub), address(dai), address(spoke2), 0);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryHubs.CrossHubLineClosed.selector, address(hub), address(dai), address(spoke2)
            )
        );
        registry.enableDebtReserve(address(spoke2), d);
    }

    // TEST-139 verifies: REQ-CONFIG-035
    // A primary route whose result reaches 2^96 fails the raw-price bound even though its raw answer is below 2^96:
    // an answer of 2^95 at 1 decimal reads 2^95 x 10^7 at 8 decimals.
    function test_TEST_139_primaryAnswerAtTwoToTheNinetySixRefused() public {
        _setUpWorld();
        address t = address(new RegistryTokenMock(6));
        RegistryFeedMock big = new RegistryFeedMock(1, int256(2 ** 95));
        ps.setFeed(address(big), 1, 86_400, 25, 25);
        (, address[] memory a, address[] memory s) = _routes("t");
        address[] memory p = new address[](1);
        p[0] = address(big);
        vm.prank(address(timelock));
        registry.listToken(t, _tokenDef(p, a, s));
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), t);
        lpVault.setPoolTokens(toks, 18);
        PositionShape memory sh = PositionShape(ShapeKind.TickRange, -10, 10);
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, sh);
        MarketDef memory d = _marketDef(vt, address(o));
        d.shape = sh;
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("rawPrice")));
        registry.listCollateralMarket(d);
        // At 2^95 / 10^8 (still at 1 decimal) the route reads below 2^96 and the bound itself decides.
        big.setAnswer(int256(uint256(2 ** 95) / 1e8));
        vm.prank(address(timelock));
        assertEq(registry.listCollateralMarket(d), 1);
    }
}
