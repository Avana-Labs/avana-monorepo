// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskStatus} from "../../src/amm/types/AmmTypes.sol";
import {ICollateralization} from "../../src/custody/collateralization/ICollateralization.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {MarketDef} from "../../src/types/MarketTypes.sol";
import {PledgeCounters, PositionShape, ShapeKind} from "../../src/types/PositionTypes.sol";
import {ParameterStoreRegistryFixture} from "../utils/fixtures/ParameterStoreRegistryFixture.sol";
import {RegistryLPOracleMock, RegistryRouteMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The real ParameterStore against the real MarketRegistry: every scope check, route read, debt-reserve scan
/// and liveness evaluation of the store reads the registry's own records, and the registry's listing and
/// activation read the store's values back.
contract ParameterStoreMarketRegistryIntegrationTest is ParameterStoreRegistryFixture {
    uint256 internal constant VT_ASSET = 1;
    uint256 internal constant VT_RESERVE = 1;
    bytes internal oob = abi.encodeWithSelector(IParameterStoreBase.OutOfBounds.selector);

    function setUp() public {
        _setUpWorld();
    }

    function _refuses(
        bytes memory data,
        bytes memory err
    ) internal {
        vm.prank(address(timelock));
        (bool ok, bytes memory ret) = address(store).call(data);
        assertFalse(ok, "store accepted");
        assertEq(ret, err, "wrong error");
    }

    // ─── Wiring ───

    // TEST-062 verifies: REQ-PSTORE-001, REQ-PSTORE-011
    function test_TEST_062_storeAndRegistryNameEachOther() public view {
        assertEq(registry.PARAMETER_STORE(), address(store));
        assertEq(store.MARKET_REGISTRY(), address(registry));
        assertEq(store.TIMELOCK(), address(timelock));
        assertEq(registry.TIMELOCK(), address(timelock));
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_feeRecipientRefusesEveryRegistryRecord() public {
        address[17] memory bad = [
            address(registry),
            address(store),
            registry.AAVE_ADAPTER(),
            registry.COLLATERALIZATION(),
            registry.PROXY_MANAGER(),
            registry.LP_VAULT_SWAP(),
            registry.VAULT_TOKEN_FACTORY(),
            registry.RISK_MODULE(),
            registry.LOCK(),
            registry.PAYOUT_ESCROW(),
            registry.FLASH_LIQUIDATOR(),
            registry.STANDARD_SPOKE_IMPLEMENTATION(),
            registry.flashSource(),
            address(hub),
            address(spoke),
            address(ghoCoverage),
            address(ghoSource)
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            _refuses(
                abi.encodeCall(store.setFeeRecipient, (bad[i])),
                abi.encodeWithSelector(IParameterStoreBase.InvalidFeeRecipient.selector, bad[i])
            );
        }
        // The integration's LPVault is recorded by the registry as integration 1.
        _refuses(
            abi.encodeCall(store.setFeeRecipient, (address(lpVault))),
            abi.encodeWithSelector(IParameterStoreBase.InvalidFeeRecipient.selector, address(lpVault))
        );
        vm.prank(address(timelock));
        store.setFeeRecipient(daoTreasury);
        assertEq(store.feeRecipient(), daoTreasury);
    }

    // ─── Scope checks read the registry ───

    // TEST-272 verifies: REQ-RISK-044, REQ-PSTORE-026, REQ-PSTORE-022
    function test_TEST_272_hubAndSpokeScopesFollowTheRegistry() public {
        address other = makeAddr("otherHub");
        _refuses(
            abi.encodeCall(store.setInitialTokenCap, (other, address(usdc), 1e8)),
            abi.encodeWithSelector(IParameterStoreBase.UnknownHub.selector, other)
        );
        vm.prank(address(timelock));
        store.setInitialTokenCap(address(hub), address(usdc), 20_000_000e8);
        assertEq(store.tokenUsdCap(address(hub), address(usdc)), 20_000_000e8);
        // A token the registry never listed.
        address dai = makeAddr("DAI");
        _refuses(
            abi.encodeCall(store.setTokenCollateralFactorBps, (dai, 5000)),
            abi.encodeWithSelector(IParameterStoreBase.TokenNotListed.selector, dai)
        );
    }

    // ─── Debt reserves: the allowance and the deficit threshold read the registry ───

    // TEST-246 verifies: REQ-CONFIG-050, REQ-PSTORE-006, Q-397
    function test_TEST_246_allowanceFromTheRegistryReserve() public {
        vm.prank(address(timelock));
        store.loosenFloorRoundingAllowance(address(gho), 1e18);
        assertEq(store.floorRoundingAllowance(address(gho)), 1e18);
        // The reserve's price source moves to $2: the bound halves.
        ghoSource.setAnswer(2e8);
        _refuses(abi.encodeCall(store.loosenFloorRoundingAllowance, (address(gho), 1e18 + 1)), oob);
        // A reverting or non-positive price makes the bound zero: fail closed.
        ghoSource.setAnswer(0);
        _refuses(abi.encodeCall(store.loosenFloorRoundingAllowance, (address(gho), 1e18 + 1)), oob);
        // A listed token no approved reserve lends.
        _refuses(
            abi.encodeCall(store.loosenFloorRoundingAllowance, (address(usdc), 1)),
            abi.encodeWithSelector(IParameterStoreBase.TokenNotListed.selector, address(usdc))
        );
    }

    // TEST-228 verifies: REQ-PSTORE-016, Q-399, Q-402
    function test_TEST_228_deficitThresholdBoundedByTheCoverageMinimum() public {
        vm.mockCall(
            address(ghoCoverage), abi.encodeWithSignature("firstLossReserveMinimum()"), abi.encode(uint256(100_000e18))
        );
        vm.prank(address(timelock));
        store.loosenDeficitMax(address(hub), address(gho), 10_000e18);
        _refuses(abi.encodeCall(store.loosenDeficitMax, (address(hub), address(gho), 100_000e18 + 1)), oob);
        vm.prank(address(timelock));
        store.loosenDeficitMax(address(hub), address(gho), 100_000e18);
        assertEq(store.deficitMax(address(hub), address(gho)), 100_000e18);
        // USDT has no reserve funded by the Hub.
        _refuses(
            abi.encodeCall(store.loosenDeficitMax, (address(hub), address(usdt), 1)),
            abi.encodeWithSelector(IParameterStoreBase.UnknownDebtReserve.selector, address(0), 0)
        );
    }

    // ─── A market through listing and activation ───

    function _listMarket() internal returns (uint256 id, address vaultToken, RegistryLPOracleMock lpOracle) {
        id = registry.marketCount() + 1;
        lpOracle = new RegistryLPOracleMock(id, address(lpVault));
        vm.prank(address(timelock));
        vaultToken = factory.deployVaultToken(
            V3,
            pool,
            bytes32(0),
            PositionShape(ShapeKind.TickRange, -50, 50),
            address(hub),
            address(spoke),
            id,
            address(lpOracle),
            18,
            "Avana USDC/USDT",
            "avUSDC-USDT"
        );
        MarketDef memory d;
        d.hub = address(hub);
        d.spoke = address(spoke);
        d.integrationId = V3;
        d.pool = pool;
        d.shape = PositionShape(ShapeKind.TickRange, -50, 50);
        d.vaultToken = vaultToken;
        d.lpOracle = address(lpOracle);
        vm.prank(address(timelock));
        id = registry.listCollateralMarket(d);
    }

    /// @dev The store's listing writes of the market (the pool's observation buffer and the integration's depth read
    /// are answered by mocked calls), the Aave payload and the swap routes into GHO.
    function _storeListing(
        uint256 id,
        address vaultToken
    ) internal {
        RiskStatus memory st;
        st.depthAvailable = true;
        st.depthUnits = 1;
        vm.mockCall(address(lpVault), abi.encodeWithSignature("riskStatus(uint256,uint32)"), abi.encode(st));
        MarketParams memory p;
        (p.slippageAllowanceBps, p.slippageAllowanceMinBps) = (195, 30);
        (p.poolRiskFactor, p.minPledgeUsd) = (4000, 10e8);
        vm.startPrank(address(timelock));
        store.setTokenCollateralFactorBps(address(usdc), 7800);
        store.setTokenCollateralFactorBps(address(usdt), 7500);
        store.setInitialMarketParams(id, p);
        store.setInitialMarketCaps(id, 1_000_000e8, 100_000e8, 1e8);
        vm.stopPrank();
        hub.setAsset(vaultToken, VT_ASSET);
        hub.setSpokeConfig(VT_ASSET, address(spoke), 2_000_000, 0);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (vaultToken, address(hub), uint16(VT_ASSET), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory dyn;
        (dyn.collateralFactor, dyn.maxLiquidationBonus) = (2500, 10_500);
        spoke.setReserve(VT_RESERVE, r, c, dyn);
        spoke.setLiquidationConfig(1.1e18, 5000);
        _route(id, address(usdc), 0, "dexA");
        _route(id, address(usdc), 1, "dexB");
        _route(id, address(usdt), 0, "dexC");
        _route(id, address(usdt), 1, "dexD");
    }

    function _route(
        uint256 id,
        address token,
        uint8 kind,
        string memory dep
    ) internal {
        address[] memory deps = new address[](1);
        deps[0] = makeAddr(dep);
        address route = address(new RegistryRouteMock(token, address(gho), address(lpVaultSwap), deps));
        vm.prank(address(timelock));
        registry.setRoute(id, token, address(gho), uint8(kind), route);
    }

    function _activeMarket() internal returns (uint256 id, address vaultToken, RegistryLPOracleMock lpOracle) {
        (id, vaultToken, lpOracle) = _listMarket();
        _storeListing(id, vaultToken);
        vm.prank(address(timelock));
        registry.activateMarket(id);
    }

    // TEST-250 verifies: REQ-PSTORE-004, REQ-PSTORE-012, REQ-RISK-041, REQ-PSTORE-011
    function test_TEST_250_listingWritesFollowTheRegistryStatus() public {
        (uint256 id, address vaultToken,) = _listMarket();
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Registered));
        _storeListing(id, vaultToken);
        assertEq(store.getMarketParams(id).poolRiskFactor, 4000);
        vm.prank(address(timelock));
        registry.activateMarket(id);
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Active));
        // Active: the listing writes are closed.
        MarketParams memory p = store.getMarketParams(id);
        _refuses(
            abi.encodeCall(store.setInitialMarketParams, (id, p)),
            abi.encodeWithSelector(IParameterStoreBase.NotInListing.selector)
        );
        _refuses(
            abi.encodeCall(store.setInitialMarketCaps, (id, 1e8, 0, 1e8)),
            abi.encodeWithSelector(IParameterStoreBase.NotInListing.selector)
        );
        // An identifier the registry never assigned.
        _refuses(
            abi.encodeCall(store.tightenMinPledgeUsd, (id + 1, 20e8)),
            abi.encodeWithSelector(IParameterStoreBase.UnknownMarket.selector, id + 1)
        );
    }

    // TEST-245 verifies: REQ-PSTORE-021, REQ-PSTORE-024, REQ-PSTORE-015, REQ-CONFIG-052, REQ-ACCESS-095
    function test_TEST_245_livenessThroughTheRegistryAndSpoke() public {
        (uint256 id,,) = _activeMarket();
        // minLB = 10,000 + ⌊500 × 5,000 / 10⁴⌋ = 10,250.
        assertTrue(store.liquidationLivenessHolds(address(spoke), id, GHO_RESERVE));
        assertFalse(store.liquidationLivenessHolds(address(spoke), id, 7), "unapproved reserve");
        // Floor 190: 10,250 × 9,810 = 100,552,500 ≥ 10⁴ × 10,055, so a flash ceiling of 55 holds and 56 does not.
        vm.prank(address(timelock));
        store.setSlippageAllowanceMinBps(id, 190);
        vm.prank(address(timelock));
        store.setMaxFlashFeeBps(55);
        _refuses(
            abi.encodeCall(store.setMaxFlashFeeBps, (56)),
            abi.encodeWithSelector(IParameterStoreBase.LivenessBound.selector)
        );
        // At 55, raising the floor one more bp breaks the pair (10,250 × 9,809 < 10⁴ × 10,055).
        _refuses(
            abi.encodeCall(store.setSlippageAllowanceMinBps, (id, 191)),
            abi.encodeWithSelector(IParameterStoreBase.LivenessBound.selector)
        );
        // An Aave bonus cut after activation is drift: the view turns false, and only lowerings still pass.
        IAaveV4Spoke.Reserve memory r = spoke.getReserve(VT_RESERVE);
        IAaveV4Spoke.DynamicReserveConfig memory dyn;
        (dyn.collateralFactor, dyn.maxLiquidationBonus) = (2500, 10_100);
        spoke.setReserve(VT_RESERVE, r, spoke.getReserveConfig(VT_RESERVE), dyn);
        assertFalse(store.liquidationLivenessHolds(address(spoke), id, GHO_RESERVE));
        vm.prank(address(timelock));
        store.setMaxFlashFeeBps(0);
        vm.prank(address(timelock));
        store.setSlippageAllowanceMinBps(id, 30);
    }

    // TEST-225 verifies: SPEC-CAP-006, REQ-RISK-044, REQ-PSTORE-017
    function test_TEST_225_capLoosenOnALiveMarketReadsTheHubAndCounters() public {
        (uint256 id, address vaultToken,) = _activeMarket();
        PledgeCounters memory c;
        c.regularUsed = 1_200_000e8;
        vm.mockCall(
            registry.COLLATERALIZATION(),
            abi.encodeCall(ICollateralization.getCounters, (vaultToken, address(0))),
            abi.encode(c)
        );
        // (max(1,500,000, 1,200,000) + 100,000) / $1 = 1,600,000 ≤ addCap 2,000,000.
        vm.prank(address(timelock));
        store.loosenMarketUsdCap(id, 1_500_000e8);
        vm.warp(block.timestamp + NORMAL_DELAY);
        hub.setSpokeConfig(VT_ASSET, address(spoke), 2_149_999, 0);
        // The step allows 2,250,000 (1.5 × 1,500,000); with the slice that needs 2,350,000 whole tokens of addCap.
        _refuses(
            abi.encodeCall(store.loosenMarketUsdCap, (id, 2_250_000e8)),
            abi.encodeWithSelector(IParameterStoreBase.AddCapTooSmall.selector)
        );
        hub.setSpokeConfig(VT_ASSET, address(spoke), 2_350_000, 0);
        vm.prank(address(timelock));
        store.loosenMarketUsdCap(id, 2_250_000e8);
        assertEq(store.marketUsdCap(id), 2_250_000e8);
    }

    // TEST-138 verifies: REQ-PSTORE-004, REQ-PSTORE-012, REQ-CONFIG-046
    // Sources: 5.1 TEST-138 (listing order: the store's initial parameters before activation)
    /// @notice A listed market cannot be activated before the ParameterStore's listing writes
    /// (`setInitialMarketParams`, including `minPledgeUsd`, and the initial caps): `activateMarket` reverts
    /// `ActivationCheckFailed` and the market stays Registered. After the store's writes it activates, the store serves
    /// the listed values, and the listing writes close.
    function test_TEST_138_activationOnlyAfterTheStoreListing() public {
        (uint256 id, address vaultToken,) = _listMarket();
        vm.expectPartialRevert(IMarketRegistryBase.ActivationCheckFailed.selector);
        vm.prank(address(timelock));
        registry.activateMarket(id);
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Registered), "still Registered");
        _storeListing(id, vaultToken);
        vm.prank(address(timelock));
        registry.activateMarket(id);
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Active), "Active after the store listing");
        assertEq(store.minPledgeUsd(id), 10e8, "the listed minimum pledge");
        assertEq(store.getMarketParams(id).poolRiskFactor, 4000, "the listed pool risk factor");
        _refuses(
            abi.encodeCall(store.setInitialMarketCaps, (id, 1e8, 0, 1e8)),
            abi.encodeWithSelector(IParameterStoreBase.NotInListing.selector)
        );
    }
}
