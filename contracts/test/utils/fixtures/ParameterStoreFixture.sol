// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreAdmin} from "../../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {ParameterStore} from "../../../src/policy/parameter-store/ParameterStore.sol";
import {ParameterStoreAdminOracleLogic} from "../../../src/policy/parameter-store/ParameterStoreAdminOracleLogic.sol";
import {ParameterStoreAdminRiskLogic} from "../../../src/policy/parameter-store/ParameterStoreAdminRiskLogic.sol";
import {ParameterStoreListingLogic} from "../../../src/policy/parameter-store/ParameterStoreListingLogic.sol";
import {ParameterStoreLoosenLogic} from "../../../src/policy/parameter-store/ParameterStoreLoosenLogic.sol";
import {ParameterStoreTightenLogic} from "../../../src/policy/parameter-store/ParameterStoreTightenLogic.sol";
import {FeedDef} from "../../../src/policy/parameter-store/types/FeedDef.sol";
import {GlobalParams} from "../../../src/policy/parameter-store/types/GlobalParams.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/MarketParams.sol";
import {ParameterStoreLogics} from "../../../src/policy/parameter-store/types/ParameterStoreLogics.sol";
import {Market} from "../../../src/types/Market.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {MockMarketRegistry} from "../mocks/MockMarketRegistry.sol";
import {
    MockAggregator,
    MockCollateralization,
    MockCoverageSpoke,
    MockHub,
    MockIntegration,
    MockLPOracle,
    MockPool,
    MockPriceSource,
    MockSpoke,
    MockVaultToken
} from "../mocks/ParameterStoreMocks.sol";
import {TimelockFixture} from "./TimelockFixture.sol";
import {TimelockLaunchLists} from "./TimelockLaunchLists.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title ParameterStoreFixture
/// @notice The real AvanaTimelock (launch short-delay list naming the ParameterStore proxy), the ParameterStore
/// proxy over its implementation and five logic contracts, initialized with the launch values of 1.5, and a mocked
/// MarketRegistry with one Hub, one CDP Spoke, one GHO debt reserve and market 1 (USDC/USDT, concentrated
/// liquidity, `Registered`). `_listMarket` runs the market's listing writes as the timelock.
abstract contract ParameterStoreFixture is TimelockFixture {
    IParameterStore internal store;
    ParameterStore internal implementation;
    ParameterStoreLogics internal logics;
    MockMarketRegistry internal registry;
    MockCollateralization internal collateralization;
    MockHub internal hub;
    MockSpoke internal spoke;
    MockIntegration internal integration;
    MockPool internal pool;
    MockLPOracle internal lpOracle;
    MockVaultToken internal vaultToken;
    MockCoverageSpoke internal coverage;
    MockPriceSource internal ghoPrice;
    MockAggregator internal fUsdc;
    MockAggregator internal fUsdcAlt;
    MockAggregator internal fUsdt;
    MockAggregator internal fUsdtAlt;
    address internal usdc = makeAddr("USDC");
    address internal usdt = makeAddr("USDT");
    address internal gho = makeAddr("GHO");
    address internal guardianTimelock;
    uint256 internal constant M = 1;
    uint32 internal constant BLOCK_TIME = 12;

    function _deployStore(
        bool hasSequencer
    ) internal {
        registry = new MockMarketRegistry();
        collateralization = new MockCollateralization();
        registry.setCollateralization(address(collateralization));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 7);
        timelock = _newTimelock(
            NORMAL_DELAY,
            true,
            TimelockLaunchLists.shortEligible(predicted, makeAddr("registryTarget"), makeAddr("swapTarget")),
            TimelockLaunchLists.daoOnlyCancel(makeAddr("registryTarget"), makeAddr("swapTarget"))
        );
        address tl = address(timelock);
        logics = ParameterStoreLogics({
            tighten: address(new ParameterStoreTightenLogic(tl, address(registry), BLOCK_TIME, hasSequencer)),
            loosen: address(new ParameterStoreLoosenLogic(tl, address(registry), BLOCK_TIME, hasSequencer)),
            listing: address(new ParameterStoreListingLogic(tl, address(registry), BLOCK_TIME, hasSequencer)),
            adminOracle: address(new ParameterStoreAdminOracleLogic(tl, address(registry), BLOCK_TIME, hasSequencer)),
            adminRisk: address(new ParameterStoreAdminRiskLogic(tl, address(registry), BLOCK_TIME, hasSequencer))
        });
        implementation = new ParameterStore(tl, address(registry), BLOCK_TIME, hasSequencer, logics);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(IParameterStoreAdmin.initialize, (tl, _launchGlobals(), 0, 10_000))
        );
        require(address(proxy) == predicted, "prediction");
        store = IParameterStore(address(proxy));
        vm.label(address(store), "ParameterStore");
        _deployWorld();
    }

    function _launchGlobals() internal view returns (GlobalParams memory g) {
        g.cachedWindow = 3600;
        g.disagreementPauseMax = 3600;
        g.usdBandLow = 0.9e8;
        g.usdBandHigh = 1.02e8;
        g.graceDuration = 1800;
        g.graceHealthFactor = 0.95e18;
        g.maxFlashFeeBps = 10;
        g.avanaFeeShareBps = 2000;
        g.feeRecipient = feeRecipient;
        g.feedAgreementMarginBps = 50;
        g.gateRecoverySeconds = 1800;
        g.maxShortfallBps = 1000;
    }

    function _deployWorld() internal {
        hub = new MockHub();
        spoke = new MockSpoke();
        integration = new MockIntegration();
        pool = new MockPool();
        lpOracle = new MockLPOracle();
        vaultToken = new MockVaultToken();
        coverage = new MockCoverageSpoke();
        coverage.setMinimum(100_000e18);
        ghoPrice = new MockPriceSource();
        ghoPrice.setAnswer(1e8);
        fUsdc = new MockAggregator(8, 1e6, 1e12);
        fUsdcAlt = new MockAggregator(8, 1e6, 1e12);
        fUsdt = new MockAggregator(8, 1e6, 1e12);
        fUsdtAlt = new MockAggregator(8, 1e6, 1e12);
        registry.setHub(address(hub), true);
        registry.setSpoke(address(spoke), address(hub));
        registry.setToken(usdc, _one(address(fUsdc)), _one(address(fUsdcAlt)), new address[](0));
        registry.setToken(usdt, _one(address(fUsdt)), _one(address(fUsdtAlt)), new address[](0));
        registry.setToken(gho, new address[](0), new address[](0), new address[](0));
        hub.setAsset(address(vaultToken), 7);
        hub.setAddCap(10_000_000);
        Market memory m;
        m.chainId = uint64(block.chainid);
        m.hub = address(hub);
        m.spoke = address(spoke);
        m.integrationId = 1;
        m.integration = address(integration);
        m.pool = address(pool);
        m.shape.kind = ShapeKind.TickRange;
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (usdc, usdt);
        m.tokenDecimals = new uint8[](2);
        (m.tokenDecimals[0], m.tokenDecimals[1]) = (6, 6);
        m.vaultToken = address(vaultToken);
        m.decimals = 6;
        m.lpOracle = address(lpOracle);
        m.hubAssetId = 7;
        m.status = MarketStatus.Registered;
        registry.setMarket(M, m);
        DebtReserveDef memory d;
        d.reserveId = 1;
        d.asset = gho;
        d.decimals = 18;
        d.fundingHub = address(hub);
        d.priceSource = address(ghoPrice);
        d.fixedPrice = true;
        d.coverageSpoke = address(coverage);
        d.approved = true;
        registry.setDebtReserve(address(spoke), d);
    }

    function _one(
        address a
    ) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _feedDef(
        uint32 heartbeat,
        uint32 margin
    ) internal pure returns (FeedDef memory d) {
        d.feedHeartbeat = heartbeat;
        d.heartbeatMargin = margin;
        d.feedMaxAge = heartbeat + margin;
        d.liquidationPriceMaxAge = heartbeat + margin;
        d.borrowPriceMaxAge = heartbeat + margin;
        d.feedDeviationThresholdBps = 25;
        d.heartbeatDriftBps = 25;
        // No Avana cap below the aggregator's own bound (REQ-ORACLE-049).
        d.maxAnswerCap = type(int256).max;
    }

    function _launchMarketParams() internal pure returns (MarketParams memory p) {
        p.twapWindow = 1800;
        p.consistencyToleranceBps = 50;
        p.slippageAllowanceBps = 100;
        p.slippageAllowanceMinBps = 30;
        p.poolRiskFactor = 4000;
        p.minPledgeUsd = 10e8;
    }

    /// @dev Listing writes of market 1 as the timelock: feeds, token inputs, market parameters and caps, Hub caps.
    function _listMarket() internal {
        vm.startPrank(address(timelock));
        // Tolerances first: every setFeed re-checks the tolerance lower bound of the tokens whose routes use the feed.
        store.setFeedAgreementToleranceBps(usdc, 150);
        store.setFeedAgreementToleranceBps(usdt, 150);
        store.setFeed(address(fUsdc), _feedDef(86_400, 1800));
        store.setFeed(address(fUsdcAlt), _feedDef(86_400, 1800));
        store.setFeed(address(fUsdt), _feedDef(86_400, 1800));
        store.setFeed(address(fUsdtAlt), _feedDef(86_400, 1800));
        store.setTokenCollateralFactorBps(usdc, 7800);
        store.setTokenCollateralFactorBps(usdt, 7500);
        store.setInitialMarketParams(M, _launchMarketParams());
        store.setInitialMarketCaps(M, 5_000_000e8, 500_000e8, 1e8);
        store.setInitialHubCaps(address(hub), 1_000_000e8);
        store.setInitialTokenCap(address(hub), usdc, 20_000_000e8);
        vm.stopPrank();
    }

    function _activate() internal {
        registry.setStatus(M, MarketStatus.Active);
    }

    /// @dev Next call is made by the timelock.
    function _tl() internal {
        vm.prank(address(timelock));
    }
}
