// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CoverageSpoke} from "../../../src/coverage/coverage-spoke/CoverageSpoke.sol";
import {AaveV3FlashSource} from "../../../src/flash/AaveV3FlashSource.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILens} from "../../../src/lens/lens/ILens.sol";
import {ILPVaultSwap} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {LPVaultSwap} from "../../../src/liquidation/lp-vault-swap/LPVaultSwap.sol";
import {LPVaultSwapImmutables} from "../../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {LPVaultSwapLogics} from "../../../src/liquidation/lp-vault-swap/types/LPVaultSwapLogics.sol";
import {PayoutEscrow} from "../../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {FlashLiquidator} from "../../../src/periphery/flash-liquidator/FlashLiquidator.sol";
import {AaveAdapter} from "../../../src/policy/aave-adapter/AaveAdapter.sol";
import {IAaveAdapter} from "../../../src/policy/aave-adapter/IAaveAdapter.sol";
import {AaveAdapterImmutables} from "../../../src/policy/aave-adapter/types/AaveAdapterImmutables.sol";
import {AaveAdapterLogics} from "../../../src/policy/aave-adapter/types/AaveAdapterLogics.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {RiskModule} from "../../../src/policy/risk-module/RiskModule.sol";
import {RiskModuleImmutables} from "../../../src/policy/risk-module/types/RiskModuleImmutables.sol";
import {RiskModuleLogics} from "../../../src/policy/risk-module/types/RiskModuleLogics.sol";
import {ProxyManager} from "../../../src/proxy/proxy-manager/ProxyManager.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {AdapterPlaceholder} from "../mocks/AaveAdapterMocks.sol";
import {MockAaveV3ACLManager, MockAaveV3AddressesProvider, MockAaveV3Pool} from "../mocks/AaveV3PoolMocks.sol";
import {CollPoolToken} from "../mocks/CollateralizationMocks.sol";
import {IntegLPVaultMock} from "../mocks/IntegLPVaultMock.sol";
import {IntegDebtOracleMock, IntegLPOracleMock} from "../mocks/IntegOracleMocks.sol";
import {IntegRegistryMock, IntegStoreMock} from "../mocks/IntegrationMocks.sol";
import {MockCLPool, MockPoolFactory} from "../mocks/SwapRouteMocks.sol";
import {IAvanaAaveV4Roles, ISpokeInstanceBatch} from "./AaveV4Fixture.sol";
import {
    CollHubSpokeConfig,
    CollSpokeDynamicReserveConfig,
    CollSpokeReserveConfig,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "./CollateralizationFixture.sol";
import {IntegrationMarkets} from "./IntegrationMarkets.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title IntegrationFixture
/// @notice The Avana stack deployed together on the real local Aave V4 (Stable LP Hub, Lend Spoke and one standard
/// CDP Spoke per AMM integration: "uniswap-v3-stable" and "slipstream-stable"): the AaveAdapter (router and four logic
/// contracts), LPVaultSwap (router and three logic contracts, launch keeper), the RiskModule (router and five logic
/// contracts), each behind its ERC-1967 proxy, the Lens (entry point, nine modules and Aave's sizing), the public flash
/// liquidation helper, Collateralization, Lock, VaultTokenFactory, the vault tokens, ProxyManager and PositionProxies,
/// PayoutEscrow, a Coverage Spoke per debt asset, the AaveV3FlashSource and `DexPathRoute` swap routes. Nothing
/// between the borrower's wallet and the Spoke is a stand-in.
/// @dev Stand-ins, each named: the MarketRegistry and the ParameterStore (`IntegRegistryMock`, `IntegStoreMock`: one
/// record set every reader shares), each market's LPOracle and the USDC DebtOracle (`IntegLPOracleMock`,
/// `IntegDebtOracleMock`, also the AaveOracle sources of their reserves, so Aave and Avana read one price), one LPVault
/// per AMM integration (`IntegLPVaultMock`), the pools behind the routes and the Aave V3 Pool. The reviewed
/// RiskModule runs every pledge charge and gate (Collateralization's `checkPledge`), borrow, withdrawal and health check.
/// Base markets (Uniswap v3): 4 and 5, USDC/USDT, 6-decimal vault tokens at $2.10, CF 80 %, bonus 5 % at HF <= 0.95.
/// `_addLaunchMarkets` adds WETH/USDC, WBTC/WETH and a thin MEME/WETH pool on Uniswap v3 and USDC/USDT and WETH/USDC on
/// Slipstream (pool tokens of 6, 8 and 18 decimals). Debt reserves on each CDP Spoke: GHO (18 decimals, fixed $1.00)
/// and USDC (the pools' own USDC, DebtOracle at $1.00), settlement reserve USDC. Launch values: slippage 100 bps,
/// floor rounding 1 USDC and 1 GHO, fee share 2,000 bps, `maxShortfallBps` 1,000, flash premium 5 bps.
/// Suites set `isolate = false` when a test reads state between calls of one flow.
abstract contract IntegrationFixture is IntegrationMarkets {
    uint256 internal constant T0 = 1_762_650_000;
    uint256 internal constant MARKET_B = 5;
    uint256 internal constant USDC_RATE = 1_056_615;
    uint256 internal constant USDT_RATE = 1_036_000;
    uint256 internal constant P_USDT = 99_950_000;
    uint256 internal constant P_VAULT = 210_000_000;
    uint256 internal constant DEADLINE_SLACK = 600;
    uint256 internal constant ETH_USDC = 6;
    uint256 internal constant WBTC_ETH = 7;
    uint256 internal constant MEME_ETH = 8;
    uint256 internal constant SLIP_USDC_USDT = 9;
    uint256 internal constant SLIP_ETH_USDC = 10;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    IAaveAdapter internal adapterC;
    ILPVaultSwap internal lvs;
    RiskModule internal rm;
    ILens internal lens;
    FlashLiquidator internal helper;
    ProxyManager internal proxyManager;
    PayoutEscrow internal escrow;
    IntegLPOracleMock internal lpo;
    IntegLPOracleMock internal lpoB;
    IntegLPVaultMock internal vault;
    IntegLPVaultMock internal vaultSlip;
    CoverageSpoke internal usdcCoverage;
    CoverageSpoke internal ghoCoverage;
    MockAaveV3Pool internal v3Pool;
    AaveV3FlashSource internal flashSource;
    MockCLPool internal usdtUsdcPool;
    MockCLPool internal usdtUsdcPool2;
    CollPoolToken internal weth;
    CollPoolToken internal wbtc;
    CollPoolToken internal meme;
    IntegDebtOracleMock internal wethOracle;
    CoverageSpoke internal wethCoverage;
    uint256 internal wethAssetId;
    uint256 internal wethReserveId;
    address internal feedWethDebt = makeAddr("feed WETH/USD debt");

    VaultToken internal tokenB;
    address internal vtB;
    address internal poolB = makeAddr("usdcUsdtPoolB");
    uint256 internal vtReserveIdB;
    uint256 internal usdcReserveId;
    address internal feedUsdc;
    address internal feedUsdt;
    address internal feedUsdcDebt = makeAddr("feed USDC/USD debt");
    uint256 internal keyNonce;

    function _deployIntegration() internal {
        vm.warp(T0);
        vm.roll(1000);
        reg = new IntegRegistryMock();
        store = new IntegStoreMock();
        marketRegistry = address(reg);
        // The two Lock members first, so every immutable contract is built with their final addresses.
        adapter = address(new ERC1967Proxy(address(new AdapterPlaceholder()), ""));
        lpVaultSwap = address(new ERC1967Proxy(address(new AdapterPlaceholder()), ""));
        _deployCollateralization();
        address fresh = deployCode(
            "IntegLPVaultMock.sol:IntegLPVaultMock",
            abi.encode(INTEGRATION, address(coll), address(lock), keccak256("UNISWAP_V3"))
        );
        vm.etch(address(lpVault), fresh.code);
        vault = IntegLPVaultMock(address(lpVault));
        vault.setDepth(1e30, true);
        escrow = PayoutEscrow(deployCode("PayoutEscrow.sol:PayoutEscrow", abi.encode(lpVaultSwap, address(lock))));
        proxyManager = ProxyManager(deployCode("ProxyManager.sol:ProxyManager", abi.encode(adapter, address(reg))));
        v3Factory = new MockPoolFactory();
        ghoAssetId = IAaveV4Hub(aave.hub).getAssetId(address(debt));
        usdcOracle = new IntegDebtOracleMock(address(usdc), address(reg), address(store), feedUsdcDebt, 1e8);
        store.setBorrowAge(feedUsdcDebt, FEED_AGE);
        store.setDepositorCap(aave.hub, 1e30);
        _listUsdcAsset();
        _deployCoverage();
        _registerToken(address(usdc), "USDC", PRICE_UNIT);
        _registerToken(address(usdt), "USDT", P_USDT);
        tokenPrice8[address(debt)] = PRICE_UNIT;
        (feedUsdc, feedUsdt) = (tokenFeed[address(usdc)], tokenFeed[address(usdt)]);
        _recordCdpSpoke(
            UNISWAP_V3,
            aave.cdpSpoke,
            aave.cdpSpokeImplementation,
            aave.cdpOracle,
            vault,
            debtReserveId,
            type(uint256).max
        );
        usdcReserveId = cdp[UNISWAP_V3].usdcReserveId;
        _deploySlipstreamSpoke();
        _listBaseMarkets();
        _deployRiskModule();
        _deployAdapter();
        _deployLPVaultSwap();
        _deployFlash();
        _deployLens();
        reg.setRecordedHub(aave.hub, true);
        reg.setPayoutEscrow(address(escrow));
        reg.setFlashSource(address(flashSource));
        reg.setCoverageSpoke(aave.hub, address(usdc), address(usdcCoverage));
        reg.setCoverageSpoke(aave.hub, address(debt), address(ghoCoverage));
        store.setFloorRoundingAllowance(address(usdc), FLOOR_ROUNDING_ALLOWANCE_USDC);
        store.setFloorRoundingAllowance(address(debt), FLOOR_ROUNDING_ALLOWANCE_GHO);
        store.setFeeRecipient(feeRecipient);
        _labelIntegration();
    }

    // ─── Markets ───

    function _listBaseMarkets() private {
        _adoptMarket(_usdcUsdtConfig(MARKET_ID, UNISWAP_V3, pool, -50), vt, vtReserveId);
        MarketInfo memory b = _addMarket(_usdcUsdtConfig(MARKET_B, UNISWAP_V3, poolB, -60));
        (vtB, vtReserveIdB, tokenB) = (b.vaultToken, b.reserveId, VaultToken(b.vaultToken));
        (lpo, lpoB) = (markets[MARKET_ID].oracle, b.oracle);
        usdtUsdcPool = routePools[address(usdt)][address(usdc)][0];
        usdtUsdcPool2 = routePools[address(usdt)][address(usdc)][1];
    }

    /// @notice A USDC/USDT stable market: 6-decimal vault token at $2.10, each unit unwinding into `USDC_RATE` USDC and
    /// `USDT_RATE` USDT per 1e6 units, CF 80 %, bonus 5 %.
    function _usdcUsdtConfig(
        uint256 marketId,
        uint32 integrationId,
        address pool_,
        int24 lower
    ) internal view returns (MarketConfig memory c) {
        c.marketId = marketId;
        c.integrationId = integrationId;
        c.symbol = string.concat("USDC-USDT-", vm.toString(marketId));
        c.pool = pool_;
        c.tokens = _pair(address(usdc), address(usdt));
        c.rates = _two(USDC_RATE * 1e12, USDT_RATE * 1e12);
        c.vtDecimals = VT_DECIMALS;
        c.vaultPrice8 = P_VAULT;
        (c.collateralFactor, c.maxLiquidationBonus, c.tickLower, c.tickUpper, c.addCap) =
        (8000, 10_500, lower, -lower, 5_500_000);
    }

    /// @notice A volatile market of 18-decimal vault tokens worth the unwind composition at the token prices.
    function _volatileConfig(
        uint256 marketId,
        uint32 integrationId,
        address[] memory tokens,
        uint256[] memory rates,
        uint16 cf
    ) internal returns (MarketConfig memory c) {
        c.marketId = marketId;
        c.integrationId = integrationId;
        c.symbol = string.concat("M", vm.toString(marketId));
        c.pool = makeAddr(string.concat("pool ", c.symbol));
        (c.tokens, c.rates, c.vtDecimals) = (tokens, rates, 18);
        (c.collateralFactor, c.maxLiquidationBonus, c.tickLower, c.tickUpper, c.addCap) =
        (cf, 10_500, -600, 600, 5_000_000);
    }

    /// @notice The multi-AMM launch set: on Uniswap v3 WETH/USDC (18/6), WBTC/WETH (8/18) and a thin MEME/WETH pool
    /// (18/18, its own depth of 1,000,000 vault tokens), on Slipstream USDC/USDT and WETH/USDC. Per whole vault token:
    /// 1 WETH + 3,000 USDC ($6,000), 0.05 WBTC + 1 WETH ($6,000), 1,000 MEME + 0.1 WETH ($600).
    function _addLaunchMarkets() internal {
        weth = _newToken("WETH", 18, 3000e8);
        wbtc = _newToken("WBTC", 8, 60_000e8);
        meme = _newToken("MEME", 18, 30_000_000);
        _addMarket(_volatileConfig(ETH_USDC, UNISWAP_V3, _pair(address(weth), address(usdc)), _two(1e18, 3e9), 7000));
        _addMarket(_volatileConfig(WBTC_ETH, UNISWAP_V3, _pair(address(wbtc), address(weth)), _two(5e6, 1e18), 7000));
        _addMarket(_volatileConfig(MEME_ETH, UNISWAP_V3, _pair(address(meme), address(weth)), _two(1e21, 1e17), 4000));
        vault.setMarketDepth(MEME_ETH, 1e24);
        _addMarket(_usdcUsdtConfig(SLIP_USDC_USDT, SLIPSTREAM, makeAddr("slipstream USDC/USDT"), -10));
        _addMarket(
            _volatileConfig(SLIP_ETH_USDC, SLIPSTREAM, _pair(address(weth), address(usdc)), _two(1e18, 3e9), 7000)
        );
    }

    // ─── Aave listing beyond CollateralizationFixture ───

    /// @dev The pools' USDC as a Hub asset with a 10,000,000 USDC line through the Lend Spoke.
    function _listUsdcAsset() private {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        vm.startPrank(aaveDao);
        usdcAssetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, address(usdc), 6, aave.treasurySpoke, 0, aave.irStrategy, _ir());
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, aave.lendSpoke, usdcAssetId, CollHubSpokeConfig(maxCap, 0, maxRp, true, false));
        uint256 lendReserve = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.lendSpoke,
                aave.hub,
                usdcAssetId,
                address(usdcOracle),
                CollSpokeReserveConfig(0, false, false, true, false),
                CollSpokeDynamicReserveConfig(0, 10_000, 0)
            );
        vm.stopPrank();
        usdc.mint(daoTreasury, 10_000_000e6);
        vm.startPrank(daoTreasury);
        usdc.approve(aave.lendSpoke, 10_000_000e6);
        IAaveV4Spoke(aave.lendSpoke).supply(lendReserve, 10_000_000e6, daoTreasury);
        vm.stopPrank();
    }

    /// @dev A further standard CDP Spoke ("slipstream-stable") with its own AaveOracle, deployed by Aave's Spoke batch
    /// and set up by Aave's role procedure exactly as `_deployAaveV4` sets up the first: the fixture holds the
    /// AccessManager admin role only while the procedure runs, granted and taken back by the Aave DAO.
    function _deployExtraCdpSpoke(
        string memory label
    ) private returns (address spoke, address impl, address oracle) {
        address batch = deployCode(
            "out-aave/AaveV4SpokeInstanceBatch.sol/AaveV4SpokeInstanceBatch.json",
            abi.encode(
                aaveDao,
                aave.accessManager,
                _linkedSpokeInstanceCode(aave.liquidationLogic),
                ORACLE_DECIMALS,
                CDP_SPOKE_USER_RESERVES_LIMIT,
                _childSalt(aave.salt, "spoke", label)
            )
        );
        (spoke, impl, oracle) = ISpokeInstanceBatch(batch).getReport();
        vm.prank(aaveDao);
        IAccessManager(aave.accessManager).grantRole(0, address(this), 0);
        (bool ok, bytes memory data) =
            aave.roles.delegatecall(abi.encodeCall(IAvanaAaveV4Roles.setupSpoke, (aave.accessManager, spoke)));
        _bubble(ok, data);
        IAccessManager(aave.accessManager).renounceRole(0, address(this));
    }

    /// @dev The Slipstream integration's LPVault, registered in the VaultTokenFactory, and its CDP Spoke.
    function _deploySlipstreamSpoke() private {
        (address slipSpoke, address slipImpl, address slipOracle) = _deployExtraCdpSpoke("slipstream-stable");
        vaultSlip = IntegLPVaultMock(
            deployCode(
                "IntegLPVaultMock.sol:IntegLPVaultMock",
                abi.encode(SLIPSTREAM, address(coll), address(lock), keccak256("SLIPSTREAM"))
            )
        );
        vaultSlip.setCore(timelock, address(reg));
        vaultSlip.setDepth(1e30, true);
        vm.prank(timelock);
        factory.registerIntegration(SLIPSTREAM, address(vaultSlip));
        _recordCdpSpoke(SLIPSTREAM, slipSpoke, slipImpl, slipOracle, vaultSlip, type(uint256).max, type(uint256).max);
        vm.label(slipSpoke, "Aave.Spoke.SlipstreamStable");
        vm.label(address(vaultSlip), "LPVault(slipstream stand-in)");
    }

    /// @notice WETH as a non-GHO debt reserve of the Uniswap v3 CDP Spoke: a Hub asset with a 10,000 WETH line
    /// through the Lend Spoke, the CDP reserve (draw cap 5,000 WETH) priced by a WETH DebtOracle (`IntegDebtOracleMock`
    /// at $3,000, also its AaveOracle source), its record in the MarketRegistry, its own Coverage Spoke, a 0.0005 WETH
    /// floor rounding allowance, primary and backup routes from USDC and USDT into WETH for the base markets at the
    /// oracle rate, and 2,000 WETH idle on the Aave V3 Pool for the flash liquidation helper. Suites call it after
    /// `_deployIntegration`; WETH is the launch markets' token when `_addLaunchMarkets` ran first.
    function _addWethDebtReserve() internal {
        if (address(weth) == address(0)) weth = _newToken("WETH", 18, 3000e8);
        wethOracle = new IntegDebtOracleMock(address(weth), address(reg), address(store), feedWethDebt, 3000e8);
        store.setBorrowAge(feedWethDebt, FEED_AGE);
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        vm.startPrank(aaveDao);
        wethAssetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, address(weth), 18, aave.treasurySpoke, 0, aave.irStrategy, _ir());
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, aave.lendSpoke, wethAssetId, CollHubSpokeConfig(maxCap, 0, maxRp, true, false));
        uint256 lendReserve = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.lendSpoke,
                aave.hub,
                wethAssetId,
                address(wethOracle),
                CollSpokeReserveConfig(0, false, false, true, false),
                CollSpokeDynamicReserveConfig(0, 10_000, 0)
            );
        wethReserveId = _listDebt(aave.cdpSpoke, wethAssetId, address(wethOracle), 5000);
        vm.stopPrank();
        weth.mint(daoTreasury, 10_000e18);
        vm.startPrank(daoTreasury);
        weth.approve(aave.lendSpoke, 10_000e18);
        IAaveV4Spoke(aave.lendSpoke).supply(lendReserve, 10_000e18, daoTreasury);
        vm.stopPrank();
        wethCoverage = _coverageSpoke(address(weth), wethAssetId);
        reg.setCoverageSpoke(aave.hub, address(weth), address(wethCoverage));
        reg.setDebtReserve(
            aave.cdpSpoke,
            wethReserveId,
            DebtReserveDef({
                reserveId: wethReserveId,
                asset: address(weth),
                decimals: 18,
                fundingHub: aave.hub,
                hubAssetId: wethAssetId,
                priceSource: address(wethOracle),
                fixedPrice: false,
                coverageSpoke: address(wethCoverage),
                crossHub: false,
                approved: true
            })
        );
        store.setFloorRoundingAllowance(address(weth), 0.0005e18);
        uint256[2] memory ids = [MARKET_ID, MARKET_B];
        address[2] memory tokens = [address(usdc), address(usdt)];
        for (uint256 i = 0; i < 2; ++i) {
            for (uint256 j = 0; j < 2; ++j) {
                address[2] memory r = _routes(tokens[j], address(weth));
                reg.setRoute(ids[i], tokens[j], address(weth), 0, r[0], true);
                reg.setRoute(ids[i], tokens[j], address(weth), 1, r[1], true);
            }
        }
        _listOnV3(weth, 2000e18);
        vm.label(address(wethOracle), "DebtOracleWETH(stand-in)");
        vm.label(address(wethCoverage), "WethCoverageSpoke");
    }

    function _deployCoverage() private {
        usdcCoverage = _coverageSpoke(address(usdc), usdcAssetId);
        ghoCoverage = _coverageSpoke(address(debt), ghoAssetId);
        (usdcCoverageAddr, ghoCoverageAddr) = (address(usdcCoverage), address(ghoCoverage));
    }

    function _coverageSpoke(
        address asset,
        uint256 assetId
    ) private returns (CoverageSpoke cs) {
        cs = CoverageSpoke(
            deployCode(
                "CoverageSpoke.sol:CoverageSpoke", abi.encode(aave.hub, asset, assetId, aave.accessManager, 1_209_600)
            )
        );
        uint24 maxRp = IAaveV4Hub(aave.hub).MAX_RISK_PREMIUM_THRESHOLD();
        vm.prank(aaveDao);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, address(cs), assetId, CollHubSpokeConfig(1_000_000, 0, maxRp, true, false));
        _grantDeficitEliminator(address(cs));
    }

    // ─── Avana contracts ───

    function _deployRiskModule() private {
        RiskModuleImmutables memory im = RiskModuleImmutables({
            marketRegistry: address(reg),
            parameterStore: address(store),
            collateralization: address(coll),
            adapter: adapter,
            lpVaultSwap: lpVaultSwap,
            timelock: timelock
        });
        RiskModuleLogics memory l;
        l.drift = deployCode("RiskModuleDriftLogic.sol:RiskModuleDriftLogic", abi.encode(im));
        l.breaker = deployCode("RiskModuleBreakerLogic.sol:RiskModuleBreakerLogic", abi.encode(im, l.drift));
        l.pledge = deployCode("RiskModulePledgeLogic.sol:RiskModulePledgeLogic", abi.encode(im, l.drift, l.breaker));
        l.borrow = deployCode("RiskModuleBorrowLogic.sol:RiskModuleBorrowLogic", abi.encode(im, l.drift, l.breaker));
        l.status =
            deployCode("RiskModuleStatusLogic.sol:RiskModuleStatusLogic", abi.encode(im, l.drift, l.breaker, l.borrow));
        l.speed = deployCode("RiskModuleSpeedLogic.sol:RiskModuleSpeedLogic", abi.encode(im));
        address impl = deployCode("RiskModule.sol:RiskModule", abi.encode(im, l));
        // Collateralization was built before the RiskModule with its `RISK_MODULE` immutable at the base fixture's
        // address; the reviewed RiskModule's ERC-1967 proxy is placed there (its storage is ERC-7201 namespaced, so the
        // address's earlier slots are never read), so pledge checks run in the same RiskModule as borrows.
        address at = address(riskModule);
        vm.etch(at, address(new ERC1967Proxy(impl, "")).code);
        vm.store(at, ERC1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(impl))));
        rm = RiskModule(at);
        rm.initialize(timelock);
    }

    function _deployAdapter() private {
        AaveAdapterImmutables memory im = AaveAdapterImmutables({
            proxyManager: address(proxyManager),
            collateralization: address(coll),
            riskModule: address(rm),
            marketRegistry: address(reg),
            parameterStore: address(store),
            lpVaultSwap: lpVaultSwap,
            lock: address(lock),
            vaultTokenFactory: address(factory),
            timelock: timelock
        });
        AaveAdapterLogics memory logics = AaveAdapterLogics({
            user: deployCode("AaveAdapterUserLogic.sol:AaveAdapterUserLogic", abi.encode(im)),
            exit: deployCode("AaveAdapterExitLogic.sol:AaveAdapterExitLogic", abi.encode(im)),
            collateral: deployCode("AaveAdapterCollateralLogic.sol:AaveAdapterCollateralLogic", abi.encode(im)),
            settlement: deployCode("AaveAdapterSettlementLogic.sol:AaveAdapterSettlementLogic", abi.encode(im))
        });
        address impl = deployCode("AaveAdapter.sol:AaveAdapter", abi.encode(im, logics));
        AdapterPlaceholder(adapter).upgradeToAndCall(impl, abi.encodeCall(AaveAdapter.initialize, (timelock)));
        adapterC = IAaveAdapter(adapter);
    }

    function _deployLPVaultSwap() private {
        LPVaultSwapImmutables memory im = LPVaultSwapImmutables({
            lock: address(lock),
            aaveAdapter: adapter,
            collateralization: address(coll),
            marketRegistry: address(reg),
            parameterStore: address(store),
            payoutEscrow: address(escrow),
            keeperFloor: KEEPER_FLOOR
        });
        LPVaultSwapLogics memory l = LPVaultSwapLogics(
            deployCode("LPVaultSwapLiquidationLogic.sol:LPVaultSwapLiquidationLogic", abi.encode(im)),
            deployCode("LPVaultSwapPendingLogic.sol:LPVaultSwapPendingLogic", abi.encode(im)),
            deployCode("LPVaultSwapDeleverageLogic.sol:LPVaultSwapDeleverageLogic", abi.encode(im))
        );
        address impl = deployCode("LPVaultSwap.sol:LPVaultSwap", abi.encode(im, l));
        address[] memory keepers = new address[](1);
        keepers[0] = keeper;
        AdapterPlaceholder(lpVaultSwap)
            .upgradeToAndCall(impl, abi.encodeCall(LPVaultSwap.initialize, (timelock, keepers)));
        lvs = ILPVaultSwap(lpVaultSwap);
    }

    /// @dev The Aave V3 Pool (5 bps premium) behind the core flash source and the public flash liquidation helper.
    function _deployFlash() private {
        MockAaveV3ACLManager acl = new MockAaveV3ACLManager();
        v3Pool = new MockAaveV3Pool(address(new MockAaveV3AddressesProvider(address(acl))), 5);
        _listOnV3(usdc, 18_000_000e6);
        _listOnV3(debt, 2_000_000e18);
        flashSource = AaveV3FlashSource(
            deployCode(
                "AaveV3FlashSource.sol:AaveV3FlashSource", abi.encode(address(v3Pool), lpVaultSwap, address(store))
            )
        );
        helper = FlashLiquidator(
            deployCode(
                "FlashLiquidator.sol:FlashLiquidator",
                abi.encode(address(v3Pool), lpVaultSwap, address(reg), address(store))
            )
        );
    }

    function _listOnV3(
        CollPoolToken token,
        uint256 idle
    ) private {
        address aToken = v3Pool.listReserve(address(token));
        token.mint(aToken, idle);
        v3Pool.recordSupply(address(token), idle);
    }

    function _deployLens() private {
        address[9] memory core = [
            address(coll),
            address(proxyManager),
            adapter,
            address(lock),
            address(reg),
            address(store),
            address(rm),
            lpVaultSwap,
            address(escrow)
        ];
        address sizing = deployCode("out-aave/LensAaveSizing.sol/LensAaveSizing.json");
        address[9] memory m;
        m[0] = deployCode("LensAccountModule.sol:LensAccountModule", abi.encode(core));
        m[1] = deployCode("LensMarketModule.sol:LensMarketModule", abi.encode(core));
        m[2] = deployCode("LensPriceModule.sol:LensPriceModule", abi.encode(core));
        m[3] = deployCode("LensLiquidationModule.sol:LensLiquidationModule", abi.encode(core, sizing));
        m[4] = deployCode("LensRiskModule.sol:LensRiskModule", abi.encode(core));
        m[5] = deployCode("LensPreviewModule.sol:LensPreviewModule", abi.encode(core));
        m[6] = deployCode("LensMarketsModule.sol:LensMarketsModule", abi.encode(core));
        m[7] = deployCode("LensPositionsModule.sol:LensPositionsModule", abi.encode(core));
        m[8] = deployCode("LensSpeedModule.sol:LensSpeedModule", abi.encode(core));
        lens = ILens(deployCode("Lens.sol:Lens", abi.encode(m)));
    }

    function _labelIntegration() private {
        vm.label(adapter, "AaveAdapter");
        vm.label(lpVaultSwap, "LPVaultSwap");
        vm.label(address(rm), "RiskModule");
        vm.label(address(lens), "Lens");
        vm.label(address(helper), "FlashLiquidator");
        vm.label(address(proxyManager), "ProxyManager");
        vm.label(address(escrow), "PayoutEscrow");
        vm.label(address(reg), "MarketRegistry(stand-in)");
        vm.label(address(store), "ParameterStore(stand-in)");
        vm.label(address(usdcOracle), "DebtOracleUSDC(stand-in)");
        vm.label(address(vault), "LPVault(uniswap-v3 stand-in)");
        vm.label(address(flashSource), "AaveV3FlashSource");
        vm.label(address(v3Pool), "AaveV3Pool(mock)");
        vm.label(address(usdcCoverage), "UsdcCoverageSpoke");
        vm.label(address(ghoCoverage), "GhoCoverageSpoke");
    }
}
