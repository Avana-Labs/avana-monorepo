// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaAccess} from "../../../script/deploy/lib/AvanaAccess.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {MarketRegistryActivationLogic} from "../../../src/policy/market-registry/MarketRegistryActivationLogic.sol";
import {MarketRegistryHubsLogic} from "../../../src/policy/market-registry/MarketRegistryHubsLogic.sol";
import {MarketRegistryListingLogic} from "../../../src/policy/market-registry/MarketRegistryListingLogic.sol";
import {MarketRegistryRoutesLogic} from "../../../src/policy/market-registry/MarketRegistryRoutesLogic.sol";
import {MarketRegistryWindDownLogic} from "../../../src/policy/market-registry/MarketRegistryWindDownLogic.sol";
import {IssuerProbe} from "../../../src/policy/market-registry/types/IssuerProbe.sol";
import {
    DebtReserveDef,
    MarketRegistryImmutables,
    MarketRegistryLogics,
    RiskTier,
    SpokeDef,
    TokenDef
} from "../../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {ParameterStore} from "../../../src/policy/parameter-store/ParameterStore.sol";
import {ParameterStoreAdminOracleLogic} from "../../../src/policy/parameter-store/ParameterStoreAdminOracleLogic.sol";
import {ParameterStoreAdminRiskLogic} from "../../../src/policy/parameter-store/ParameterStoreAdminRiskLogic.sol";
import {ParameterStoreListingLogic} from "../../../src/policy/parameter-store/ParameterStoreListingLogic.sol";
import {ParameterStoreLoosenLogic} from "../../../src/policy/parameter-store/ParameterStoreLoosenLogic.sol";
import {ParameterStoreTightenLogic} from "../../../src/policy/parameter-store/ParameterStoreTightenLogic.sol";
import {
    FeedDef,
    GlobalParams,
    ParameterStoreLogics
} from "../../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {AvanaTest} from "../AvanaTest.sol";
import {LegacyVaultTokenFactory as VaultTokenFactory} from "../legacy/LegacyVaultTokenFactory.sol";
import {CallRecorder} from "../mocks/CallRecorder.sol";
import {
    RegistryAaveOracleMock,
    RegistryHubMock,
    RegistrySpokeImplMock,
    RegistrySpokeMock
} from "../mocks/MarketRegistryAaveMocks.sol";
import {
    RegistryAdapterMock,
    RegistryAvanaFirstLossReserveMock,
    RegistryCollateralizationMock,
    RegistryFeedMock,
    RegistryFlashSourceMock,
    RegistryLPVaultMock,
    RegistryRiskModuleMock,
    RegistryTokenMock
} from "../mocks/MarketRegistryMocks.sol";
import {MockAggregator} from "../mocks/ParameterStoreMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title ParameterStoreRegistryFixture
/// @notice The real ParameterStore and the real MarketRegistry wired to each other (each holds the other's proxy as
/// an immutable), with settable mocks for the Aave reads, the LPVault, the First-Loss Reserve and the price feeds. World
/// after `_setUpWorld`: the Stable LP Hub recorded, integration 1 registered, the CDP Spoke deployed, GHO listed and
/// enabled as a fixed-price debt reserve funded by the Hub, and USDC and USDT listed with a one-leg primary and a
/// two-leg alternate route whose feeds the store defines (25 bps each).
abstract contract ParameterStoreRegistryFixture is AvanaTest {
    /// @dev Stand-ins for the contracts the fixture does not build: they accept every call and record it.
    CallRecorder internal parameterStore = new CallRecorder();
    CallRecorder internal marketRegistry = new CallRecorder();
    CallRecorder internal lpVaultSwap = new CallRecorder();
    CallRecorder internal other = new CallRecorder();

    uint32 internal constant V3 = 1;
    uint32 internal constant BLOCK_TIME = 12;
    uint256 internal constant GHO_RESERVE = 0;
    uint256 internal constant GHO_ASSET = 0;
    /// @dev The registry's market-count limit (REQ-MREG-034).
    uint256 internal constant MAX_MARKETS = 64;

    MarketRegistry internal registry;
    IParameterStore internal store;
    ParameterStoreLogics internal storeLogics;
    MarketRegistryImmutables internal im;
    VaultTokenFactory internal factory;
    RegistryCollateralizationMock internal collat;
    RegistryRiskModuleMock internal rm;
    RegistryAdapterMock internal adapterMock;
    RegistryHubMock internal hub;
    RegistrySpokeMock internal spoke;
    RegistrySpokeImplMock internal spokeImpl;
    RegistryAaveOracleMock internal aaveOracle;
    RegistryLPVaultMock internal lpVault;
    RegistryFlashSourceMock internal flash;
    RegistryAvanaFirstLossReserveMock internal ghoCoverage;
    RegistryTokenMock internal usdc;
    RegistryTokenMock internal usdt;
    RegistryTokenMock internal gho;
    RegistryFeedMock internal ghoSource;
    /// @dev Per listed token: primary, alternate leg 0, alternate leg 1.
    mapping(address token => address[3] feeds) internal routeFeeds;
    address internal lockAddr = makeAddr("lock");
    address internal proxyManager = makeAddr("proxyManager");
    address internal payoutEscrow = makeAddr("payoutEscrow");
    address internal flashLiquidator = makeAddr("flashLiquidator");
    address internal aaveV3Pool = makeAddr("aaveV3Pool");
    address internal pool = makeAddr("usdcUsdtPool");

    function _deployWired() internal {
        collat = new RegistryCollateralizationMock(lockAddr);
        rm = new RegistryRiskModuleMock();
        adapterMock = new RegistryAdapterMock();
        spokeImpl = new RegistrySpokeImplMock();
        // The factory names the registry and the registry names the store, both created after it: a dry run finds
        // their addresses, the state is rolled back, and the same sequence of creations runs again with them.
        uint256 dryRun = vm.snapshotState();
        _deployFactoryRegistryAndStore(address(1), address(2));
        address predictedRegistry = address(registry);
        address predictedStore = address(store);
        vm.revertToState(dryRun);
        _deployFactoryRegistryAndStore(predictedRegistry, predictedStore);
        require(address(registry) == predictedRegistry, "registry prediction");
        require(address(store) == predictedStore, "store prediction");
        _bindAccess(AvanaAccess.Kind.MarketRegistry, address(registry));
        _bindAccess(AvanaAccess.Kind.ParameterStore, address(store));
        _bindAccess(AvanaAccess.Kind.VaultTokenFactory, address(factory));
        vm.label(address(registry), "MarketRegistry");
        vm.label(address(store), "ParameterStore");
    }

    /// @dev The VaultTokenFactory (naming `registry_`), the registry's logic contracts, implementation and proxy (naming
    /// `store_`), then the store's logic contracts, implementation and proxy.
    function _deployFactoryRegistryAndStore(
        address registry_,
        address store_
    ) internal {
        factory = new VaultTokenFactory(
            address(adapterMock), address(lpVaultSwap), address(collat), address(accessManager), registry_
        );
        collat.setCore(address(factory), address(adapterMock), address(lpVaultSwap));
        im = MarketRegistryImmutables({
            aaveGovernanceExecutor: aaveGovernanceExecutor,
            vaultTokenFactory: address(factory),
            aaveAdapter: address(adapterMock),
            collateralization: address(collat),
            lock: lockAddr,
            proxyManager: proxyManager,
            parameterStore: store_,
            riskModule: address(rm),
            lpVaultSwap: address(lpVaultSwap),
            payoutEscrow: payoutEscrow,
            flashLiquidator: flashLiquidator,
            standardSpokeImplementation: address(spokeImpl),
            maxMarketCount: MAX_MARKETS
        });
        MarketRegistryLogics memory l;
        l.hubs = address(new MarketRegistryHubsLogic(im));
        l.listing = address(new MarketRegistryListingLogic(im));
        l.activation = address(new MarketRegistryActivationLogic(im));
        l.routes = address(new MarketRegistryRoutesLogic(im));
        l.windDown = address(new MarketRegistryWindDownLogic(im));
        MarketRegistry impl = new MarketRegistry(im, l);
        registry = MarketRegistry(
            address(
                new ERC1967Proxy(address(impl), abi.encodeCall(MarketRegistry.initialize, (address(accessManager))))
            )
        );
        address tl = address(accessManager);
        address reg = address(registry);
        storeLogics = ParameterStoreLogics({
            tighten: address(new ParameterStoreTightenLogic(reg, BLOCK_TIME)),
            loosen: address(new ParameterStoreLoosenLogic(reg, BLOCK_TIME)),
            listing: address(new ParameterStoreListingLogic(reg, BLOCK_TIME)),
            adminOracle: address(new ParameterStoreAdminOracleLogic(reg, BLOCK_TIME)),
            adminRisk: address(new ParameterStoreAdminRiskLogic(reg, BLOCK_TIME))
        });
        ParameterStore storeImpl = new ParameterStore(reg, BLOCK_TIME, storeLogics);
        store = IParameterStore(
            address(new ERC1967Proxy(address(storeImpl), abi.encodeCall(IParameterStore.initialize, (tl, _globals()))))
        );
    }

    function _globals() internal view returns (GlobalParams memory g) {
        g.maxFlashFeeBps = 10;
        g.avanaFeeShareBps = 2000;
        g.feeRecipient = feeRecipient;
        g.maxShortfallBps = 1000;
    }

    function _setUpWorld() internal {
        _deployWired();
        hub = new RegistryHubMock();
        spoke = new RegistrySpokeMock();
        aaveOracle = new RegistryAaveOracleMock();
        spoke.setOracle(address(aaveOracle));
        spoke.setImplementation(address(spokeImpl));
        aaveOracle.setSpoke(address(spoke));
        lpVault = new RegistryLPVaultMock(V3, address(collat), lockAddr);
        lpVault.setRegistry(address(registry));
        usdc = new RegistryTokenMock(6);
        usdt = new RegistryTokenMock(6);
        gho = new RegistryTokenMock(18);
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        lpVault.setPoolTokens(toks, 18);
        flash = new RegistryFlashSourceMock(aaveV3Pool, address(lpVaultSwap));
        ghoSource = new RegistryFeedMock(8, 1e8);
        ghoCoverage = new RegistryAvanaFirstLossReserveMock(address(hub), address(gho), GHO_ASSET);
        ghoCoverage.setFunded(4e24, false);
        vm.prank(governor);
        factory.registerIntegration(V3, address(lpVault));
        vm.startPrank(governor);
        registry.recordHub(address(hub), RiskTier.Stable);
        // The integration's position manager and factory, recorded and finalized (REQ-MREG-035).
        address[] memory amm = new address[](2);
        (amm[0], amm[1]) = (address(new RegistryTokenMock(18)), address(new RegistryTokenMock(18)));
        registry.recordIntegrationContracts(V3, amm);
        registry.finalizeIntegrationContracts(V3);
        registry.deployCdpSpoke(
            SpokeDef({
                approved: false,
                hub: address(hub),
                integrationId: V3,
                riskTier: RiskTier.Stable,
                implementation: address(spokeImpl),
                aaveOracle: address(aaveOracle)
            })
        );
        registry.setFlashSource(address(flash));
        hub.setAsset(address(gho), GHO_ASSET);
        registry.setAvanaFirstLossReserve(address(hub), address(gho), address(ghoCoverage));
        vm.stopPrank();
        _setGhoReserve();
        _listToken(address(gho), "gho", IssuerProbe.None);
        vm.prank(governor);
        registry.enableDebtReserve(address(spoke), _ghoDef());
        _listToken(address(usdc), "usdc", IssuerProbe.PausedFlag);
        _listToken(address(usdt), "usdt", IssuerProbe.PausedFlag);
    }

    function _setGhoReserve() internal {
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(gho), address(hub), uint16(GHO_ASSET), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        spoke.setReserve(GHO_RESERVE, r, c, d);
        aaveOracle.setSource(GHO_RESERVE, address(ghoSource));
        hub.setSpokeConfig(GHO_ASSET, address(spoke), 0, 1_000_000);
    }

    function _ghoDef() internal view returns (DebtReserveDef memory) {
        return DebtReserveDef({
            reserveId: GHO_RESERVE,
            asset: address(gho),
            decimals: 18,
            fundingHub: address(hub),
            hubAssetId: GHO_ASSET,
            priceSource: address(ghoSource),
            fixedPrice: true,
            firstLossReserve: address(ghoCoverage),
            approved: false
        });
    }

    /// @dev A feed the store defines as a 24-hour feed with a 1,800 s margin and a 25 bps threshold.
    function _newFeed(
        string memory label
    ) internal returns (address f) {
        f = address(new MockAggregator(8, 1e6, 1e12));
        // A live round at $1.00, which the registry reads when it lists a market.
        MockAggregator(f).setRound(1e8, 1);
        vm.label(f, label);
        vm.prank(governor);
        store.setFeed(f, _feedDef());
    }

    function _feedDef() internal pure returns (FeedDef memory d) {
        d.feedHeartbeat = 86_400;
        d.heartbeatMargin = 1800;
        d.feedMaxAge = 88_200;
        d.liquidationPriceMaxAge = 88_200;
        d.borrowPriceMaxAge = 88_200;
        d.feedDeviationThresholdBps = 25;
        d.heartbeatDriftBps = 25;
        d.maxAnswerCap = type(int256).max;
    }

    /// @dev Lists `token` with two routes of store-defined feeds.
    function _listToken(
        address token,
        string memory label,
        IssuerProbe probe
    ) internal {
        address[] memory p = new address[](1);
        address[] memory a = new address[](2);
        p[0] = _newFeed(string.concat(label, "/USD"));
        a[0] = _newFeed(string.concat(label, "/ETH"));
        a[1] = _newFeed(string.concat(label, "-ETH/USD"));
        routeFeeds[token] = [p[0], a[0], a[1]];
        TokenDef memory d;
        d.isUsdStable = true;
        d.primaryRoute = p;
        d.alternateRoute = a;
        d.issuerProbe = probe;
        vm.prank(governor);
        registry.listToken(token, d);
    }
}
