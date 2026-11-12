// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CoverageSpoke} from "../../../src/coverage/coverage-spoke/CoverageSpoke.sol";
import {ICollateralization} from "../../../src/custody/collateralization/ICollateralization.sol";
import {AaveV3FlashSource} from "../../../src/flash/AaveV3FlashSource.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwap} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {LPVaultSwap} from "../../../src/liquidation/lp-vault-swap/LPVaultSwap.sol";
import {LPVaultSwapImmutables} from "../../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {LPVaultSwapLogics} from "../../../src/liquidation/lp-vault-swap/types/LPVaultSwapLogics.sol";
import {LiquidationParams} from "../../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {PayoutEscrow} from "../../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {DexPathRoute} from "../../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {DexHop, HopKind} from "../../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {Market} from "../../../src/types/Market.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {VaultTokenFactory} from "../../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {AaveAdapterMock} from "../mocks/AaveAdapterMock.sol";
import {MockAaveV3ACLManager, MockAaveV3AddressesProvider, MockAaveV3Pool} from "../mocks/AaveV3PoolMocks.sol";
import {CollLPVaultMock, CollRiskModuleMock} from "../mocks/CollateralizationMocks.sol";
import {
    LVSDebtOracleMock,
    LVSLPOracleMock,
    LVSMarketRegistryMock,
    LVSParameterStoreMock
} from "../mocks/LPVaultSwapMocks.sol";
import {PayoutToken} from "../mocks/PayoutToken.sol";
import {MockCLPool, MockPoolFactory} from "../mocks/SwapRouteMocks.sol";
import {AaveV4Fixture} from "./AaveV4Fixture.sol";
import {
    CollHubSpokeConfig,
    CollInterestRateData,
    CollPriceSource,
    CollSpokeDynamicReserveConfig,
    CollSpokeLiquidationConfig,
    CollSpokeReserveConfig,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "./CollateralizationFixture.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title LPVaultSwapFixture
/// @notice The real LPVaultSwap (implementation, three logic contracts, ERC-1967 proxy, launch committed operator
/// `keeper`) on the real local Aave V4 (Stable LP Hub, Uniswap v3 Stable CDP Spoke, Lend Spoke), with the real Lock,
/// VaultTokenFactory and vault token, Collateralization, PositionProxies, PayoutEscrow, two Coverage Spokes (USDC and
/// GHO), `DexPathRoute` swap routes over pinned mock pools, and the `AaveV3FlashSource` over a mocked Aave V3.4 Pool.
/// The AaveAdapter is `AaveAdapterMock` (written at the same time as LPVaultSwap); the MarketRegistry, ParameterStore,
/// LPOracle, DebtOracle, LPVault and RiskModule are stand-ins whose state each test sets.
/// @dev Market 4: USDC/USDT (6 decimals each), vault token of 6 decimals priced by the LPOracle stand-in at $2.10
/// (USDC $1.00, USDT $0.9995 as leg prices). Debt reserves on the CDP Spoke: USDC (DebtOracle, the market's settlement
/// reserve) and GHO (fixed $1.00 source). Each unwound unit pays `USDC_RATE` and `USDT_RATE` raw units per 1e6 units.
/// Routes into USDC: USDT primary and backup at 0.9995; into GHO: USDC and USDT at 1:1 (decimals scaled). Launch
/// parameters: `slippageAllowanceBps = 100`, `ε` 1 USDC and 1 GHO, `avanaFeeShareBps = 2,000`, `maxShortfallBps =
/// 1,000`, `maxFlashFeeBps = 10`, Pool premium 5 bps.
abstract contract LPVaultSwapFixture is AaveV4Fixture {
    uint32 internal constant INTEGRATION = 1;
    uint256 internal constant MARKET_ID = 4;
    uint8 internal constant VT_DECIMALS = 6;
    uint256 internal constant USDC_RATE = 1_056_615;
    uint256 internal constant USDT_RATE = 1_036_000;
    uint256 internal constant P_USDT = 99_950_000;
    uint256 internal constant P_VAULT = 210_000_000;
    uint256 internal constant SLIPPAGE_BPS = 100;
    uint40 internal constant DEFAULT_BORROW_CAP = 10_000_000;

    address internal timelock = makeAddr("timelock");
    address internal pool = makeAddr("usdcUsdtPool");

    AaveAdapterMock internal adapter;
    ILPVaultSwap internal lvs;
    LPVaultSwap internal implementation;
    address internal liquidationLogic;
    address internal pendingLogic;
    address internal deleverageLogic;
    Lock internal lock;
    PayoutEscrow internal escrow;
    VaultTokenFactory internal factory;
    ICollateralization internal coll;
    CollLPVaultMock internal lpVault;
    CollRiskModuleMock internal riskModule;
    LVSMarketRegistryMock internal registry;
    LVSParameterStoreMock internal store;
    LVSLPOracleMock internal lpOracle;
    LVSDebtOracleMock internal usdcOracle;
    CollPriceSource internal ghoPrice;
    PayoutToken internal usdc;
    PayoutToken internal usdt;
    PayoutToken internal gho;
    VaultToken internal vt;
    CoverageSpoke internal usdcCoverage;
    CoverageSpoke internal ghoCoverage;
    MockAaveV3Pool internal v3Pool;
    MockAaveV3ACLManager internal acl;
    AaveV3FlashSource internal flashSource;
    MockPoolFactory internal v3Factory;
    MockPoolFactory internal slipFactory;
    MockPoolFactory internal curveFactory;
    MockCLPool internal usdtUsdcPool;
    MockCLPool internal usdtUsdcPool2;
    DexPathRoute internal usdtPrimary;
    DexPathRoute internal usdtBackup;
    DexPathRoute internal usdcToGho;
    DexPathRoute internal usdtToGho;

    uint256 internal vtReserveId;
    uint256 internal usdcReserveId;
    uint256 internal ghoReserveId;
    uint256 internal vtAssetId;
    uint256 internal usdcAssetId;
    uint256 internal ghoAssetId;
    uint256 internal nextKey = 1;

    function _deployLPVaultSwap() internal {
        vm.warp(1_780_000_000);
        _deployAaveV4();
        usdc = new PayoutToken("USDC", 6);
        usdt = new PayoutToken("USDT", 6);
        gho = new PayoutToken("GHO", 18);
        adapter = new AaveAdapterMock();
        registry = new LVSMarketRegistryMock();
        store = new LVSParameterStoreMock();
        riskModule = new CollRiskModuleMock();
        _deployCore();
        _deployMarket();
        _listAave();
        _deployCoverage();
        _configure();
        _deployRoutes();
        _deployFlash();
        _labels();
    }

    // ─── Deployment ───

    function _deployCore() private {
        uint256 n0 = vm.getNonce(address(this));
        address predictedColl = vm.computeCreateAddress(address(this), n0 + 3);
        address predictedProxy = vm.computeCreateAddress(address(this), n0 + 8);
        lock = new Lock(address(adapter), predictedProxy);
        escrow = new PayoutEscrow(predictedProxy, address(lock));
        factory = new VaultTokenFactory(address(adapter), predictedProxy, predictedColl, timelock, address(registry));
        coll = ICollateralization(
            deployCode(
                "Collateralization.sol:Collateralization",
                abi.encode(address(adapter), predictedProxy, address(riskModule), address(lock), address(factory))
            )
        );
        require(address(coll) == predictedColl, "predicted Collateralization");
        LPVaultSwapImmutables memory im = immutables();
        liquidationLogic = deployCode("LPVaultSwapLiquidationLogic.sol:LPVaultSwapLiquidationLogic", abi.encode(im));
        pendingLogic = deployCode("LPVaultSwapPendingLogic.sol:LPVaultSwapPendingLogic", abi.encode(im));
        deleverageLogic = deployCode("LPVaultSwapDeleverageLogic.sol:LPVaultSwapDeleverageLogic", abi.encode(im));
        implementation = new LPVaultSwap(im, LPVaultSwapLogics(liquidationLogic, pendingLogic, deleverageLogic));
        address[] memory keepers = new address[](1);
        keepers[0] = keeper;
        lvs = ILPVaultSwap(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeCall(LPVaultSwap.initialize, (timelock, keepers)))
            )
        );
        require(address(lvs) == predictedProxy, "predicted LPVaultSwap");
        adapter.setCore(address(lock), address(lvs), address(coll));
    }

    /// @notice The construction values of the implementation and its logic contracts.
    function immutables() public view returns (LPVaultSwapImmutables memory im) {
        im = LPVaultSwapImmutables({
            lock: address(lock),
            aaveAdapter: address(adapter),
            collateralization: address(coll),
            marketRegistry: address(registry),
            parameterStore: address(store),
            payoutEscrow: address(escrow),
            keeperFloor: KEEPER_FLOOR
        });
    }

    function _deployMarket() private {
        lpVault = new CollLPVaultMock(INTEGRATION, address(coll), address(lock));
        lpVault.setCore(timelock, address(registry));
        vm.prank(timelock);
        factory.registerIntegration(INTEGRATION, address(lpVault));
        uint256[] memory prices = new uint256[](2);
        prices[0] = PRICE_UNIT;
        prices[1] = P_USDT;
        lpOracle = new LVSLPOracleMock(int256(P_VAULT), _pair(address(usdc), address(usdt)), prices);
        usdcOracle = new LVSDebtOracleMock(int256(PRICE_UNIT));
        ghoPrice = new CollPriceSource(int256(PRICE_UNIT));
        uint256[] memory rates = new uint256[](2);
        rates[0] = USDC_RATE;
        rates[1] = USDT_RATE;
        lpVault.bind(MARKET_ID, pool, _pair(address(usdc), address(usdt)), rates);
        usdc.mint(address(lpVault), 1e30);
        usdt.mint(address(lpVault), 1e30);
        vm.prank(timelock);
        vt = VaultToken(
            factory.deployVaultToken(
                INTEGRATION,
                pool,
                bytes32(0),
                PositionShape(ShapeKind.TickRange, -50, 50),
                aave.hub,
                aave.cdpSpoke,
                MARKET_ID,
                address(lpOracle),
                VT_DECIMALS,
                "Avana USDC/USDT",
                "avLP-4"
            )
        );
        adapter.bindMarket(MARKET_ID, address(vt));
    }

    function _listAave() private {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        ICollHubConfigurator hubCfg = ICollHubConfigurator(aave.hubConfigurator);
        vm.startPrank(aaveDao);
        usdcAssetId = _addDebtAsset(hubCfg, address(usdc), 6, maxCap, maxRp);
        ghoAssetId = _addDebtAsset(hubCfg, address(gho), 18, maxCap, maxRp);
        ICollSpokeConfigurator spokeCfg = ICollSpokeConfigurator(aave.spokeConfigurator);
        usdcReserveId = _addDebtReserve(spokeCfg, usdcAssetId, address(usdcOracle));
        ghoReserveId = _addDebtReserve(spokeCfg, ghoAssetId, address(ghoPrice));
        vtAssetId = hubCfg.addAssetWithDecimals(
            aave.hub, address(vt), VT_DECIMALS, aave.treasurySpoke, 0, aave.irStrategy, _irData()
        );
        hubCfg.addSpoke(aave.hub, aave.cdpSpoke, vtAssetId, CollHubSpokeConfig(maxCap, 0, maxRp, true, false));
        vtReserveId = spokeCfg.addReserve(
            aave.cdpSpoke,
            aave.hub,
            vtAssetId,
            address(lpOracle),
            CollSpokeReserveConfig(0, false, false, false, false),
            CollSpokeDynamicReserveConfig(8000, 10_500, 0)
        );
        spokeCfg.updateLiquidationConfig(aave.cdpSpoke, CollSpokeLiquidationConfig(1.1e18, 0.95e18, 5000));
        vm.stopPrank();
        _supplyCreditLine(usdc, 10_000_000e6);
        _supplyCreditLine(gho, 10_000_000e18);
    }

    function _addDebtAsset(
        ICollHubConfigurator hubCfg,
        address token,
        uint8 decimals,
        uint40 maxCap,
        uint24 maxRp
    ) private returns (uint256 assetId) {
        assetId =
            hubCfg.addAssetWithDecimals(aave.hub, token, decimals, aave.treasurySpoke, 0, aave.irStrategy, _irData());
        hubCfg.addSpoke(aave.hub, aave.lendSpoke, assetId, CollHubSpokeConfig(maxCap, 0, maxRp, true, false));
        hubCfg.addSpoke(aave.hub, aave.cdpSpoke, assetId, CollHubSpokeConfig(0, DEFAULT_BORROW_CAP, maxRp, true, false));
    }

    function _addDebtReserve(
        ICollSpokeConfigurator spokeCfg,
        uint256 assetId,
        address source
    ) private returns (uint256 reserveId) {
        spokeCfg.addReserve(
            aave.lendSpoke,
            aave.hub,
            assetId,
            source,
            CollSpokeReserveConfig(0, false, false, true, false),
            CollSpokeDynamicReserveConfig(0, 10_000, 0)
        );
        reserveId = spokeCfg.addReserve(
            aave.cdpSpoke,
            aave.hub,
            assetId,
            source,
            CollSpokeReserveConfig(0, false, false, true, false),
            CollSpokeDynamicReserveConfig(0, 10_000, 0)
        );
    }

    function _supplyCreditLine(
        PayoutToken token,
        uint256 amount
    ) private {
        uint256 lendReserve =
            IAaveV4Spoke(aave.lendSpoke).getReserveId(aave.hub, token == usdc ? usdcAssetId : ghoAssetId);
        token.mint(daoTreasury, amount);
        vm.startPrank(daoTreasury);
        token.approve(aave.lendSpoke, amount);
        IAaveV4Spoke(aave.lendSpoke).supply(lendReserve, amount, daoTreasury);
        vm.stopPrank();
    }

    function _deployCoverage() private {
        usdcCoverage = _coverageSpoke(address(usdc), usdcAssetId, "UsdcCoverageSpoke");
        ghoCoverage = _coverageSpoke(address(gho), ghoAssetId, "GhoCoverageSpoke");
    }

    function _coverageSpoke(
        address token,
        uint256 assetId,
        string memory label
    ) private returns (CoverageSpoke cs) {
        cs = new CoverageSpoke(aave.hub, token, assetId, aave.accessManager, 1_209_600);
        vm.label(address(cs), label);
        uint24 maxRp = IAaveV4Hub(aave.hub).MAX_RISK_PREMIUM_THRESHOLD();
        vm.prank(aaveDao);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, address(cs), assetId, CollHubSpokeConfig(1_000_000, 0, maxRp, true, false));
        _grantDeficitEliminator(address(cs));
    }

    function _configure() private {
        Market memory m;
        m.chainId = uint64(block.chainid);
        m.hub = aave.hub;
        m.spoke = aave.cdpSpoke;
        m.integrationId = INTEGRATION;
        m.integration = address(lpVault);
        m.pool = pool;
        m.shape = PositionShape(ShapeKind.TickRange, -50, 50);
        m.tokens = _pair(address(usdc), address(usdt));
        m.tokenDecimals = new uint8[](2);
        m.tokenDecimals[0] = 6;
        m.tokenDecimals[1] = 6;
        m.vaultToken = address(vt);
        m.decimals = VT_DECIMALS;
        m.lpOracle = address(lpOracle);
        m.hubAssetId = vtAssetId;
        m.reserveId = vtReserveId;
        m.status = MarketStatus.Active;
        registry.setMarket(MARKET_ID, m);
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, _debtDef(usdcReserveId, address(usdc), 6, false), true);
        registry.setDebtReserve(aave.cdpSpoke, ghoReserveId, _debtDef(ghoReserveId, address(gho), 18, true), true);
        registry.setSettlementReserve(MARKET_ID, usdcReserveId);
        registry.setCoverageSpoke(aave.hub, address(usdc), address(usdcCoverage));
        registry.setCoverageSpoke(aave.hub, address(gho), address(ghoCoverage));
        registry.setRecordedHub(aave.hub, true);
        store.setSlippage(MARKET_ID, uint16(SLIPPAGE_BPS));
        store.setFloorRoundingAllowance(address(usdc), FLOOR_ROUNDING_ALLOWANCE_USDC);
        store.setFloorRoundingAllowance(address(gho), FLOOR_ROUNDING_ALLOWANCE_GHO);
        store.setFeeRecipient(feeRecipient);
    }

    function _debtDef(
        uint256 reserveId,
        address asset,
        uint8 decimals,
        bool fixedPrice
    ) internal view returns (DebtReserveDef memory d) {
        d.reserveId = reserveId;
        d.asset = asset;
        d.decimals = decimals;
        d.fundingHub = aave.hub;
        d.hubAssetId = asset == address(usdc) ? usdcAssetId : ghoAssetId;
        d.priceSource = fixedPrice ? address(ghoPrice) : address(usdcOracle);
        d.fixedPrice = fixedPrice;
        d.coverageSpoke = asset == address(usdc) ? address(usdcCoverage) : address(ghoCoverage);
        d.approved = true;
    }

    function _deployRoutes() private {
        v3Factory = new MockPoolFactory();
        slipFactory = new MockPoolFactory();
        curveFactory = new MockPoolFactory();
        // Each route is checked against the pinned factory's pool for its pair when it is built, so the backup's
        // pool of the same pair is registered after the primary is built.
        usdtUsdcPool = _clPool(usdt, usdc, 9995, 10_000);
        usdtPrimary = _route(address(usdt), address(usdc), usdtUsdcPool);
        usdtUsdcPool2 = _clPool(usdt, usdc, 9995, 10_000);
        usdtBackup = _route(address(usdt), address(usdc), usdtUsdcPool2);
        usdcToGho = _route(address(usdc), address(gho), _clPool(usdc, gho, 1e12, 1));
        usdtToGho = _route(address(usdt), address(gho), _clPool(usdt, gho, 1e12, 1));
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(usdtPrimary), true);
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 1, address(usdtBackup), true);
        registry.setRoute(MARKET_ID, address(usdc), address(gho), 0, address(usdcToGho), true);
        registry.setRoute(MARKET_ID, address(usdt), address(gho), 0, address(usdtToGho), true);
    }

    function _clPool(
        PayoutToken a,
        PayoutToken b,
        uint256 num,
        uint256 den
    ) internal returns (MockCLPool p) {
        p = new MockCLPool(address(a), address(b));
        p.setRate(num, den);
        a.mint(address(p), 1e40);
        b.mint(address(p), 1e40);
        v3Factory.register(address(p));
    }

    function _route(
        address tokenIn,
        address tokenOut,
        MockCLPool p
    ) internal returns (DexPathRoute r) {
        DexHop[] memory hops = new DexHop[](1);
        hops[0] = DexHop({kind: HopKind.ConcentratedLiquidity, pool: address(p), tokenOut: tokenOut, i: 0, j: 0});
        r = new DexPathRoute(_routeConfig(tokenIn, tokenOut), hops);
    }

    function _routeConfig(
        address tokenIn,
        address tokenOut
    ) internal view returns (RouteConfig memory c) {
        c = RouteConfig({
            lpVaultSwap: address(lvs),
            lock: address(lock),
            aaveAdapter: address(adapter),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            tokenClassMask: 1 << 1,
            uniswapV3Factory: address(v3Factory),
            slipstreamFactory: address(slipFactory),
            curveFactory: address(curveFactory),
            curveLegacyPools: new address[](0)
        });
    }

    function _deployFlash() private {
        acl = new MockAaveV3ACLManager();
        MockAaveV3AddressesProvider provider = new MockAaveV3AddressesProvider(address(acl));
        v3Pool = new MockAaveV3Pool(address(provider), 5);
        _listOnV3(usdc, 18_000_000e6);
        _listOnV3(gho, 2_000_000e18);
        flashSource = new AaveV3FlashSource(address(v3Pool), address(lvs), address(store));
        registry.setFlashSource(address(flashSource));
    }

    function _listOnV3(
        PayoutToken token,
        uint256 idle
    ) internal {
        address aToken = v3Pool.listReserve(address(token));
        token.mint(aToken, idle);
        v3Pool.recordSupply(address(token), idle);
    }

    function _labels() private {
        vm.label(address(lvs), "LPVaultSwap");
        vm.label(address(implementation), "LPVaultSwapImpl");
        vm.label(liquidationLogic, "LPVaultSwapLiquidationLogic");
        vm.label(pendingLogic, "LPVaultSwapPendingLogic");
        vm.label(deleverageLogic, "LPVaultSwapDeleverageLogic");
        vm.label(address(adapter), "AaveAdapter(mock)");
        vm.label(address(lock), "Lock");
        vm.label(address(escrow), "PayoutEscrow");
        vm.label(address(coll), "Collateralization");
        vm.label(address(lpVault), "LPVault(mock)");
        vm.label(address(registry), "MarketRegistry(mock)");
        vm.label(address(store), "ParameterStore(mock)");
        vm.label(address(lpOracle), "LPOracle(mock)");
        vm.label(address(usdcOracle), "DebtOracle(mock)");
        vm.label(address(vt), "VaultToken");
        vm.label(address(usdc), "USDC");
        vm.label(address(usdt), "USDT");
        vm.label(address(gho), "GHO");
        vm.label(address(flashSource), "AaveV3FlashSource");
        vm.label(address(v3Pool), "AaveV3Pool");
        vm.label(address(usdtPrimary), "Route USDT>USDC primary");
        vm.label(address(usdtBackup), "Route USDT>USDC backup");
    }

    function _irData() private pure returns (bytes memory) {
        return abi.encode(CollInterestRateData(9000, 0, 400, 6000));
    }

    function _pair(
        address a,
        address b
    ) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    // ─── Second market ───

    uint256 internal constant MARKET_B = 5;
    address internal poolB = makeAddr("usdcUsdtPoolB");
    LVSLPOracleMock internal lpOracleB;
    VaultToken internal vtB;
    uint256 internal vtReserveIdB;
    uint256 internal vtAssetIdB;

    /// @notice Market 5: a second USDC/USDT range (another pool) with its own vault token, LPOracle stand-in at $2.10,
    /// Hub asset and CDP Spoke reserve, the same routes and settlement reserve (USDC). Records of both markets live in
    /// the same Collateralization and LPVault.
    function _deploySecondMarket() internal {
        uint256[] memory prices = new uint256[](2);
        prices[0] = PRICE_UNIT;
        prices[1] = P_USDT;
        lpOracleB = new LVSLPOracleMock(int256(P_VAULT), _pair(address(usdc), address(usdt)), prices);
        uint256[] memory rates = new uint256[](2);
        rates[0] = USDC_RATE;
        rates[1] = USDT_RATE;
        lpVault.bind(MARKET_B, poolB, _pair(address(usdc), address(usdt)), rates);
        vm.prank(timelock);
        vtB = VaultToken(
            factory.deployVaultToken(
                INTEGRATION,
                poolB,
                bytes32(0),
                PositionShape(ShapeKind.TickRange, -60, 60),
                aave.hub,
                aave.cdpSpoke,
                MARKET_B,
                address(lpOracleB),
                VT_DECIMALS,
                "Avana USDC/USDT B",
                "avLP-5"
            )
        );
        adapter.bindMarket(MARKET_B, address(vtB));
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        vm.startPrank(aaveDao);
        vtAssetIdB = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(
                aave.hub, address(vtB), VT_DECIMALS, aave.treasurySpoke, 0, aave.irStrategy, _irData()
            );
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(
                aave.hub,
                aave.cdpSpoke,
                vtAssetIdB,
                CollHubSpokeConfig(
                    hubView.MAX_ALLOWED_SPOKE_CAP(), 0, hubView.MAX_RISK_PREMIUM_THRESHOLD(), true, false
                )
            );
        vtReserveIdB = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.cdpSpoke,
                aave.hub,
                vtAssetIdB,
                address(lpOracleB),
                CollSpokeReserveConfig(0, false, false, false, false),
                CollSpokeDynamicReserveConfig(8000, 10_500, 0)
            );
        vm.stopPrank();
        Market memory m = registry.getMarket(MARKET_ID);
        m.pool = poolB;
        m.shape = PositionShape(ShapeKind.TickRange, -60, 60);
        m.vaultToken = address(vtB);
        m.lpOracle = address(lpOracleB);
        m.hubAssetId = vtAssetIdB;
        m.reserveId = vtReserveIdB;
        registry.setMarket(MARKET_B, m);
        registry.setSettlementReserve(MARKET_B, usdcReserveId);
        registry.setRoute(MARKET_B, address(usdt), address(usdc), 0, address(usdtPrimary), true);
        registry.setRoute(MARKET_B, address(usdt), address(usdc), 1, address(usdtBackup), true);
        registry.setRoute(MARKET_B, address(usdc), address(gho), 0, address(usdcToGho), true);
        registry.setRoute(MARKET_B, address(usdt), address(gho), 0, address(usdtToGho), true);
        store.setSlippage(MARKET_B, uint16(SLIPPAGE_BPS));
        vm.label(address(vtB), "VaultTokenB");
    }

    /// @notice Opens `wallet`'s account in market 5 at `pledgePrice8`, then sets that market's price to `P_VAULT`.
    function _openAccountB(
        address wallet,
        uint128 units,
        uint256 borrowed,
        uint256 pledgePrice8
    ) internal returns (address proxy, bytes32 key) {
        proxy = adapter.createProxy(wallet, aave.cdpSpoke, MARKET_B, vtReserveIdB);
        key = bytes32(nextKey++);
        lpVault.mintPosition(key, wallet, MARKET_B, units);
        lpOracleB.setAnswer(int256(pledgePrice8));
        adapter.pledge(proxy, wallet, key);
        if (borrowed != 0) adapter.borrow(proxy, usdcReserveId, address(usdc), borrowed, wallet);
        lpOracleB.setAnswer(int256(P_VAULT));
    }

    // ─── Accounts ───

    /// @notice Opens `wallet`'s account: a PositionProxy, a pledged position of `units` and a USDC borrow of
    /// `borrowed`, at the vault price `pledgePrice8`; the vault price is then set to `P_VAULT`.
    function _openAccount(
        address wallet,
        uint128 units,
        uint256 borrowed,
        uint256 pledgePrice8
    ) internal returns (address proxy, bytes32 key) {
        proxy = adapter.createProxy(wallet, aave.cdpSpoke, MARKET_ID, vtReserveId);
        key = bytes32(nextKey++);
        lpVault.mintPosition(key, wallet, MARKET_ID, units);
        lpOracle.setAnswer(int256(pledgePrice8));
        adapter.pledge(proxy, wallet, key);
        if (borrowed != 0) adapter.borrow(proxy, usdcReserveId, address(usdc), borrowed, wallet);
        lpOracle.setAnswer(int256(P_VAULT));
    }

    /// @notice Adds a second record of `units` to `wallet`'s existing account.
    function _addRecord(
        address proxy,
        address wallet,
        uint128 units
    ) internal returns (bytes32 key) {
        key = bytes32(nextKey++);
        lpVault.mintPosition(key, wallet, MARKET_ID, units);
        adapter.pledge(proxy, wallet, key);
    }

    /// @notice The standard unhealthy account of the examples: 10,000 vault tokens pledged at $2.50 against 18,000 USDC,
    /// HF 0.933 at $2.10 (Aave's maximum bonus 10,500 applies at HF <= 0.95).
    function _bobAccount() internal returns (address proxy, bytes32 key) {
        (proxy, key) = _openAccount(bob, 10_000e6, 18_000e6, 250_000_000);
    }

    function _hf(
        address proxy
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(proxy).healthFactor;
    }

    function _debtOf(
        address proxy,
        uint256 reserveId
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(reserveId, proxy);
    }

    function _suppliedUnits(
        address proxy
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy);
    }

    // ─── Liquidation calls ───

    function _params(
        address proxy,
        uint256 debtToCover
    ) internal view returns (LiquidationParams memory p) {
        p = LiquidationParams({
            proxy: proxy,
            marketId: MARKET_ID,
            debtReserveId: usdcReserveId,
            debtToCover: debtToCover,
            routeMode: RouteMode.PrimaryThenBackup,
            minAmounts: new uint256[](0),
            deadline: block.timestamp + 120,
            minPayout: 0,
            maxShortfall: 0
        });
    }

    /// @notice Funds `caller` with `p.debtToCover + p.maxShortfall` of the debt asset, approves LPVaultSwap and calls
    /// `liquidate` as `caller`.
    function _liquidateAs(
        address caller,
        LiquidationParams memory p
    ) internal returns (LiquidationResult memory r) {
        PayoutToken asset = p.debtReserveId == ghoReserveId ? gho : usdc;
        asset.mint(caller, p.debtToCover + p.maxShortfall);
        vm.startPrank(caller);
        asset.approve(address(lvs), p.debtToCover + p.maxShortfall);
        r = lvs.liquidate(p);
        vm.stopPrank();
    }

    function _position(
        bytes32 key
    ) internal pure returns (PositionRef memory) {
        return PositionRef(INTEGRATION, key);
    }

    /// @notice A pending-settlement balance: an earlier implementation seized `debtToCover` worth of `proxy`'s units
    /// and kept them; the next honest liquidation of the account reconciles them into Collateralization's pending
    /// balance. Returns the units LPVaultSwap holds.
    function _seizeAndKeep(
        address proxy,
        uint256 debtToCover
    ) internal returns (uint256 seized) {
        uint256 before = vt.balanceOf(address(lvs));
        usdc.mint(address(lvs), debtToCover);
        vm.startPrank(address(lvs));
        usdc.approve(aave.cdpSpoke, debtToCover);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, usdcReserveId, proxy, debtToCover, false);
        usdc.approve(aave.cdpSpoke, 0);
        vm.stopPrank();
        seized = vt.balanceOf(address(lvs)) - before;
    }

    function _grantAccessRole(
        uint64 role,
        address account
    ) internal {
        vm.prank(aaveDao);
        IAccessManager(aave.accessManager).grantRole(role, account, 0);
    }
}
