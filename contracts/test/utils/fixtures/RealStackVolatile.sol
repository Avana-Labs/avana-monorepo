// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IClIntegration} from "../../../src/amm/IClIntegration.sol";
import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ClUnitMath} from "../../../src/amm/concentrated-liquidity/ClUnitMath.sol";
import {AvanaFirstLossReserve} from "../../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {INonfungiblePositionManager} from "../../../src/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {LiquidationParams} from "../../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {ILPOracle} from "../../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleCL} from "../../../src/oracle/lp-oracle/LPOracleCL.sol";
import {InitParams} from "../../../src/oracle/lp-oracle/types/InitParams.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {RiskTier} from "../../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../../src/policy/market-registry/types/SpokeDef.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/MarketParams.sol";
import {MarketSpeedLimits} from "../../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../../src/policy/parameter-store/types/SpeedLimit.sol";
import {MarketDef} from "../../../src/types/MarketDef.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {OracleFeedMock} from "../mocks/LPOracleMocks.sol";
import {IAvanaAaveV4Roles, IHubInstanceBatch, ISpokeInstanceBatch} from "./AaveV4Fixture.sol";
import {ClTestToken, IClPool} from "./ClPoolFixture.sol";
import {
    CollHubSpokeConfig,
    CollPriceSource,
    CollSpokeDynamicReserveConfig,
    CollSpokeLiquidationConfig,
    CollSpokeReserveConfig,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "./CollateralizationFixture.sol";
import {LPOracleCLDeployer} from "./LPOracleCLFixture.sol";
import {RealStackFlows} from "./RealStackFlows.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title RealStackVolatile
/// @notice `RealStackFlows` with a Volatile LP Hub: volatile Uniswap v3 markets need their own Hub and CDP Spoke, since
/// the MarketRegistry admits only USD-stable pool tokens on a Stable-tier Hub. Built as the Aave and Avana payloads do
/// it: a second Aave V4 Hub ("volatile-lp") and CDP Spoke ("uniswap-v3-volatile", with its own AaveOracle) from Aave's
/// instance batches and role procedure; the Hub recorded with tier Volatile, the Spoke's implementation hash approved and
/// the Spoke recorded for the Uniswap v3 integration through the real MarketRegistry; USDC (its DebtOracle) and GHO
/// (fixed $1.00) as Hub assets lent through the Lend Spoke, each with a real First-Loss Reserve and credit line on the
/// new Hub and enabled as debt reserves of the new Spoke. Volatile tokens are listed with feeds (`_listPricedToken`, not
/// USD-stable) and token collateral factors; markets (`_addVolatileMarket`) are the full range of real Uniswap v3 pools
/// created at the feed prices, priced by real `LPOracleCL`s with the pool's unit exponent, their vault-token decimals
/// those the real LPVault's `bindMarket` computes (`ClUnitMath`), with real routes from each pool token into USDC and
/// GHO at the feed rate.
/// @dev `_repriceMarkets` swaps every market pool to its tokens' published prices and waits the TWAP window, as
/// `_depegUsdt` does for USDT. Spoke-aware reads (`_hfOn`, `_debtOn`, `_sharesOn`) and a liquidation helper that funds
/// the caller in the reserve's asset of any Spoke (`_liquidateOn`) complement the fixture's Stable-Spoke ones.
abstract contract RealStackVolatile is RealStackFlows {
    string internal constant HUB_VOLATILE_LP = "volatile-lp";
    string internal constant SPOKE_CDP_UNISWAP_V3_VOLATILE = "uniswap-v3-volatile";
    uint16 internal constant POOL_RISK_FACTOR = 4000;

    /// @notice Where a concentrated-liquidity market is listed: its AMM integration and LPVault, its Hub, CDP Spoke and
    /// the Hub's interest-rate strategy, the `slot0` layout of its pools (7 Uniswap v3, 6 Slipstream) and, for
    /// Slipstream, the pool's generation (`bindMarket`'s `integrationData` names it).
    struct ClSite {
        uint32 integrationId;
        address lpVault;
        address hub;
        address spoke;
        address ir;
        uint8 slot0Words;
        uint8 generation;
    }

    /// @dev A vault token's name, symbol and shape (one stack slot for `_volatileVaultToken`).
    struct VtMeta {
        string name;
        string symbol;
        PositionShape shape;
    }

    address internal hubV;
    address internal irV;
    address internal spokeV;
    address internal spokeVImpl;
    address internal spokeVOracle;
    uint256 internal usdcAssetIdV;
    uint256 internal usdcReserveIdV;
    uint256 internal ghoAssetIdV;
    uint256 internal ghoReserveIdV;
    /// @dev Per debt asset, its First-Loss Reserve on the Volatile Hub.
    mapping(address asset => address reserve) internal firstLossReserveOfV;
    ClTestToken internal wbtc;
    ClTestToken internal meme;

    // ─── The Volatile Hub and Spoke ───

    /// @notice The Volatile LP Hub and its Uniswap v3 CDP Spoke with USDC and GHO debt reserves; WETH, WBTC and MEME
    /// listed at $3,000, $60,000 and $0.30 with token collateral factors 8,000, 7,500 and 5,000.
    function _setUpVolatile() internal {
        _deployVolatileAave();
        _recordVolatileSpoke();
        (usdcAssetIdV, usdcReserveIdV) = _volatileDebt(usdc, 6, address(usdcOracle), false);
        (ghoAssetIdV, ghoReserveIdV) = _volatileDebt(gho, 18, address(ghoPrice), true);
        if (address(weth) == address(0)) {
            weth = new ClTestToken("WETH", 18);
            vm.label(address(weth), "WETH");
        }
        wbtc = new ClTestToken("WBTC", 8);
        vm.label(address(wbtc), "WBTC");
        meme = new ClTestToken("MEME", 18);
        vm.label(address(meme), "MEME");
        if (address(feedsOf[address(weth)][0]) == address(0)) _listPricedToken(weth, "WETH", WETH_PRICE, false);
        _listPricedToken(wbtc, "WBTC", 60_000e8, false);
        _listPricedToken(meme, "MEME", 30_000_000, false);
        vm.startPrank(address(timelock));
        store.setTokenCollateralFactorBps(address(weth), 8000);
        store.setTokenCollateralFactorBps(address(wbtc), 7500);
        store.setTokenCollateralFactorBps(address(meme), 5000);
        address[4] memory toks = [address(usdc), address(weth), address(wbtc), address(meme)];
        for (uint256 i = 0; i < 4; ++i) {
            store.setInitialTokenCap(hubV, toks[i], 10_000_000e8);
        }
        vm.stopPrank();
    }

    /// @dev Aave's batches and role procedure for the Hub and the Spoke, with the fixture holding the AccessManager
    /// admin role only while the procedure runs (granted and taken back by the Aave DAO).
    function _deployVolatileAave() private {
        address hubBatch = deployCode(
            "out-aave/AaveV4HubInstanceBatch.sol/AaveV4HubInstanceBatch.json",
            abi.encode(
                aaveDao,
                aave.accessManager,
                vm.getCode("out-aave/HubInstance.sol/HubInstance.json"),
                _childSalt(aave.salt, "hub", HUB_VOLATILE_LP)
            )
        );
        (hubV,, irV) = IHubInstanceBatch(hubBatch).getReport();
        address spokeBatch = deployCode(
            "out-aave/AaveV4SpokeInstanceBatch.sol/AaveV4SpokeInstanceBatch.json",
            abi.encode(
                aaveDao,
                aave.accessManager,
                _linkedSpokeInstanceCode(aave.liquidationLogic),
                ORACLE_DECIMALS,
                CDP_SPOKE_USER_RESERVES_LIMIT,
                _childSalt(aave.salt, "spoke", SPOKE_CDP_UNISWAP_V3_VOLATILE)
            )
        );
        (spokeV, spokeVImpl, spokeVOracle) = ISpokeInstanceBatch(spokeBatch).getReport();
        vm.prank(aaveDao);
        IAccessManager(aave.accessManager).grantRole(0, address(this), 0);
        _aaveRoles(abi.encodeCall(IAvanaAaveV4Roles.setupHub, (aave.accessManager, hubV)));
        _aaveRoles(abi.encodeCall(IAvanaAaveV4Roles.setupSpoke, (aave.accessManager, spokeV)));
        IAccessManager(aave.accessManager).renounceRole(0, address(this));
        vm.label(hubV, "Aave.Hub.VolatileLP");
        vm.label(spokeV, "Aave.Spoke.UniswapV3Volatile");
    }

    function _aaveRoles(
        bytes memory call
    ) private {
        (bool ok, bytes memory data) = aave.roles.delegatecall(call);
        _bubble(ok, data);
    }

    /// @dev The Hub recorded as Volatile, the Spoke's implementation hash approved and the Spoke recorded, its
    /// liquidation expectations and the Hub's depositor cap, then the Aave DAO's liquidation configuration.
    function _recordVolatileSpoke() private {
        vm.startPrank(address(timelock));
        registry.recordHub(hubV, RiskTier.Volatile);
        registry.approveSpokeCodeHash(spokeVImpl.codehash);
        registry.deployCdpSpoke(
            SpokeDef({
                approved: false,
                hub: hubV,
                integrationId: V3,
                riskTier: RiskTier.Volatile,
                implementation: spokeVImpl,
                aaveOracle: spokeVOracle
            })
        );
        store.setLiquidationExpectations(spokeV, TARGET_HEALTH_FACTOR, 200);
        store.setInitialHubCaps(hubV, DEPOSITOR_CAP);
        vm.stopPrank();
        vm.prank(aaveDao);
        ICollSpokeConfigurator(aave.spokeConfigurator)
            .updateLiquidationConfig(spokeV, CollSpokeLiquidationConfig(1.1e18, 0.95e18, 5000));
    }

    /// @dev `asset` on the Volatile Hub lent through the Lend Spoke (1,000,000 whole tokens), its borrowable reserve on
    /// the Volatile Spoke priced by `source`, a real First-Loss Reserve (100,000 whole tokens) and credit line on the
    /// Hub, and the reserve enabled in the MarketRegistry with the asset's launch speed limit on the Hub.
    function _volatileDebt(
        ClTestToken asset,
        uint8 dec,
        address source,
        bool fixedPrice
    ) private returns (uint256 assetId, uint256 reserveId) {
        (assetId, reserveId) = _volatileAaveDebt(asset, dec, source);
        uint256 whole = 10 ** dec;
        address cs = _volatileFirstLoss(asset, assetId, whole);
        _enableVolatileDebt(
            DebtReserveDef({
                reserveId: reserveId,
                asset: address(asset),
                decimals: dec,
                fundingHub: hubV,
                hubAssetId: assetId,
                priceSource: source,
                fixedPrice: fixedPrice,
                firstLossReserve: cs,
                crossHub: false,
                approved: false
            })
        );
    }

    function _enableVolatileDebt(
        DebtReserveDef memory def
    ) private {
        vm.startPrank(address(timelock));
        registry.enableDebtReserve(spokeV, def);
        uint96 unit = uint96(10 ** def.decimals);
        store.loosenDebtSpeedLimit(hubV, def.asset, SpeedLimit(2500, 21_600, 500_000 * unit, 5_000_000 * unit));
        vm.stopPrank();
    }

    /// @dev The Aave DAO's payload for `asset` on the Volatile Hub and Spoke, and the Lend Spoke's supply.
    function _volatileAaveDebt(
        ClTestToken asset,
        uint8 dec,
        address source
    ) private returns (uint256 assetId, uint256 reserveId) {
        uint24 maxRp = IAaveV4Hub(hubV).MAX_RISK_PREMIUM_THRESHOLD();
        uint40 maxCap = IAaveV4Hub(hubV).MAX_ALLOWED_SPOKE_CAP();
        ICollHubConfigurator hubCfg = ICollHubConfigurator(aave.hubConfigurator);
        ICollSpokeConfigurator spokeCfg = ICollSpokeConfigurator(aave.spokeConfigurator);
        vm.startPrank(aaveDao);
        assetId = hubCfg.addAssetWithDecimals(hubV, address(asset), dec, aave.treasurySpoke, 0, irV, _irData());
        hubCfg.addSpoke(hubV, aave.lendSpoke, assetId, CollHubSpokeConfig(maxCap, 0, maxRp, true, false));
        hubCfg.addSpoke(hubV, spokeV, assetId, CollHubSpokeConfig(0, DEBT_DRAW_CAP, maxRp, true, false));
        uint256 lendReserve = spokeCfg.addReserve(
            aave.lendSpoke,
            hubV,
            assetId,
            address(new CollPriceSource(1e8)),
            CollSpokeReserveConfig(0, false, false, true, false),
            CollSpokeDynamicReserveConfig(0, 10_000, 0)
        );
        reserveId = spokeCfg.addReserve(
            spokeV,
            hubV,
            assetId,
            source,
            CollSpokeReserveConfig(0, false, false, true, false),
            CollSpokeDynamicReserveConfig(0, 10_000, 0)
        );
        vm.stopPrank();
        uint256 whole = 10 ** dec;
        asset.mint(daoTreasury, 1_000_000 * whole);
        vm.startPrank(daoTreasury);
        asset.approve(aave.lendSpoke, 1_000_000 * whole);
        IAaveV4Spoke(aave.lendSpoke).supply(lendReserve, 1_000_000 * whole, daoTreasury);
        vm.stopPrank();
    }

    function _volatileFirstLoss(
        ClTestToken asset,
        uint256 assetId,
        uint256 whole
    ) private returns (address cs) {
        cs = deployCode(
            "AvanaFirstLossReserve.sol:AvanaFirstLossReserve",
            abi.encode(hubV, address(asset), assetId, aave.accessManager, 1_209_600)
        );
        uint24 maxRp = IAaveV4Hub(hubV).MAX_RISK_PREMIUM_THRESHOLD();
        vm.prank(aaveDao);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(hubV, cs, assetId, CollHubSpokeConfig(1_000_000, 0, maxRp, true, false));
        _grantDeficitEliminator(cs);
        asset.mint(address(this), 100_000 * whole);
        asset.approve(cs, 100_000 * whole);
        AvanaFirstLossReserve(cs).fund(100_000 * whole);
        firstLossReserveOfV[address(asset)] = cs;
        vm.label(cs, string.concat(asset.symbol(), " AvanaFirstLossReserve (Volatile Hub)"));
        vm.startPrank(address(timelock));
        registry.setAvanaFirstLossReserve(hubV, address(asset), cs);
        registry.recordCreditLine(hubV, address(asset), CREDIT_LINE);
        vm.stopPrank();
    }

    // ─── Volatile markets ───

    /// @notice A real Uniswap v3 pool of `a`/`b` on the fixture's factory at `fee`, initialized at the tokens' published
    /// prices with `liquidity` on its full range held by outside LPs, its observation buffer grown to 151 slots a block
    /// later. Call `_ageNewPools` once the pools of a suite exist, so their TWAP covers the window.
    function _newVolatilePool(
        ClTestToken a,
        ClTestToken b,
        uint24 fee,
        uint128 liquidity
    ) internal returns (IClPool p) {
        (ClTestToken t0, ClTestToken t1) = address(a) < address(b) ? (a, b) : (b, a);
        p = _createPool(t0, t1, fee, _usdPrice(address(t0)), _usdPrice(address(t1)), 151, liquidity);
        vm.label(address(p), string.concat("UniswapV3Pool ", t0.symbol(), "/", t1.symbol()));
    }

    /// @notice The new pools' observation buffers grown (`_touch`) and two hours passed, every feed republished and
    /// every LPOracle and DebtOracle poked: a pool's 1,800 s TWAP then covers the window.
    function _ageNewPools(
        IClPool[] memory pools
    ) internal {
        for (uint256 i = 0; i < pools.length; ++i) {
            _touch(pools[i]);
        }
        vm.warp(block.timestamp + 7200);
        vm.roll(block.number + 7200 / BLOCK_TIME);
        _refreshFeeds();
        _pokeAll();
        usdcOracle.poke();
    }

    /// @notice Lists and activates the full range of the volatile pool `p` on the Volatile Spoke, as `_addMarket`
    /// does on the Stable one: vault-token decimals `d` and the pool's unit exponent `k` as the real LPVault's
    /// `bindMarket` computes them from the listing prices (the feeds'), the LPOracleCL initialized with `k`, CF `cf`.
    function _addVolatileMarket(
        IClPool p,
        uint16 cf
    ) internal returns (uint256 id) {
        id = _addClMarket(p, cf, ClSite(V3, integration, hubV, spokeV, irV, 7, 0));
    }

    /// @notice `_addVolatileMarket` at any site: the full range of `p` listed and activated on `site`'s Spoke with the
    /// unit of the real LPVault's `bindMarket`, CF `cf`, and routes from each pool token into USDC and GHO. A market
    /// whose two tokens are USD stables carries the chain's USD band; any other has none (REQ-ORACLE-056).
    function _addClMarket(
        IClPool p,
        uint16 cf,
        ClSite memory site
    ) internal returns (uint256 id) {
        id = registry.marketCount() + 1;
        MarketInfo storage m = mkt[id];
        m.pool = p;
        (uint8 d, uint8 k) = _unitOf(p);
        m.oracle = _volatileOracle(id, p, k, site);
        m.vaultToken = _volatileVaultToken(id, p, address(m.oracle), d, site);
        _listVolatile(p, m.vaultToken, address(m.oracle), site);
        require(IClIntegration(site.lpVault).unitExponent(id) == k, "the LPVault bound the pool's unit exponent");
        _storeVolatile(id);
        _aaveVolatile(m, d, cf, site);
        _routesInto(id, address(usdc));
        _routesInto(id, address(gho));
        vm.prank(address(timelock));
        registry.activateMarket(id);
        vm.label(m.vaultToken, string.concat("VaultToken ", vm.toString(id)));
        vm.label(address(m.oracle), string.concat("LPOracle ", vm.toString(id)));
    }

    /// @dev The full range's vault-token decimals and the pool's unit exponent at the listing prices (`ClUnitMath`, as
    /// the LPVault's first binding of the pool computes them).
    function _unitOf(
        IClPool p
    ) internal view returns (uint8 d, uint8 k) {
        (address t0, address t1) = (p.token0(), p.token1());
        ClUnitMath.Valuation memory v =
            ClUnitMath.valuation(_usdPrice(t0), _usdPrice(t1), ClTestToken(t0).decimals(), ClTestToken(t1).decimals());
        bool found;
        (found, k) = ClUnitMath.firstBindingExponent(v, p.tickSpacing());
        require(found, "unit exponent");
        (int24 lower, int24 upper) = _fullRange(p);
        (found, d) = ClUnitMath.unitDecimals(v, lower, upper, k);
        require(found, "unit decimals");
    }

    function _volatileOracle(
        uint256 id,
        IClPool p,
        uint8 k,
        ClSite memory site
    ) private returns (LPOracleCL o) {
        (int24 lower, int24 upper) = _fullRange(p);
        LPOracleCL impl =
            LPOracleCLDeployer.deploy(address(timelock), BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, site.slot0Words);
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (p.token0(), p.token1());
        InitParams memory ip;
        ip.timelock = address(timelock);
        ip.parameterStore = address(store);
        ip.marketRegistry = address(registry);
        ip.marketId = id;
        ip.integration = site.lpVault;
        ip.isUsdStable = new bool[](2);
        (ip.isUsdStable[0], ip.isUsdStable[1]) = (_isStable(toks[0]), _isStable(toks[1]));
        ip.description = "CL LP / USD";
        ip.pokeMinGas = POKE_FLOOR;
        ip.config = _oracleConfigFor(id, toks);
        // A market with a token that is not a USD stable has no USD band (REQ-ORACLE-056).
        if (!ip.isUsdStable[0] || !ip.isUsdStable[1]) {
            (ip.config.usdBandLow, ip.config.usdBandHigh) = (0, type(uint256).max);
        }
        ip.market = abi.encode(address(p), lower, upper, uint256(k));
        o = LPOracleCL(address(new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (ip)))));
    }

    function _volatileVaultToken(
        uint256 id,
        IClPool p,
        address oracle,
        uint8 d,
        ClSite memory site
    ) private returns (address vt) {
        VtMeta memory v;
        (v.name, v.symbol) = _vtNames(id, p);
        v.shape = _fullShape(p);
        vm.prank(address(timelock));
        vt = vtFactory.deployVaultToken(
            site.integrationId, address(p), bytes32(0), v.shape, site.hub, site.spoke, id, oracle, d, v.name, v.symbol
        );
    }

    /// @dev True for the fixture's USD stable pool tokens.
    function _isStable(
        address token
    ) internal view returns (bool) {
        return token == address(usdc) || token == address(usdt);
    }

    function _vtNames(
        uint256 id,
        IClPool p
    ) private view returns (string memory name, string memory symbol) {
        string memory pair = string.concat(ClTestToken(p.token0()).symbol(), "-", ClTestToken(p.token1()).symbol());
        name = string.concat("Avana ", pair, " ", vm.toString(id));
        symbol = string.concat("av", pair, "-", vm.toString(id));
    }

    function _fullShape(
        IClPool p
    ) private view returns (PositionShape memory) {
        (int24 lower, int24 upper) = _fullRange(p);
        return PositionShape(ShapeKind.TickRange, lower, upper);
    }

    function _listVolatile(
        IClPool p,
        address vt,
        address oracle,
        ClSite memory site
    ) private {
        (int24 lower, int24 upper) = _fullRange(p);
        MarketDef memory d;
        (d.hub, d.spoke, d.integrationId, d.pool) = (site.hub, site.spoke, site.integrationId, address(p));
        d.shape = PositionShape(ShapeKind.TickRange, lower, upper);
        (d.vaultToken, d.lpOracle) = (vt, oracle);
        (uint256 p0, uint256 p1) = (_usdPrice(p.token0()), _usdPrice(p.token1()));
        // Slipstream's `bindMarket` reads the pool's generation first (`abi.encode(generation, price0, price1)`).
        d.integrationData = site.slot0Words == 6 ? abi.encode(uint256(site.generation), p0, p1) : abi.encode(p0, p1);
        vm.prank(address(timelock));
        registry.listCollateralMarket(d);
    }

    function _storeVolatile(
        uint256 id
    ) private {
        MarketParams memory mp;
        (mp.twapWindow, mp.consistencyToleranceBps, mp.slippageAllowanceBps, mp.slippageAllowanceMinBps) =
        (1800, 50, 195, 30);
        (mp.poolRiskFactor, mp.minPledgeUsd) = (POOL_RISK_FACTOR, MIN_PLEDGE_USD);
        vm.startPrank(address(timelock));
        store.setInitialMarketParams(id, mp);
        store.setInitialMarketCaps(id, 1_000_000e8, 100_000e8, 1e8);
        store.loosenMarketSpeedLimits(
            id, MarketSpeedLimits(21_600, 2500, 2500, 250_000e8, 2_500_000e8, 1_000_000e8, 10_000_000e8)
        );
        vm.stopPrank();
    }

    /// @dev The Aave DAO's payload on the Volatile Hub and Spoke: the vault token as a Hub asset of `d` decimals (the
    /// Spoke and the fee receiver only) and the Spoke's collateral reserve at CF `cf` and bonus 10,500, priced by the
    /// market's LPOracle.
    function _aaveVolatile(
        MarketInfo storage m,
        uint8 d,
        uint16 cf,
        ClSite memory site
    ) private {
        address hub = site.hub;
        uint24 maxRp = IAaveV4Hub(hub).MAX_RISK_PREMIUM_THRESHOLD();
        vm.startPrank(aaveDao);
        m.assetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(hub, m.vaultToken, d, aave.treasurySpoke, 0, site.ir, _irData());
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(hub, site.spoke, m.assetId, CollHubSpokeConfig(VT_ADD_CAP, 0, maxRp, true, false));
        m.reserveId = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                site.spoke,
                hub,
                m.assetId,
                address(m.oracle),
                CollSpokeReserveConfig(0, false, false, false, false),
                CollSpokeDynamicReserveConfig(cf, 10_500, 0)
            );
        (bool ok,) = aave.hubConfigurator
            .call(
                abi.encodeWithSignature(
                    "updateSpokeAddCap(address,uint256,address,uint256)", hub, m.assetId, aave.treasurySpoke, 0
                )
            );
        require(ok, "fee receiver add cap");
        vm.stopPrank();
    }

    /// @notice The Volatile Hub (`_setUpVolatile`) and its WBTC/WETH market: the full range of a real 0.3 % pool
    /// (liquidity 1e16, about $27M) created at $60,000 and $3,000, CF 30 %. Neither token is priced from a USDC feed.
    function _wbtcWethMarket() internal returns (uint256 id) {
        _setUpVolatile();
        IClPool[] memory pools = new IClPool[](1);
        pools[0] = _newVolatilePool(wbtc, weth, 3000, 1e16);
        _ageNewPools(pools);
        id = _addVolatileMarket(pools[0], 3000);
    }

    /// @notice `wallet`'s account in `marketId` on the Volatile Spoke: $60,000 of liquidity against USDC at HF about
    /// 1.02 (the Lens's `previewBorrowMax` / 1.02), then WBTC and WETH 10 % lower on every feed and in the pool, the TWAP
    /// window waited: HF about 0.92.
    function _usdcAccountBelowOne(
        address wallet,
        uint256 marketId
    ) internal returns (address proxy, bytes32 key) {
        (key, proxy) = _pledgeUsd(wallet, marketId, 60_000);
        uint256 max = lens.previewBorrowMax(wallet, marketId, usdcReserveIdV, _deadline());
        _borrowAs(wallet, marketId, usdcReserveIdV, max * 100 / 102);
        _publish(address(wbtc), 54_000e8);
        _publish(address(weth), WETH_PRICE * 9 / 10);
        _repriceMarkets();
        require(_hfOn(spokeV, proxy) < 1e18, "below HF 1");
    }

    /// @notice A new round now, at its current answer, on every feed of every priced token and GHO's, except `skip`.
    function _refreshFeedsExcept(
        OracleFeedMock[] memory skip
    ) internal {
        for (uint256 t = 0; t < pricedTokens.length; ++t) {
            OracleFeedMock[4] storage f = feedsOf[pricedTokens[t]];
            for (uint256 i = 0; i < 4; ++i) {
                bool skipped = false;
                for (uint256 k = 0; k < skip.length; ++k) {
                    if (skip[k] == f[i]) skipped = true;
                }
                if (!skipped) f[i].push(f[i].answer(), block.timestamp);
            }
        }
        ghoFeed.push(ghoFeed.answer(), block.timestamp);
    }

    function _warpBlocks(
        uint256 s_
    ) internal {
        vm.warp(block.timestamp + s_);
        vm.roll(block.number + s_ / BLOCK_TIME);
    }

    // ─── Positions, prices and liquidation on any Spoke ───

    /// @notice A full-range NFT in `marketId`'s pool minted by `wallet` from about `usd` dollars (half in each token at
    /// the published prices), approved to the LPVault and pledged through the Adapter.
    function _pledgeUsd(
        address wallet,
        uint256 marketId,
        uint256 usd
    ) internal returns (bytes32 key, address proxy) {
        key = _mintUsd(wallet, marketId, usd);
        vm.prank(wallet);
        (proxy,,) = adapterC.pledge(marketId, _ref(key), _deadline());
    }

    /// @notice The NFT of `_pledgeUsd`, minted and approved to the LPVault but not pledged.
    function _mintUsd(
        address wallet,
        uint256 marketId,
        uint256 usd
    ) internal returns (bytes32 key) {
        IClPool p = mkt[marketId].pool;
        (ClTestToken t0, ClTestToken t1) = (ClTestToken(p.token0()), ClTestToken(p.token1()));
        uint256 a0 = usd * 10 ** t0.decimals() * 1e8 / (2 * _usdPrice(address(t0)));
        uint256 a1 = usd * 10 ** t1.decimals() * 1e8 / (2 * _usdPrice(address(t1)));
        t0.mint(wallet, a0);
        t1.mint(wallet, a1);
        vm.startPrank(wallet);
        t0.approve(address(nfpm), a0);
        t1.approve(address(nfpm), a1);
        key = _nfpmMint(wallet, p, a0, a1);
        IERC721(address(nfpm)).approve(integration, uint256(key));
        vm.stopPrank();
    }

    function _nfpmMint(
        address wallet,
        IClPool p,
        uint256 a0,
        uint256 a1
    ) private returns (bytes32) {
        (int24 lower, int24 upper) = _fullRange(p);
        (uint256 tokenId,,,) = nfpm.mint(
            INonfungiblePositionManager.MintParams({
                token0: p.token0(),
                token1: p.token1(),
                fee: _fee(p),
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: wallet,
                deadline: block.timestamp
            })
        );
        return bytes32(tokenId);
    }

    /// @notice Every market's pool swapped to its tokens' published prices, then `TWAP_WAIT` so each 1,800 s TWAP agrees
    /// with the feeds, every feed republished, the route-DEX pools aligned and every oracle poked.
    function _repriceMarkets() internal {
        uint256 n = registry.marketCount();
        for (uint256 id = 1; id <= n; ++id) {
            IClPool p = mkt[id].pool;
            (ClTestToken t0, ClTestToken t1) = (ClTestToken(p.token0()), ClTestToken(p.token1()));
            _swapTo(
                p,
                ClPriceMath.oracleSqrtPrice(
                    _usdPrice(address(t0)), _usdPrice(address(t1)), t0.decimals(), t1.decimals()
                )
            );
        }
        vm.warp(block.timestamp + TWAP_WAIT);
        vm.roll(block.number + TWAP_WAIT / BLOCK_TIME);
        _refreshFeeds();
        _alignRoutes();
        _pokeAll();
        usdcOracle.poke();
    }

    function _hfOn(
        address spoke,
        address proxy
    ) internal view returns (uint256) {
        return IAaveV4Spoke(spoke).getUserAccountData(proxy).healthFactor;
    }

    function _debtOn(
        address spoke,
        address proxy,
        uint256 reserveId
    ) internal view returns (uint256) {
        return IAaveV4Spoke(spoke).getUserTotalDebt(reserveId, proxy);
    }

    function _sharesOn(
        address spoke,
        address proxy,
        uint256 reserveId
    ) internal view returns (uint256) {
        return IAaveV4Spoke(spoke).getUserSuppliedShares(reserveId, proxy);
    }

    /// @notice `_liquidateAs` for a debt reserve of any Spoke: the caller is funded in the reserve's asset.
    function _liquidateOn(
        address spoke,
        address caller,
        LiquidationParams memory p
    ) internal returns (LiquidationResult memory r) {
        ClTestToken asset = ClTestToken(registry.getDebtReserve(spoke, p.debtReserveId).asset);
        asset.mint(caller, p.debtToCover + p.maxShortfall);
        vm.startPrank(caller);
        asset.approve(lpVaultSwap, p.debtToCover + p.maxShortfall);
        r = lvs.liquidate(p);
        vm.stopPrank();
    }
}
