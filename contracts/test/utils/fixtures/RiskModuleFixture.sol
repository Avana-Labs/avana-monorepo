// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IssuerProbe} from "../../../src/policy/market-registry/types/IssuerProbe.sol";
import {MarketRegistryImmutables} from "../../../src/policy/market-registry/types/MarketRegistryImmutables.sol";
import {RiskTier} from "../../../src/policy/market-registry/types/RiskTier.sol";
import {RiskModule} from "../../../src/policy/risk-module/RiskModule.sol";
import {RiskModuleBorrowLogic} from "../../../src/policy/risk-module/RiskModuleBorrowLogic.sol";
import {RiskModuleBreakerLogic} from "../../../src/policy/risk-module/RiskModuleBreakerLogic.sol";
import {RiskModuleDriftLogic} from "../../../src/policy/risk-module/RiskModuleDriftLogic.sol";
import {RiskModulePledgeLogic} from "../../../src/policy/risk-module/RiskModulePledgeLogic.sol";
import {RiskModuleSpeedLogic} from "../../../src/policy/risk-module/RiskModuleSpeedLogic.sol";
import {RiskModuleStatusLogic} from "../../../src/policy/risk-module/RiskModuleStatusLogic.sol";
import {PledgeCharge} from "../../../src/policy/risk-module/types/PledgeCharge.sol";
import {RiskModuleImmutables} from "../../../src/policy/risk-module/types/RiskModuleImmutables.sol";
import {RiskModuleLogics} from "../../../src/policy/risk-module/types/RiskModuleLogics.sol";
import {PositionProxy} from "../../../src/proxy/position-proxy/PositionProxy.sol";
import {MarketDef} from "../../../src/types/MarketDef.sol";
import {PledgeCounters} from "../../../src/types/PledgeCounters.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {VaultTokenFactory} from "../../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {RegistryAaveOracleMock, RegistrySpokeImplMock} from "../mocks/MarketRegistryAaveMocks.sol";
import {
    RegistryAvanaFirstLossReserveMock,
    RegistryFeedMock,
    RegistryFlashSourceMock
} from "../mocks/MarketRegistryMocks.sol";
import {
    RiskAdapterMock,
    RiskCollateralizationMock,
    RiskDebtOracleMock,
    RiskHubMock,
    RiskLPOracleMock,
    RiskLPVaultMock,
    RiskSpokeMock,
    RiskStoreMock,
    RiskSwapMock,
    RiskTokenMock
} from "../mocks/RiskModuleMocks.sol";
import {MarketRegistryFixture} from "./MarketRegistryFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title RiskModuleFixture
/// @notice The real RiskModule (five logic contracts, implementation, ERC-1967 proxy) wired to the real MarketRegistry,
/// the real VaultTokenFactory and vault token, and real PositionProxies; settable mocks stand for the Aave V4 Hub,
/// Spoke and AaveOracle reads, the ParameterStore views (its market listing writes need the full listing world: pool
/// observations and the LPOracle's own configuration), the market's LPOracle and AMM integration, Collateralization's
/// views and LPVaultSwap's keeper count.
/// @dev World after `_deployRiskWorld`: Stable LP Hub, integration 1, the CDP Spoke, GHO debt reserve 0 (fixed price),
/// USDC and USDT listed, market `MID` (USDC/USDT `[-50, 50]`, `d = 18`) Active at $2.00 per whole vault token with
/// `CF = 3,000`, `marketUsdCap = $1,000,000`, `topUpSliceUsd = $100,000`, `stressFloorUsd = $1.00`, `minPledgeUsd = $10`,
/// routes into GHO, one active keeper, and the wallet's proxy `proxy` with the vault-token reserve as collateral.
abstract contract RiskModuleFixture is MarketRegistryFixture {
    uint256 internal constant T0 = 1_762_650_000;
    uint32 internal constant FEED_AGE = 88_200;

    RiskModule internal riskModule;
    RiskModuleImmutables internal rmIm;
    RiskModuleLogics internal rmLogics;
    RiskStoreMock internal store;
    RiskCollateralizationMock internal coll;
    RiskAdapterMock internal adapter;
    RiskSwapMock internal swap;
    RiskHubMock internal rHub;
    RiskSpokeMock internal rSpoke;
    RiskLPVaultMock internal rVault;
    RiskLPOracleMock internal oracle;
    RiskTokenMock internal tUsdc;
    RiskTokenMock internal tUsdt;
    RiskTokenMock internal tGho;
    PositionProxy internal proxy;
    uint256 internal mid;
    address internal vaultToken;
    address internal wallet = makeAddr("wallet");
    address internal feeReceiver = makeAddr("hubFeeReceiver");
    address internal feedUsdc = makeAddr("feed USDC/USD");
    address internal feedUsdt = makeAddr("feed USDT/USD");
    bytes32 internal poolKey;
    RiskDebtOracleMock internal usdcOracle;
    uint256 internal constant USDC_RESERVE = 5;
    uint256 internal constant USDC_ASSET = 2;
    RiskHubMock internal hub2;
    RiskTokenMock internal tDai;
    uint256 internal constant DAI_RESERVE = 6;
    uint256 internal constant DAI_ASSET = 3;

    function _deployRiskWorld() internal {
        vm.warp(T0);
        _deployContracts();
        _world();
        _market();
        _account();
    }

    /// @dev MarketRegistry and RiskModule, each at the address the other was built with.
    function _deployContracts() internal {
        _deployTimelock();
        coll = new RiskCollateralizationMock(lockAddr);
        collat = coll;
        store = new RiskStoreMock();
        ps = store;
        adapter = new RiskAdapterMock();
        adapterMock = adapter;
        swap = new RiskSwapMock();
        spokeImpl = new RegistrySpokeImplMock();
        // The factory names the registry, which is created after it: a dry run finds the registry's address, the state
        // is rolled back, and the same sequence of creations runs again with that address.
        uint256 dryRun = vm.snapshotState();
        _deployFactoryRegistryAndRisk(address(1));
        address registryAddress = address(registry);
        vm.revertToState(dryRun);
        _deployFactoryRegistryAndRisk(registryAddress);
        vm.label(address(registry), "MarketRegistry");
        vm.label(address(riskModule), "RiskModule");
        vm.startPrank(address(timelock));
        registry.grantRole(PAUSE_GUARDIAN, emergencyGuardian);
        registry.grantRole(FREEZE_GUARDIAN, emergencyGuardian);
        vm.stopPrank();
    }

    /// @dev The VaultTokenFactory (naming `marketRegistry_`), the MarketRegistry and the RiskModule, each at the address
    /// the other was built with.
    function _deployFactoryRegistryAndRisk(
        address marketRegistry_
    ) internal {
        factory = new VaultTokenFactory(
            address(adapter), address(lpVaultSwap), address(coll), address(timelock), marketRegistry_
        );
        coll.setCore(address(factory), address(adapter), address(lpVaultSwap));
        uint256 n = vm.getNonce(address(this));
        address predictedRegistry = vm.computeCreateAddress(address(this), n + 7);
        address predictedRisk = vm.computeCreateAddress(address(this), n + 15);
        im = MarketRegistryImmutables({
            timelock: address(timelock),
            aaveGovernanceExecutor: aaveGovernanceExecutor,
            vaultTokenFactory: address(factory),
            aaveAdapter: address(adapter),
            collateralization: address(coll),
            lock: lockAddr,
            proxyManager: proxyManager,
            parameterStore: address(store),
            riskModule: predictedRisk,
            lpVaultSwap: address(lpVaultSwap),
            payoutEscrow: payoutEscrow,
            flashLiquidator: flashLiquidator,
            standardSpokeImplementation: address(spokeImpl),
            maxMarketCount: 64
        });
        logics = _deployLogics(im);
        MarketRegistry impl = new MarketRegistry(im, logics);
        registry = MarketRegistry(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(MarketRegistry.initialize, (address(timelock)))))
        );
        require(address(registry) == predictedRegistry, "registry prediction");
        rmIm = RiskModuleImmutables({
            marketRegistry: address(registry),
            parameterStore: address(store),
            collateralization: address(coll),
            adapter: address(adapter),
            lpVaultSwap: address(swap),
            timelock: address(timelock)
        });
        rmLogics = _deployRiskLogics(rmIm);
        RiskModule rmImpl = new RiskModule(rmIm, rmLogics);
        riskModule = RiskModule(
            address(new ERC1967Proxy(address(rmImpl), abi.encodeCall(RiskModule.initialize, (address(timelock)))))
        );
        require(address(riskModule) == predictedRisk, "risk module prediction");
    }

    function _deployRiskLogics(
        RiskModuleImmutables memory i
    ) internal returns (RiskModuleLogics memory l) {
        l.drift = address(new RiskModuleDriftLogic(i));
        l.breaker = address(new RiskModuleBreakerLogic(i, l.drift));
        l.pledge = address(new RiskModulePledgeLogic(i, l.drift, l.breaker));
        l.borrow = address(new RiskModuleBorrowLogic(i, l.drift, l.breaker));
        l.status = address(new RiskModuleStatusLogic(i, l.drift, l.breaker, l.borrow));
        l.speed = address(new RiskModuleSpeedLogic(i));
    }

    /// @dev Hub, Spoke, tokens and the GHO debt reserve, as `MarketRegistryFixture._setUpWorld` with richer mocks.
    function _world() internal {
        rHub = new RiskHubMock();
        hub = rHub;
        rSpoke = new RiskSpokeMock();
        spoke = rSpoke;
        aaveOracle = new RegistryAaveOracleMock();
        spoke.setOracle(address(aaveOracle));
        spoke.setImplementation(address(spokeImpl));
        aaveOracle.setSpoke(address(spoke));
        rVault = new RiskLPVaultMock(V3, address(coll), lockAddr);
        lpVault = rVault;
        lpVault.setRegistry(address(registry));
        tUsdc = new RiskTokenMock(6);
        tUsdt = new RiskTokenMock(6);
        tGho = new RiskTokenMock(18);
        (usdc, usdt, gho) = (tUsdc, tUsdt, tGho);
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        lpVault.setPoolTokens(toks, 18);
        flash = new RegistryFlashSourceMock(aaveV3Pool, address(lpVaultSwap));
        ghoSource = new RegistryFeedMock(8, 1e8);
        ghoCoverage = new RegistryAvanaFirstLossReserveMock(address(hub), address(gho), GHO_ASSET);
        ghoCoverage.setFunded(4e24, false);
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
        registry.setAvanaFirstLossReserve(address(hub), address(gho), address(ghoCoverage));
        registry.recordCreditLine(address(hub), address(gho), 20_000_000);
        vm.stopPrank();
        _setGhoReserve();
        rSpoke.setReserveCount(1);
        rHub.setThreshold(GHO_ASSET, address(spoke), type(uint24).max);
        rHub.setActive(GHO_ASSET, address(spoke), true, false);
        // Every debt asset is a listed token with its issuer probe, a fixed-price one included (REQ-MREG-006).
        _listTokenWithProbe(address(gho), "gho", _ghoIssuerProbe());
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), _ghoDef());
        _listToken(address(usdc), "usdc");
        _listToken(address(usdt), "usdt");
        store.setTokenCf(address(usdc), 7800);
        store.setTokenCf(address(usdt), 7500);
        spoke.setLiquidationConfig(1.1e18, 5000);
        store.setLiquidationExpectations(address(spoke), 1.1e18, 200);
    }

    /// @dev Issuer probe GHO is listed with; a suite that checks a probe on the GHO reserve overrides it.
    function _ghoIssuerProbe() internal pure virtual returns (IssuerProbe) {
        return IssuerProbe.None;
    }

    /// @dev Lists and activates market `mid`.
    function _market() internal {
        mid = registry.marketCount() + 1;
        oracle = new RiskLPOracleMock(mid, address(lpVault));
        vm.prank(address(timelock));
        vaultToken = factory.deployVaultToken(
            V3,
            pool,
            bytes32(0),
            _shape(),
            address(hub),
            address(spoke),
            mid,
            address(oracle),
            18,
            "Avana USDC/USDT",
            "avUSDC-USDT"
        );
        store.setMarket(mid, 4000, 10e8, 1_000_000e8, 100_000e8, 1e8);
        store.setTwap(mid, 1800);
        vm.prank(address(timelock));
        registry.listCollateralMarket(_marketDef(vaultToken, address(oracle)));
        hub.setAsset(vaultToken, VT_ASSET);
        hub.setSpokeConfig(VT_ASSET, address(spoke), 2_000_000, 0);
        rHub.setActive(VT_ASSET, address(spoke), true, false);
        rHub.setThreshold(VT_ASSET, address(spoke), type(uint24).max);
        rHub.setFeeReceiver(VT_ASSET, feeReceiver);
        address[] memory spokes = new address[](2);
        (spokes[0], spokes[1]) = (address(spoke), feeReceiver);
        rHub.setSpokes(VT_ASSET, spokes);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (vaultToken, address(hub), uint16(VT_ASSET), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (3000, 10_500);
        spoke.setReserve(VT_RESERVE, r, c, d);
        rSpoke.setReserveCount(2);
        aaveOracle.setSource(VT_RESERVE, address(oracle));
        _setRoutesInto(mid, address(gho));
        vm.prank(address(timelock));
        registry.activateMarket(mid);
        poolKey = keccak256(abi.encode(V3, pool, bytes32(0)));
        store.setTokenCap(address(hub), address(usdc), 10_000_000e8);
        store.setTokenCap(address(hub), address(usdt), 10_000_000e8);
        store.setDepositorCap(address(hub), 5_000_000e8);
        store.setBorrowAge(feedUsdc, FEED_AGE);
        store.setBorrowAge(feedUsdt, FEED_AGE);
        _report(uint64(block.timestamp), 1e8, 1e8);
    }

    /// @dev The wallet's proxy with the vault-token reserve enabled as collateral and supplied.
    function _account() internal {
        proxy = new PositionProxy(address(adapter), wallet, address(spoke), mid);
        rSpoke.setStatus(address(proxy), VT_RESERVE, true, false);
        rSpoke.setSupplied(address(proxy), VT_RESERVE, 1e21);
        adapter.setProxy(wallet, mid, address(proxy), true);
    }

    /// @dev The LPOracle's per-token report: two tokens, one leg each, updated at `at`, quotes `q0`, `q1`.
    function _report(
        uint64 at,
        uint256 q0,
        uint256 q1
    ) internal {
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        address[] memory feeds = new address[](2);
        (feeds[0], feeds[1]) = (feedUsdc, feedUsdt);
        uint64[] memory ats = new uint64[](2);
        (ats[0], ats[1]) = (at, at);
        uint256[] memory quotes = new uint256[](2);
        (quotes[0], quotes[1]) = (q0, q1);
        oracle.setTokens(toks, feeds, ats, quotes, new uint32[](2));
    }

    /// @dev Puts the account in debt: GHO reserve borrowed, health factor `hf`, debt `debtUsd` (whole USD).
    function _debt(
        uint256 hf,
        uint256 debtUsd
    ) internal {
        rSpoke.setStatus(address(proxy), GHO_RESERVE, false, true);
        rSpoke.setAccount(address(proxy), hf, debtUsd * 1e26 * RAY, 1);
    }

    /// @dev Enables USDC as debt reserve 5 (asset 2), priced by its DebtOracle, with routes from USDT into USDC.
    function _enableUsdcDebt() internal {
        usdcOracle = new RiskDebtOracleMock(address(usdc), address(registry), address(store));
        RegistryAvanaFirstLossReserveMock usdcCoverage =
            new RegistryAvanaFirstLossReserveMock(address(hub), address(usdc), USDC_ASSET);
        usdcCoverage.setFunded(2e12, false);
        hub.setAsset(address(usdc), USDC_ASSET);
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, 500_000);
        rHub.setThreshold(USDC_ASSET, address(spoke), type(uint24).max);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(usdc), address(hub), uint16(USDC_ASSET), 6);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        spoke.setReserve(USDC_RESERVE, r, c, d);
        rSpoke.setReserveCount(USDC_RESERVE + 1);
        aaveOracle.setSource(USDC_RESERVE, address(usdcOracle));
        store.setStressRise(address(usdc), 500);
        vm.startPrank(address(timelock));
        registry.setAvanaFirstLossReserve(address(hub), address(usdc), address(usdcCoverage));
        registry.recordCreditLine(address(hub), address(usdc), 1_000_000);
        vm.stopPrank();
        _setRoute(mid, address(usdt), address(usdc), 0, "dexE");
        _setRoute(mid, address(usdt), address(usdc), 1, "dexF");
        DebtReserveDef memory def = DebtReserveDef({
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
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), def);
    }

    /// @dev Enables DAI (listed) as debt reserve 6 on the CDP Spoke, funded by a second Hub (asset 3, fixed price):
    /// cross-Hub lines on, a 1,000,000 DAI credit line with a 500,000 DAI draw cap, routes from USDC and USDT into DAI.
    function _enableCrossHubDebt() internal {
        hub2 = new RiskHubMock();
        tDai = new RiskTokenMock(18);
        RegistryFeedMock daiSource = new RegistryFeedMock(8, 1e8);
        hub2.setAsset(address(tDai), DAI_ASSET);
        hub2.setSpokeConfig(DAI_ASSET, address(spoke), 0, 500_000);
        hub2.setThreshold(DAI_ASSET, address(spoke), type(uint24).max);
        RegistryAvanaFirstLossReserveMock daiCoverage =
            new RegistryAvanaFirstLossReserveMock(address(hub2), address(tDai), DAI_ASSET);
        daiCoverage.setFunded(4e24, false);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(tDai), address(hub2), uint16(DAI_ASSET), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        spoke.setReserve(DAI_RESERVE, r, c, IAaveV4Spoke.DynamicReserveConfig(0, 0, 0));
        rSpoke.setReserveCount(DAI_RESERVE + 1);
        aaveOracle.setSource(DAI_RESERVE, address(daiSource));
        vm.startPrank(address(timelock));
        registry.recordHub(address(hub2), RiskTier.Stable);
        registry.setAvanaFirstLossReserve(address(hub2), address(tDai), address(daiCoverage));
        registry.recordCreditLine(address(hub2), address(tDai), 1_000_000);
        registry.setCrossHubLinesEnabled(true);
        // Base units: 1,000,000 DAI, within the 4,000,000 DAI coverage and above the 500,000 DAI draw cap.
        registry.setCrossHubLine(address(hub2), address(tDai), address(spoke), 1_000_000e18);
        vm.stopPrank();
        _listToken(address(tDai), "dai");
        _setRoutesInto(mid, address(tDai));
        DebtReserveDef memory def = DebtReserveDef({
            reserveId: DAI_RESERVE,
            asset: address(tDai),
            decimals: 18,
            fundingHub: address(hub2),
            hubAssetId: DAI_ASSET,
            priceSource: address(daiSource),
            fixedPrice: true,
            firstLossReserve: address(daiCoverage),
            crossHub: true,
            approved: false
        });
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), def);
    }

    /// @dev Lists a second market of the same pool and Spoke, `[-100, 100]`, left `Registered` (not activated).
    function _listRegisteredMarket() internal returns (uint256 id) {
        id = registry.marketCount() + 1;
        PositionShape memory shape = PositionShape(ShapeKind.TickRange, -100, 100);
        RiskLPOracleMock o = new RiskLPOracleMock(id, address(lpVault));
        vm.prank(address(timelock));
        address vt = factory.deployVaultToken(
            V3,
            pool,
            bytes32(0),
            shape,
            address(hub),
            address(spoke),
            id,
            address(o),
            18,
            "Avana USDC/USDT wide",
            "avUSDC-USDT-w"
        );
        store.setMarket(id, 4000, 10e8, 1_000_000e8, 100_000e8, 1e8);
        store.setTwap(id, 1800);
        MarketDef memory d = _marketDef(vt, address(o));
        d.shape = shape;
        vm.prank(address(timelock));
        registry.listCollateralMarket(d);
    }

    /// @dev Counters of an empty market: two token counters.
    function _counters() internal view returns (PledgeCounters memory k) {
        k.hub = address(hub);
        k.poolKey = poolKey;
        k.tokenUsed = new uint256[](2);
    }

    /// @dev `checkPledge` for the wallet's proxy.
    function _pledge(
        uint128 units,
        PledgeCounters memory k,
        bool requireRescue
    ) internal returns (PledgeCharge memory) {
        return riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), units, k, requireRescue);
    }
}
