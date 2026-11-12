// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../../src/governance/roles/AvanaRoles.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {MarketRegistryActivationLogic} from "../../../src/policy/market-registry/MarketRegistryActivationLogic.sol";
import {MarketRegistryHubsLogic} from "../../../src/policy/market-registry/MarketRegistryHubsLogic.sol";
import {MarketRegistryListingLogic} from "../../../src/policy/market-registry/MarketRegistryListingLogic.sol";
import {MarketRegistryRoutesLogic} from "../../../src/policy/market-registry/MarketRegistryRoutesLogic.sol";
import {MarketRegistrySafetyLogic} from "../../../src/policy/market-registry/MarketRegistrySafetyLogic.sol";
import {MarketRegistryWindDownLogic} from "../../../src/policy/market-registry/MarketRegistryWindDownLogic.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IssuerProbe} from "../../../src/policy/market-registry/types/IssuerProbe.sol";
import {MarketRegistryImmutables} from "../../../src/policy/market-registry/types/MarketRegistryImmutables.sol";
import {MarketRegistryLogics} from "../../../src/policy/market-registry/types/MarketRegistryLogics.sol";
import {RiskTier} from "../../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../../src/policy/market-registry/types/SpokeDef.sol";
import {TokenDef} from "../../../src/policy/market-registry/types/TokenDef.sol";
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
import {ParameterStoreLogics} from "../../../src/policy/parameter-store/types/ParameterStoreLogics.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {VaultTokenFactory} from "../../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {
    RegistryAaveOracleMock,
    RegistryHubMock,
    RegistrySpokeImplMock,
    RegistrySpokeMock
} from "../mocks/MarketRegistryAaveMocks.sol";
import {
    RegistryAdapterMock,
    RegistryCollateralizationMock,
    RegistryCoverageSpokeMock,
    RegistryFeedMock,
    RegistryFlashSourceMock,
    RegistryLPVaultMock,
    RegistryRiskModuleMock,
    RegistryTokenMock
} from "../mocks/MarketRegistryMocks.sol";
import {MockAggregator} from "../mocks/ParameterStoreMocks.sol";
import {TimelockFixture} from "./TimelockFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title ParameterStoreRegistryFixture
/// @notice The real ParameterStore and the real MarketRegistry wired to each other (each holds the other's proxy as
/// an immutable), with settable mocks for the Aave reads, the LPVault, the Coverage Spoke and the price feeds. World
/// after `_setUpWorld`: the Stable LP Hub recorded, integration 1 registered, the CDP Spoke deployed, GHO listed and
/// enabled as a fixed-price debt reserve funded by the Hub, and USDC and USDT listed with a one-leg primary, a
/// two-leg alternate and a one-leg standby route whose feeds the store defines (25 bps each).
abstract contract ParameterStoreRegistryFixture is TimelockFixture {
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
    RegistryCoverageSpokeMock internal ghoCoverage;
    RegistryTokenMock internal usdc;
    RegistryTokenMock internal usdt;
    RegistryTokenMock internal gho;
    RegistryFeedMock internal ghoSource;
    /// @dev Per listed token: primary, alternate leg 0, alternate leg 1, standby.
    mapping(address token => address[4] feeds) internal routeFeeds;
    address internal lockAddr = makeAddr("lock");
    address internal proxyManager = makeAddr("proxyManager");
    address internal payoutEscrow = makeAddr("payoutEscrow");
    address internal flashLiquidator = makeAddr("flashLiquidator");
    address internal aaveV3Pool = makeAddr("aaveV3Pool");
    address internal pool = makeAddr("usdcUsdtPool");

    function _deployWired() internal {
        _deployTimelock();
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
        address tl = address(timelock);
        vm.label(address(registry), "MarketRegistry");
        vm.label(address(store), "ParameterStore");
        vm.startPrank(tl);
        registry.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        vm.stopPrank();
    }

    /// @dev The VaultTokenFactory (naming `registry_`), the registry's logic contracts, implementation and proxy (naming
    /// `store_`), then the store's logic contracts, implementation and proxy.
    function _deployFactoryRegistryAndStore(
        address registry_,
        address store_
    ) internal {
        factory = new VaultTokenFactory(
            address(adapterMock), address(lpVaultSwap), address(collat), address(timelock), registry_
        );
        collat.setCore(address(factory), address(adapterMock), address(lpVaultSwap));
        im = MarketRegistryImmutables({
            timelock: address(timelock),
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
        l.safety = address(new MarketRegistrySafetyLogic(im));
        l.windDown = address(new MarketRegistryWindDownLogic(im));
        MarketRegistry impl = new MarketRegistry(im, l);
        registry = MarketRegistry(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(MarketRegistry.initialize, (address(timelock)))))
        );
        address tl = address(timelock);
        address reg = address(registry);
        storeLogics = ParameterStoreLogics({
            tighten: address(new ParameterStoreTightenLogic(tl, reg, BLOCK_TIME, false)),
            loosen: address(new ParameterStoreLoosenLogic(tl, reg, BLOCK_TIME, false)),
            listing: address(new ParameterStoreListingLogic(tl, reg, BLOCK_TIME, false)),
            adminOracle: address(new ParameterStoreAdminOracleLogic(tl, reg, BLOCK_TIME, false)),
            adminRisk: address(new ParameterStoreAdminRiskLogic(tl, reg, BLOCK_TIME, false))
        });
        ParameterStore storeImpl = new ParameterStore(tl, reg, BLOCK_TIME, false, storeLogics);
        store = IParameterStore(
            address(
                new ERC1967Proxy(
                    address(storeImpl), abi.encodeCall(IParameterStoreAdmin.initialize, (tl, _globals(), 0, 10_000))
                )
            )
        );
    }

    function _globals() internal view returns (GlobalParams memory g) {
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
        ghoCoverage = new RegistryCoverageSpokeMock(address(hub), address(gho), GHO_ASSET);
        ghoCoverage.setFunded(4e24, false);
        vm.prank(address(timelock));
        factory.registerIntegration(V3, address(lpVault));
        vm.startPrank(address(timelock));
        registry.recordHub(address(hub), RiskTier.Stable);
        registry.registerIntegration(V3, address(lpVault), makeAddr("clPricing"));
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
        registry.setCoverageSpoke(address(hub), address(gho), address(ghoCoverage));
        registry.recordCreditLine(address(hub), address(gho), 20_000_000);
        vm.stopPrank();
        _setGhoReserve();
        _listToken(address(gho), "gho", IssuerProbe.None, false);
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), _ghoDef());
        _listToken(address(usdc), "usdc", IssuerProbe.PausedFlag, true);
        _listToken(address(usdt), "usdt", IssuerProbe.PausedFlag, true);
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
            coverageSpoke: address(ghoCoverage),
            crossHub: false,
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
        vm.prank(address(timelock));
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

    /// @dev Lists `token` with three routes of store-defined feeds and, when `tolerance`, writes its agreement
    /// tolerance in the store (150 bps) once the registry lists it.
    function _listToken(
        address token,
        string memory label,
        IssuerProbe probe,
        bool tolerance
    ) internal {
        address[] memory p = new address[](1);
        address[] memory a = new address[](2);
        address[] memory s = new address[](1);
        p[0] = _newFeed(string.concat(label, "/USD"));
        a[0] = _newFeed(string.concat(label, "/ETH"));
        a[1] = _newFeed(string.concat(label, "-ETH/USD"));
        s[0] = _newFeed(string.concat(label, "/USD standby"));
        routeFeeds[token] = [p[0], a[0], a[1], s[0]];
        TokenDef memory d;
        d.isUsdStable = true;
        d.primaryRoute = p;
        d.alternateRoute = a;
        d.standbyRoute = s;
        d.replacedSlot = RouteSlot.None;
        d.issuerProbe = probe;
        vm.prank(address(timelock));
        registry.listToken(token, d);
        if (tolerance) {
            vm.prank(address(timelock));
            store.setFeedAgreementToleranceBps(token, 150);
        }
    }
}
