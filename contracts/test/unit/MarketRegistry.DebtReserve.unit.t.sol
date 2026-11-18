// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {
    DebtReserveDef,
    RiskTier,
    SpokeDef,
    TokenDef
} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
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
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.InvalidDebtReserve.selector, check));
        registry.enableDebtReserve(address(spoke), d);
    }

    // TEST-185 verifies: REQ-MREG-006, REQ-MREG-007, REQ-MREG-008, REQ-MREG-009, REQ-CONFIG-079, Q-233, Q-238
    // Sources: 5.1 TEST-185, TEST-139
    function test_TEST_185_enableUsdcWithItsDebtOracle() public {
        _setRoute(marketId, address(usdt), address(usdc), 0, "dexE");
        _setRoute(marketId, address(usdt), address(usdc), 1, "dexF");
        vm.expectEmit(address(registry));
        emit IMarketRegistryBase.DebtReserveApproved(
            address(spoke),
            USDC_RESERVE,
            address(usdc),
            address(hub),
            USDC_ASSET,
            address(usdcOracle),
            address(usdcCoverage)
        );
        _enable(_usdcDef());
        assertTrue(registry.isApprovedDebtReserve(address(spoke), USDC_RESERVE));
        uint256[] memory ids = registry.getDebtReserveIds(address(spoke));
        assertEq(ids.length, 2);
        assertEq(ids[1], USDC_RESERVE);
        DebtReserveDef memory rec = registry.getDebtReserve(address(spoke), USDC_RESERVE);
        assertTrue(rec.approved);
        assertEq(rec.firstLossReserve, address(usdcCoverage));
        (uint256 sum,,) = registry.drawCapCoverage(address(hub), address(usdc));
        assertEq(sum, 500_000, "the Spoke's draw cap is covered");
        // The DebtOracle and the First-Loss Reserve are now protected from the address freeze.
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.ProtectedAddress.selector, address(usdcOracle)));
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
            approved: false
        });
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.TokenNotListed.selector, address(dai)));
        registry.enableDebtReserve(address(spoke), def);
        // GHO, the fixture's fixed-price reserve, was enabled only after its listing with an issuer probe.
        assertTrue(registry.getToken(address(gho)).listed);
        assertTrue(registry.getToken(address(gho)).issuerProbe == IssuerProbe.None);
    }

    // TEST-185 verifies: REQ-MREG-006, REQ-CONFIG-081, REQ-MREG-009
    function test_TEST_185_firstLossReserveChecks() public {
        DebtReserveDef memory d = _usdcDef();
        d.firstLossReserve = address(ghoCoverage);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistry.AvanaFirstLossReserveMismatch.selector,
                address(hub),
                address(usdc),
                address(ghoCoverage)
            )
        );
        registry.enableDebtReserve(address(spoke), d);
        usdcCoverage.setFunded(2e12, true);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.CoverageNotFunded.selector, address(hub), address(usdc)));
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
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.TransferFeeActive.selector, address(usdtLike)));
        registry.enableDebtReserve(address(spoke), d);
        usdtLike.setFee(0, true);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.TransferFeeActive.selector, address(usdtLike)));
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
            abi.encodeWithSelector(IMarketRegistryBase.LivenessBound.selector, address(spoke), marketId, USDC_RESERVE)
        );
        registry.enableDebtReserve(address(spoke), _usdcDef());
        _setRoute(marketId, address(usdt), address(usdc), 0, "dexE");
        _setRoute(marketId, address(usdt), address(usdc), 1, "dexF");
        ps.setLivenessFails(address(spoke), marketId, USDC_RESERVE, true);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryBase.LivenessBound.selector, address(spoke), marketId, USDC_RESERVE)
        );
        registry.enableDebtReserve(address(spoke), _usdcDef());
        ps.setLivenessFails(address(spoke), marketId, USDC_RESERVE, false);
        _enable(_usdcDef());
    }

    // TEST-273 verifies: REQ-CONFIG-081
    function test_TEST_273_specExampleCoverageRatio() public {
        // 20,000,000 USDC of draw caps at 2,000 bps needs 4,000,000 USDC: 3,900,000 USDC reverts, 4,000,000 enables.
        ps.setCoverageRatioBps(2000);
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, 20_000_000);
        usdcCoverage.setFunded(3.9e12, false);
        _setRoute(marketId, address(usdt), address(usdc), 0, "dexE");
        _setRoute(marketId, address(usdt), address(usdc), 1, "dexF");
        DebtReserveDef memory d = _usdcDef();
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistry.CoverageBelowRatio.selector, address(hub), address(usdc), 4e12, 3.9e12
            )
        );
        registry.enableDebtReserve(address(spoke), d);
        usdcCoverage.setFunded(4e12, false);
        _enable(d);
        (uint256 sum, uint256 required, uint256 funded) = registry.drawCapCoverage(address(hub), address(usdc));
        assertEq(sum, 20_000_000, "draw cap sum");
        assertEq(required, 4e12, "required");
        assertEq(funded, 4e12, "funded");
    }

    // TEST-213 verifies: REQ-MREG-010, REQ-MREG-033, ATTACK-136, Q-233, Q-397, REQ-ACCESS-145
    // Sources: 5.1 TEST-213, TEST-185
    function test_TEST_213_removeOnlyWithNothingOwed() public {
        _setRoute(marketId, address(usdt), address(usdc), 0, "dexE");
        _setRoute(marketId, address(usdt), address(usdc), 1, "dexF");
        _enable(_usdcDef());
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.UnknownDebtReserve.selector, address(spoke), 9));
        registry.removeDebtReserve(address(spoke), 9);
        // GHO is the settlement reserve of the live market.
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryBase.DebtReserveInUse.selector, address(spoke), GHO_RESERVE)
        );
        registry.removeDebtReserve(address(spoke), GHO_RESERVE);
        vm.stopPrank();
        hub.setOwed(USDC_ASSET, address(spoke), 1, 0);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryBase.DebtReserveInUse.selector, address(spoke), USDC_RESERVE)
        );
        registry.removeDebtReserve(address(spoke), USDC_RESERVE);
        hub.setOwed(USDC_ASSET, address(spoke), 0, 1);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryBase.DebtReserveInUse.selector, address(spoke), USDC_RESERVE)
        );
        registry.removeDebtReserve(address(spoke), USDC_RESERVE);
        hub.setOwed(USDC_ASSET, address(spoke), 0, 0);
        vm.prank(emergencyGuardian);
        registry.tripDebtBreaker(address(spoke), USDC_RESERVE);
        vm.expectEmit(address(registry));
        emit IMarketRegistryBase.DebtReserveRemoved(address(spoke), USDC_RESERVE);
        vm.prank(address(timelock));
        registry.removeDebtReserve(address(spoke), USDC_RESERVE);
        assertFalse(registry.isApprovedDebtReserve(address(spoke), USDC_RESERVE));
        uint256[] memory ids = registry.getDebtReserveIds(address(spoke));
        assertEq(ids.length, 1);
        assertEq(ids[0], GHO_RESERVE);
        (uint32 latched,) = registry.debtBreaker(address(spoke), USDC_RESERVE);
        assertEq(latched, 0);
        (uint256 sum,,) = registry.drawCapCoverage(address(hub), address(usdc));
        assertEq(sum, 0, "the removed reserve's Spoke no longer counts");
    }

    // TEST-273 verifies: REQ-CONFIG-081, SPEC-CAP-010
    // Enabling is refused exactly when the Spoke's draw cap at the ratio needs more than the First-Loss Reserve holds.
    function testFuzz_TEST_273_coverageTestIsExact(
        uint40 cap,
        uint128 funded,
        uint16 ratio
    ) public {
        ratio = uint16(bound(ratio, 1, 10_000));
        cap = uint40(bound(cap, 1, 1e12));
        ps.setCoverageRatioBps(ratio);
        usdcCoverage.setFunded(funded, false);
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, cap);
        _setRoute(marketId, address(usdt), address(usdc), 0, "dexE");
        _setRoute(marketId, address(usdt), address(usdc), 1, "dexF");
        bool covers = uint256(cap) * 1e6 * ratio <= uint256(funded) * 1e4;
        if (!covers) vm.expectPartialRevert(IMarketRegistry.CoverageBelowRatio.selector);
        _enable(_usdcDef());
        assertEq(registry.isApprovedDebtReserve(address(spoke), USDC_RESERVE), covers);
    }
}
