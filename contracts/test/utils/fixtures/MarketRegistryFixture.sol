// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../../src/amm/IAmmIntegration.sol";
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
import {MarketDef} from "../../../src/types/MarketDef.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
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
    RegistryLPOracleMock,
    RegistryLPVaultMock,
    RegistryParameterStoreMock,
    RegistryRiskModuleMock,
    RegistryRouteMock,
    RegistryTokenMock
} from "../mocks/MarketRegistryMocks.sol";
import {TimelockFixture} from "./TimelockFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title MarketRegistryFixture
/// @notice The real MarketRegistry (six logic contracts, implementation, ERC-1967 proxy) with the real
/// VaultTokenFactory and VaultTokens, and settable mocks for the other neighbours (ParameterStore views,
/// RiskModule, LPVault, LPOracle, routes, flash source, Coverage Spoke) and for the Aave reserve reads.
/// @dev World after `_setUpWorld`: the Stable LP Hub recorded (Stable tier), integration 1 registered, the CDP Spoke
/// recorded, the GHO Coverage Spoke funded, a 20,000,000 GHO credit line, the flash source set, GHO listed (issuer probe
/// None) and enabled as debt reserve 0 (fixed price, same Hub), USDC and USDT listed with three routes each. `_listMarket` lists the USDC/USDT
/// `[-50, 50]` market; `_activate` makes it Active with routes into GHO.
abstract contract MarketRegistryFixture is TimelockFixture {
    uint32 internal constant V3 = 1;
    uint256 internal constant GHO_RESERVE = 0;
    uint256 internal constant GHO_ASSET = 0;
    uint256 internal constant VT_ASSET = 1;
    uint256 internal constant VT_RESERVE = 1;
    bytes32 internal constant PAUSE_GUARDIAN = AvanaRoles.APPLICATION_PAUSE_GUARDIAN;
    bytes32 internal constant FREEZE_GUARDIAN = AvanaRoles.APPLICATION_FREEZE_GUARDIAN;
    bytes32 internal constant APP_ADMIN = AvanaRoles.APPLICATION_ADMIN;

    MarketRegistry internal registry;
    MarketRegistryImmutables internal im;
    MarketRegistryLogics internal logics;
    VaultTokenFactory internal factory;
    RegistryCollateralizationMock internal collat;
    RegistryParameterStoreMock internal ps;
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
    address internal lockAddr = makeAddr("lock");
    address internal proxyManager = makeAddr("proxyManager");
    address internal payoutEscrow = makeAddr("payoutEscrow");
    address internal flashLiquidator = makeAddr("flashLiquidator");
    address internal aaveV3Pool = makeAddr("aaveV3Pool");
    address internal pool = makeAddr("usdcUsdtPool");
    /// @dev The AMM protocol contracts recorded and finalized for integration V3 in `_setUpWorld` (REQ-MREG-035).
    address internal ammPositionManager;
    address internal ammFactory;

    function _deployRegistry() internal {
        _deployRegistryWith(address(0));
    }

    /// @dev `standardImpl == 0` uses a fresh `RegistrySpokeImplMock` as the approved standard Spoke implementation.
    function _deployRegistryWith(
        address standardImpl
    ) internal {
        _deployTimelock();
        collat = new RegistryCollateralizationMock(lockAddr);
        ps = new RegistryParameterStoreMock();
        rm = new RegistryRiskModuleMock();
        adapterMock = new RegistryAdapterMock();
        spokeImpl = new RegistrySpokeImplMock();
        if (standardImpl == address(0)) standardImpl = address(spokeImpl);
        // The factory names the registry, which is created after it: a dry run finds the registry's address, the state
        // is rolled back, and the same sequence of creations runs again with that address.
        uint256 dryRun = vm.snapshotState();
        _deployFactoryAndRegistry(standardImpl, address(1));
        address predictedRegistry = address(registry);
        vm.revertToState(dryRun);
        _deployFactoryAndRegistry(standardImpl, predictedRegistry);
        vm.label(address(registry), "MarketRegistry");
        require(address(registry) == predictedRegistry, "registry prediction");
        vm.startPrank(address(timelock));
        registry.grantRole(PAUSE_GUARDIAN, emergencyGuardian);
        registry.grantRole(FREEZE_GUARDIAN, emergencyGuardian);
        registry.grantRole(PAUSE_GUARDIAN, aaveGuardian);
        registry.grantRole(FREEZE_GUARDIAN, aaveGuardian);
        vm.stopPrank();
    }

    /// @dev The VaultTokenFactory (naming `marketRegistry_`), the registry's logic contracts, implementation and proxy.
    function _deployFactoryAndRegistry(
        address standardImpl,
        address marketRegistry_
    ) internal {
        factory = new VaultTokenFactory(
            address(adapterMock), address(lpVaultSwap), address(collat), address(timelock), marketRegistry_
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
            parameterStore: address(ps),
            riskModule: address(rm),
            lpVaultSwap: address(lpVaultSwap),
            payoutEscrow: payoutEscrow,
            flashLiquidator: flashLiquidator,
            standardSpokeImplementation: standardImpl,
            maxMarketCount: _maxMarketCount()
        });
        logics = _deployLogics(im);
        MarketRegistry impl = new MarketRegistry(im, logics);
        registry = MarketRegistry(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(MarketRegistry.initialize, (address(timelock)))))
        );
    }

    function _deployLogics(
        MarketRegistryImmutables memory i
    ) internal returns (MarketRegistryLogics memory l) {
        l.hubs = address(new MarketRegistryHubsLogic(i));
        l.listing = address(new MarketRegistryListingLogic(i));
        l.activation = address(new MarketRegistryActivationLogic(i));
        l.routes = address(new MarketRegistryRoutesLogic(i));
        l.safety = address(new MarketRegistrySafetyLogic(i));
        l.windDown = address(new MarketRegistryWindDownLogic(i));
    }

    function _setUpWorld() internal {
        _deployRegistry();
        hub = new RegistryHubMock();
        spoke = new RegistrySpokeMock();
        aaveOracle = new RegistryAaveOracleMock();
        vm.label(address(hub), "StableLpHub");
        vm.label(address(spoke), "UniswapV3StableSpoke");
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

        _beforeIntegrationRegistered();
        vm.prank(address(timelock));
        factory.registerIntegration(V3, address(lpVault));
        vm.startPrank(address(timelock));
        registry.recordHub(address(hub), RiskTier.Stable);
        registry.registerIntegration(V3, address(lpVault), makeAddr("clPricing"));
        vm.stopPrank();
        _recordAmmContracts();
        vm.startPrank(address(timelock));
        registry.deployCdpSpoke(_spokeDef());
        registry.setFlashSource(address(flash));
        hub.setAsset(address(gho), GHO_ASSET);
        registry.setCoverageSpoke(address(hub), address(gho), address(ghoCoverage));
        registry.recordCreditLine(address(hub), address(gho), 20_000_000);
        vm.stopPrank();
        _setGhoReserve();
        // Every debt asset is a listed token with its issuer probe, a fixed-price one included (REQ-MREG-006).
        _listTokenWithProbe(address(gho), "gho", IssuerProbe.None);
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), _ghoDef());
        _listToken(address(usdc), "usdc");
        _listToken(address(usdt), "usdt");
    }

    /// @dev The registry's market-count limit (REQ-MREG-034); a suite that lists up to the limit lowers it.
    function _maxMarketCount() internal view virtual returns (uint256) {
        return 64;
    }

    /// @dev Records the integration's position manager and factory and finalizes the record, as the integration's
    /// listing batch does (REQ-MREG-035); a suite that needs an unrecorded or unfinalized integration overrides it.
    function _recordAmmContracts() internal virtual {
        ammPositionManager = address(new RegistryTokenMock(18));
        ammFactory = address(new RegistryTokenMock(18));
        vm.label(ammPositionManager, "v3PositionManager");
        vm.label(ammFactory, "v3Factory");
        address[] memory amm = new address[](2);
        (amm[0], amm[1]) = (ammPositionManager, ammFactory);
        vm.startPrank(address(timelock));
        registry.recordIntegrationContracts(V3, amm);
        registry.finalizeIntegrationContracts(V3);
        vm.stopPrank();
    }

    /// @dev The key of integration `id`'s AMM contract record: chain, LPVault address and code hash, AMM protocol tag
    /// and pool keying (REQ-MREG-035).
    function _recordKeyOf(
        uint32 id
    ) internal view returns (bytes32) {
        (address v,) = registry.integrationOf(id);
        IAmmIntegration a = IAmmIntegration(v);
        return keccak256(abi.encode(block.chainid, v, v.codehash, a.AMM_PROTOCOL(), a.capabilities().poolKeying));
    }

    /// @dev Runs after the mock LPVault is configured and before the factory records its pool keying and shape kind,
    /// which are fixed at registration; a suite that needs another keying sets it here.
    function _beforeIntegrationRegistered() internal virtual {}

    function _spokeDef() internal view returns (SpokeDef memory) {
        return SpokeDef({
            approved: false,
            hub: address(hub),
            integrationId: V3,
            riskTier: RiskTier.Stable,
            implementation: address(spokeImpl),
            aaveOracle: address(aaveOracle)
        });
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

    function _newFeed(
        string memory label
    ) internal returns (address f) {
        f = address(new RegistryFeedMock(8, 1e8));
        vm.label(f, label);
        ps.setFeed(f, 8, 86_400, 25, 25);
    }

    function _routes(
        string memory label
    ) internal returns (address[] memory p, address[] memory a, address[] memory s) {
        p = new address[](1);
        a = new address[](2);
        s = new address[](1);
        p[0] = _newFeed(string.concat(label, "/USD"));
        a[0] = _newFeed(string.concat(label, "/ETH"));
        a[1] = _newFeed(string.concat(label, "-ETH/USD"));
        s[0] = _newFeed(string.concat(label, "/USD standby"));
    }

    function _tokenDef(
        address[] memory p,
        address[] memory a,
        address[] memory s
    ) internal pure returns (TokenDef memory d) {
        d.isUsdStable = true;
        d.primaryRoute = p;
        d.alternateRoute = a;
        d.standbyRoute = s;
        d.replacedSlot = RouteSlot.None;
        d.issuerProbe = IssuerProbe.PausedFlag;
    }

    function _listToken(
        address token,
        string memory label
    ) internal {
        _listTokenWithProbe(token, label, IssuerProbe.PausedFlag);
    }

    function _listTokenWithProbe(
        address token,
        string memory label,
        IssuerProbe probe
    ) internal {
        (address[] memory p, address[] memory a, address[] memory s) = _routes(label);
        ps.setTolerance(token, 100, 50);
        TokenDef memory d = _tokenDef(p, a, s);
        d.issuerProbe = probe;
        vm.prank(address(timelock));
        registry.listToken(token, d);
    }

    function _shape() internal pure returns (PositionShape memory) {
        return PositionShape(ShapeKind.TickRange, -50, 50);
    }

    function _marketDef(
        address vaultToken,
        address lpOracle
    ) internal view returns (MarketDef memory d) {
        d.hub = address(hub);
        d.spoke = address(spoke);
        d.integrationId = V3;
        d.pool = pool;
        d.shape = _shape();
        d.vaultToken = vaultToken;
        d.lpOracle = lpOracle;
    }

    /// @dev Deploys the market's LPOracle and vault token (as the listing batch does) for `marketId`.
    function _deployTokenAndOracle(
        uint256 marketId,
        PositionShape memory shape
    ) internal returns (address vaultToken, RegistryLPOracleMock lpOracle) {
        lpOracle = new RegistryLPOracleMock(marketId, address(lpVault));
        vm.prank(address(timelock));
        vaultToken = factory.deployVaultToken(
            V3,
            pool,
            bytes32(0),
            shape,
            address(hub),
            address(spoke),
            marketId,
            address(lpOracle),
            18,
            "Avana USDC/USDT",
            "avUSDC-USDT"
        );
    }

    function _listMarket() internal returns (uint256 id, address vaultToken, RegistryLPOracleMock lpOracle) {
        (vaultToken, lpOracle) = _deployTokenAndOracle(registry.marketCount() + 1, _shape());
        vm.prank(address(timelock));
        id = registry.listCollateralMarket(_marketDef(vaultToken, address(lpOracle)));
    }

    /// @dev Sets the Aave payload of the market (Hub asset, reserve, caps), its ParameterStore values and its routes
    /// into GHO.
    function _prepareActivation(
        uint256 id,
        address vaultToken
    ) internal {
        hub.setAsset(vaultToken, VT_ASSET);
        hub.setSpokeConfig(VT_ASSET, address(spoke), 2_000_000, 0);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (vaultToken, address(hub), uint16(VT_ASSET), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (7500, 10_500);
        spoke.setReserve(VT_RESERVE, r, c, d);
        spoke.setLiquidationConfig(1.1e18, 5000);
        ps.setLiquidationExpectations(address(spoke), 1.1e18, 200);
        ps.setMarket(id, 9500, 10e8, 1_000_000e8, 100_000e8, 1e8);
        _setRoutesInto(id, address(gho));
    }

    function _setRoutesInto(
        uint256 id,
        address asset
    ) internal {
        _setRoute(id, address(usdc), asset, 0, "dexA");
        _setRoute(id, address(usdc), asset, 1, "dexB");
        _setRoute(id, address(usdt), asset, 0, "dexC");
        _setRoute(id, address(usdt), asset, 1, "dexD");
    }

    function _newRoute(
        address tokenIn,
        address tokenOut,
        string memory dep
    ) internal returns (RegistryRouteMock r) {
        address[] memory deps = new address[](1);
        deps[0] = makeAddr(dep);
        r = new RegistryRouteMock(tokenIn, tokenOut, address(lpVaultSwap), deps);
    }

    function _setRoute(
        uint256 id,
        address token,
        address asset,
        uint8 kind,
        string memory dep
    ) internal returns (address route) {
        route = address(_newRoute(token, asset, dep));
        vm.prank(address(timelock));
        registry.setRoute(id, token, asset, kind, route);
    }

    function _activeMarket() internal returns (uint256 id, address vaultToken, RegistryLPOracleMock lpOracle) {
        (id, vaultToken, lpOracle) = _listMarket();
        _prepareActivation(id, vaultToken);
        vm.prank(address(timelock));
        registry.activateMarket(id);
    }
}
