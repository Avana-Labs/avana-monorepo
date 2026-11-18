// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {DebtReserveDef, RiskTier, SpokeDef} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {MarketDef} from "../../src/types/MarketTypes.sol";
import {PositionShape, ShapeKind} from "../../src/types/PositionTypes.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryAaveOracleMock, RegistryHubMock, RegistrySpokeMock} from "../utils/mocks/MarketRegistryAaveMocks.sol";
import {
    RegistryAvanaFirstLossReserveMock,
    RegistryFeedMock,
    RegistryFlashSourceMock,
    RegistryLPOracleMock,
    RegistryLPVaultMock,
    RegistryTokenMock
} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice Paths the other suites leave out: a debt reserve before any flash source is set, a credit line with no
/// First-Loss Reserve, a cross-Hub reserve whose funding Hub never consented, and a primary route whose answer reaches
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
        ghoCoverage = new RegistryAvanaFirstLossReserveMock(address(hub), address(gho), GHO_ASSET);
        ghoCoverage.setFunded(4e24, false);
        vm.startPrank(address(timelock));
        factory.registerIntegration(V3, address(lpVault));
        registry.recordHub(address(hub), RiskTier.Stable);
        registry.registerIntegration(V3, address(lpVault), makeAddr("clPricing"));
        registry.deployCdpSpoke(_spokeDef());
        hub.setAsset(address(gho), GHO_ASSET);
        registry.setAvanaFirstLossReserve(address(hub), address(gho), address(ghoCoverage));
        vm.stopPrank();
        _setGhoReserve();
        _listTokenWithProbe(address(gho), "gho", IssuerProbe.None);
        assertEq(registry.flashSource(), address(0));
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.InvalidDebtReserve.selector, bytes32("flash")));
        registry.enableDebtReserve(address(spoke), _ghoDef());
        // Once a source lends GHO, the same definition is accepted.
        flash = new RegistryFlashSourceMock(aaveV3Pool, address(lpVaultSwap));
        vm.startPrank(address(timelock));
        registry.setFlashSource(address(flash));
        registry.enableDebtReserve(address(spoke), _ghoDef());
        vm.stopPrank();
        assertTrue(registry.isApprovedDebtReserve(address(spoke), GHO_RESERVE));
    }

    // TEST-139 verifies: REQ-CONFIG-035
    // A primary route whose result reaches 2^96 fails the raw-price bound even though its raw answer is below 2^96:
    // an answer of 2^95 at 1 decimal reads 2^95 x 10^7 at 8 decimals.
    function test_TEST_139_primaryAnswerAtTwoToTheNinetySixRefused() public {
        _setUpWorld();
        address t = address(new RegistryTokenMock(6));
        RegistryFeedMock big = new RegistryFeedMock(1, int256(2 ** 95));
        ps.setFeed(address(big), 1, 86_400, 25, 25);
        (, address[] memory a) = _routes("t");
        address[] memory p = new address[](1);
        p[0] = address(big);
        vm.prank(address(timelock));
        registry.listToken(t, _tokenDef(p, a));
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), t);
        lpVault.setPoolTokens(toks, 18);
        PositionShape memory sh = PositionShape(ShapeKind.TickRange, -10, 10);
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, sh);
        MarketDef memory d = _marketDef(vt, address(o));
        d.shape = sh;
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.ListingCheckFailed.selector, bytes32("rawPrice")));
        registry.listCollateralMarket(d);
        // At 2^95 / 10^8 (still at 1 decimal) the route reads below 2^96 and the bound itself decides.
        big.setAnswer(int256(uint256(2 ** 95) / 1e8));
        vm.prank(address(timelock));
        assertEq(registry.listCollateralMarket(d), 1);
    }
}
