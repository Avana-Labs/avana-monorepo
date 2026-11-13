// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {DexHop, HopKind} from "../../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {RiskTier} from "../../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../../src/policy/market-registry/types/SpokeDef.sol";
import {Market} from "../../../src/types/Market.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {CollPoolToken} from "../mocks/CollateralizationMocks.sol";
import {IntegLPVaultMock} from "../mocks/IntegLPVaultMock.sol";
import {IntegDebtOracleMock, IntegLPOracleMock} from "../mocks/IntegOracleMocks.sol";
import {IntegRegistryMock, IntegStoreMock} from "../mocks/IntegrationMocks.sol";
import {MockCLPool, MockPoolFactory} from "../mocks/SwapRouteMocks.sol";
import {
    CollHubSpokeConfig,
    CollInterestRateData,
    CollSpokeDynamicReserveConfig,
    CollSpokeLiquidationConfig,
    CollSpokeReserveConfig,
    CollateralizationFixture,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "./CollateralizationFixture.sol";

interface IIntegConfigurator {
    function updateSpokeAddCap(
        address hub,
        uint256 assetId,
        address spoke,
        uint256 addCap
    ) external;
    function updateReservePriceSource(
        address spoke,
        uint256 reserveId,
        address priceSource
    ) external;
}

/// @title IntegrationMarkets
/// @notice The listing layer of the integration world: pool tokens with their prices and feeds, one standard CDP Spoke
/// per AMM integration (each with its own LPVault, its GHO and USDC debt reserves and its liquidation config), and
/// markets added from a small `MarketConfig` (pool, tokens, unwind composition, vault-token decimals, price, CF, bonus,
/// range, Hub add cap) with their vault token, Hub asset, Spoke reserve, LPOracle, records in the registry and store
/// stand-ins, and a primary and a backup swap route from every pool token into every debt asset at the oracle rate.
/// @dev A later suite adds a pool with `_newToken` and `_addMarket(cfg)`; routes between a pair are built once and
/// reused by every market, and `_moveTokenPrice` moves a token's price in every oracle, vault price and route at once.
/// The RiskModule's drift check expects `CF = floor(min token CF × poolRiskFactor / 1e4)`: every token's CF is 8,000
/// and each market's pool risk factor is `cf × 1e4 / 8,000` (so `cf` must be a multiple of 4 bps). Unwind rates are raw
/// units of each token per raw vault-token unit, scaled by 1e18. Contracts are created with `deployCode` so the
/// fixture's own bytecode stays small.
abstract contract IntegrationMarkets is CollateralizationFixture {
    uint32 internal constant FEED_AGE = 88_200;
    uint32 internal constant UNISWAP_V3 = 1;
    uint32 internal constant SLIPSTREAM = 2;
    uint16 internal constant TOKEN_CF = 8000;
    uint256 internal constant SLIPPAGE_BPS = 100;

    struct MarketConfig {
        uint256 marketId;
        uint32 integrationId;
        string symbol;
        address pool;
        address[] tokens;
        uint256[] rates;
        uint8 vtDecimals;
        uint256 vaultPrice8;
        uint16 collateralFactor;
        uint32 maxLiquidationBonus;
        int24 tickLower;
        int24 tickUpper;
        uint40 addCap;
    }

    struct MarketInfo {
        uint32 integrationId;
        address spoke;
        address vaultToken;
        uint256 reserveId;
        uint256 hubAssetId;
        IntegLPOracleMock oracle;
        IntegLPVaultMock vault;
    }

    struct CdpSpoke {
        address spoke;
        address implementation;
        address oracle;
        IntegLPVaultMock vault;
        uint256 ghoReserveId;
        uint256 usdcReserveId;
    }

    IntegRegistryMock internal reg;
    IntegStoreMock internal store;
    IntegDebtOracleMock internal usdcOracle;
    MockPoolFactory internal v3Factory;
    uint256 internal ghoAssetId;
    uint256 internal usdcAssetId;
    address internal ghoCoverageAddr;
    address internal usdcCoverageAddr;
    mapping(uint32 => CdpSpoke) internal cdp;
    mapping(uint256 => MarketInfo) internal markets;
    uint256[] internal marketIds;
    mapping(address => uint256) internal tokenPrice8;
    mapping(address => address) internal tokenFeed;
    mapping(address => mapping(address => address[2])) internal routeOf;
    mapping(address => mapping(address => MockCLPool[2])) internal routePools;
    mapping(uint256 => address[]) internal configTokens;
    mapping(uint256 => uint256[]) internal configRates;
    mapping(uint256 => uint8) internal configVtDecimals;
    mapping(uint256 => bool) internal derivedPrice;
    address[2][] internal routePairs;

    // ─── Tokens ───

    /// @notice A pool token of `decimals` at `price8`, with its feed and CF.
    function _newToken(
        string memory symbol,
        uint8 decimals,
        uint256 price8
    ) internal returns (CollPoolToken t) {
        t = new CollPoolToken(symbol, decimals);
        _registerToken(address(t), symbol, price8);
    }

    function _registerToken(
        address t,
        string memory symbol,
        uint256 price8
    ) internal {
        tokenPrice8[t] = price8;
        tokenFeed[t] = makeAddr(string.concat("feed ", symbol, "/USD"));
        store.setBorrowAge(tokenFeed[t], FEED_AGE);
        store.setTokenCf(t, TOKEN_CF);
        store.setTokenCap(aave.hub, t, 1e30);
        vm.label(t, symbol);
    }

    // ─── CDP Spokes ───

    /// @notice Records `spoke` as the CDP Spoke of `integrationId`: GHO and USDC debt reserves on it, Aave's liquidation
    /// config, its SpokeDef, debt reserve definitions and liquidation expectations. Pass reserve IDs already listed
    /// (the base Spoke's GHO) or `type(uint256).max` to list here.
    function _recordCdpSpoke(
        uint32 integrationId,
        address spoke,
        address implementation,
        address oracle,
        IntegLPVaultMock vault_,
        uint256 ghoReserve,
        uint256 usdcReserve
    ) internal {
        vm.startPrank(aaveDao);
        if (ghoReserve == type(uint256).max) ghoReserve = _listDebt(spoke, ghoAssetId, address(debtPrice), 1_000_000);
        if (usdcReserve == type(uint256).max) {
            usdcReserve = _listDebt(spoke, usdcAssetId, address(usdcOracle), 5_000_000);
        }
        ICollSpokeConfigurator(aave.spokeConfigurator)
            .updateLiquidationConfig(spoke, CollSpokeLiquidationConfig(1.1e18, 0.95e18, 5000));
        vm.stopPrank();
        cdp[integrationId] = CdpSpoke(spoke, implementation, oracle, vault_, ghoReserve, usdcReserve);
        reg.setSpoke(spoke, SpokeDef(true, aave.hub, integrationId, RiskTier.Stable, implementation, oracle));
        reg.setDebtReserve(spoke, ghoReserve, _debtDef(ghoReserve, address(debt), 18, ghoAssetId));
        reg.setDebtReserve(spoke, usdcReserve, _debtDef(usdcReserve, address(usdc), 6, usdcAssetId));
        reg.setIntegrationId(address(vault_), integrationId);
        store.setLiquidationExpectations(spoke, 1.1e18, 200);
    }

    function _listDebt(
        address spoke,
        uint256 assetId,
        address source,
        uint40 drawCap
    ) private returns (uint256 reserveId) {
        uint24 maxRp = IAaveV4Hub(aave.hub).MAX_RISK_PREMIUM_THRESHOLD();
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, spoke, assetId, CollHubSpokeConfig(0, drawCap, maxRp, true, false));
        reserveId = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                spoke,
                aave.hub,
                assetId,
                source,
                CollSpokeReserveConfig(0, false, false, true, false),
                CollSpokeDynamicReserveConfig(0, 10_000, 0)
            );
    }

    function _debtDef(
        uint256 reserveId,
        address asset,
        uint8 decimals,
        uint256 hubAssetId
    ) internal view returns (DebtReserveDef memory def) {
        bool fixedPrice = asset == address(debt);
        def = DebtReserveDef({
            reserveId: reserveId,
            asset: asset,
            decimals: decimals,
            fundingHub: aave.hub,
            hubAssetId: hubAssetId,
            priceSource: fixedPrice ? address(debtPrice) : address(usdcOracle),
            fixedPrice: fixedPrice,
            coverageSpoke: fixedPrice ? ghoCoverageAddr : usdcCoverageAddr,
            crossHub: false,
            approved: true
        });
    }

    // ─── Markets ───

    /// @notice Lists a market from `c`: vault token, Hub asset and Spoke reserve (its LPOracle as the price source), the
    /// registry and store records, and routes from each pool token into GHO and USDC.
    function _addMarket(
        MarketConfig memory c
    ) internal returns (MarketInfo memory info) {
        info = _bind(c);
        vm.prank(timelock);
        info.vaultToken = factory.deployVaultToken(
            c.integrationId,
            c.pool,
            bytes32(0),
            PositionShape(ShapeKind.TickRange, c.tickLower, c.tickUpper),
            aave.hub,
            info.spoke,
            c.marketId,
            address(info.oracle),
            c.vtDecimals,
            string.concat("Avana ", c.symbol),
            string.concat("av", c.symbol)
        );
        uint24 maxRp = IAaveV4Hub(aave.hub).MAX_RISK_PREMIUM_THRESHOLD();
        vm.startPrank(aaveDao);
        info.hubAssetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(
                aave.hub, info.vaultToken, c.vtDecimals, aave.treasurySpoke, 0, aave.irStrategy, _ir()
            );
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, info.spoke, info.hubAssetId, CollHubSpokeConfig(c.addCap, 0, maxRp, true, false));
        info.reserveId = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                info.spoke,
                aave.hub,
                info.hubAssetId,
                address(info.oracle),
                CollSpokeReserveConfig(0, false, false, false, false),
                CollSpokeDynamicReserveConfig(c.collateralFactor, c.maxLiquidationBonus, 0)
            );
        IIntegConfigurator(aave.hubConfigurator).updateSpokeAddCap(aave.hub, info.hubAssetId, aave.treasurySpoke, 0);
        vm.stopPrank();
        _record(c, info);
    }

    /// @notice Records a market whose vault token and Spoke reserve a base fixture already listed (`vt_`, `reserveId`):
    /// its LPOracle becomes the reserve's price source and the fee receiver's add cap is set to 0.
    function _adoptMarket(
        MarketConfig memory c,
        address vt_,
        uint256 reserveId
    ) internal returns (MarketInfo memory info) {
        info = _bind(c);
        (info.vaultToken, info.reserveId) = (vt_, reserveId);
        info.hubAssetId = IAaveV4Hub(aave.hub).getAssetId(vt_);
        vm.startPrank(aaveDao);
        IIntegConfigurator(aave.spokeConfigurator).updateReservePriceSource(info.spoke, reserveId, address(info.oracle));
        IIntegConfigurator(aave.hubConfigurator).updateSpokeAddCap(aave.hub, info.hubAssetId, aave.treasurySpoke, 0);
        vm.stopPrank();
        _record(c, info);
    }

    function _bind(
        MarketConfig memory c
    ) private returns (MarketInfo memory info) {
        CdpSpoke storage s = cdp[c.integrationId];
        require(s.spoke != address(0), "no CDP Spoke for the integration");
        (info.integrationId, info.spoke, info.vault) = (c.integrationId, s.spoke, s.vault);
        if (c.vaultPrice8 == 0) {
            c.vaultPrice8 = _derivedPrice(c.tokens, c.rates, c.vtDecimals);
            derivedPrice[c.marketId] = true;
        }
        s.vault.bindMarket(c.marketId, c.pool, c.tokens, c.rates, c.tickLower, c.tickUpper);
        uint256[] memory prices = new uint256[](c.tokens.length);
        address[] memory feeds = new address[](c.tokens.length);
        for (uint256 i = 0; i < c.tokens.length; ++i) {
            (prices[i], feeds[i]) = (tokenPrice8[c.tokens[i]], tokenFeed[c.tokens[i]]);
            CollPoolToken(c.tokens[i]).mint(address(s.vault), 1e40);
        }
        info.oracle = IntegLPOracleMock(
            deployCode("IntegOracleMocks.sol:IntegLPOracleMock", abi.encode(c.marketId, address(s.vault)))
        );
        info.oracle.setTokenReport(c.tokens, feeds, prices, uint64(block.timestamp));
        info.oracle.setAnswer(int256(c.vaultPrice8));
        vm.label(address(info.oracle), string.concat("LPOracle ", c.symbol));
    }

    function _record(
        MarketConfig memory c,
        MarketInfo memory info
    ) private {
        markets[c.marketId] = info;
        (configTokens[c.marketId], configRates[c.marketId]) = (c.tokens, c.rates);
        configVtDecimals[c.marketId] = c.vtDecimals;
        marketIds.push(c.marketId);
        reg.setMarket(c.marketId, _marketDef(c, info));
        reg.setSettlementReserve(c.marketId, cdp[c.integrationId].usdcReserveId);
        require(uint256(c.collateralFactor) * 1e4 % TOKEN_CF == 0, "cf must be a multiple of 4 bps");
        store.setMarket(c.marketId, uint16(uint256(c.collateralFactor) * 1e4 / TOKEN_CF), 0, 1e30, 0, 0);
        store.setTwap(c.marketId, 1800);
        store.setSlippage(c.marketId, uint16(SLIPPAGE_BPS));
        address[2] memory debtAssets = [address(usdc), address(debt)];
        for (uint256 i = 0; i < c.tokens.length; ++i) {
            for (uint256 j = 0; j < 2; ++j) {
                if (c.tokens[i] == debtAssets[j]) continue;
                address[2] memory r = _routes(c.tokens[i], debtAssets[j]);
                reg.setRoute(c.marketId, c.tokens[i], debtAssets[j], 0, r[0], true);
                reg.setRoute(c.marketId, c.tokens[i], debtAssets[j], 1, r[1], true);
            }
        }
        vm.label(info.vaultToken, string.concat("VaultToken ", c.symbol));
    }

    function _marketDef(
        MarketConfig memory c,
        MarketInfo memory info
    ) internal view returns (Market memory m) {
        uint8[] memory decimals = new uint8[](c.tokens.length);
        for (uint256 i = 0; i < c.tokens.length; ++i) {
            decimals[i] = CollPoolToken(c.tokens[i]).decimals();
        }
        m = Market({
            chainId: uint64(block.chainid),
            hub: aave.hub,
            spoke: info.spoke,
            integrationId: c.integrationId,
            integration: address(info.vault),
            pool: c.pool,
            poolId: bytes32(0),
            shape: PositionShape(ShapeKind.TickRange, c.tickLower, c.tickUpper),
            tokens: c.tokens,
            tokenDecimals: decimals,
            vaultToken: info.vaultToken,
            decimals: c.vtDecimals,
            lpOracle: address(info.oracle),
            hubAssetId: info.hubAssetId,
            reserveId: info.reserveId,
            status: MarketStatus.Active,
            registeredAt: uint64(block.timestamp),
            activatedAt: uint64(block.timestamp)
        });
    }

    /// @dev The vault price the unwind composition is worth at the token prices, 8 decimals per whole vault token.
    function _derivedPrice(
        address[] memory tokens,
        uint256[] memory rates,
        uint8 vtDecimals
    ) internal view returns (uint256 price8) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint8 d = CollPoolToken(tokens[i]).decimals();
            price8 += rates[i] * tokenPrice8[tokens[i]] * 10 ** vtDecimals / (1e18 * 10 ** d);
        }
    }

    // ─── Routes ───

    /// @notice The primary and backup routes from `tokenIn` into `tokenOut`, built on first use at the oracle rate
    /// `priceIn × 10^decOut / (priceOut × 10^decIn)`, each over its own pool registered in the pinned factory.
    function _routes(
        address tokenIn,
        address tokenOut
    ) internal returns (address[2] memory r) {
        r = routeOf[tokenIn][tokenOut];
        if (r[0] != address(0)) return r;
        uint256 num = tokenPrice8[tokenIn] * 10 ** CollPoolToken(tokenOut).decimals();
        uint256 den = tokenPrice8[tokenOut] * 10 ** CollPoolToken(tokenIn).decimals();
        for (uint256 k = 0; k < 2; ++k) {
            MockCLPool p = MockCLPool(deployCode("SwapRouteMocks.sol:MockCLPool", abi.encode(tokenIn, tokenOut)));
            p.setRate(num, den);
            CollPoolToken(tokenIn).mint(address(p), 1e40);
            CollPoolToken(tokenOut).mint(address(p), 1e40);
            v3Factory.register(address(p));
            routePools[tokenIn][tokenOut][k] = p;
            r[k] = _route(tokenIn, tokenOut, p);
        }
        routeOf[tokenIn][tokenOut] = r;
        routePairs.push([tokenIn, tokenOut]);
    }

    function _route(
        address tokenIn,
        address tokenOut,
        MockCLPool p
    ) private returns (address) {
        DexHop[] memory hops = new DexHop[](1);
        hops[0] = DexHop({kind: HopKind.ConcentratedLiquidity, pool: address(p), tokenOut: tokenOut, i: 0, j: 0});
        RouteConfig memory c = RouteConfig({
            lpVaultSwap: lpVaultSwap,
            lock: address(lock),
            aaveAdapter: adapter,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            tokenClassMask: 1 << 1,
            uniswapV3Factory: address(v3Factory),
            slipstreamFactory: deployCode("SwapRouteMocks.sol:MockPoolFactory"),
            curveFactory: deployCode("SwapRouteMocks.sol:MockPoolFactory"),
            curveLegacyPools: new address[](0)
        });
        return deployCode("DexPathRoute.sol:DexPathRoute", abi.encode(c, hops));
    }

    // ─── Prices ───

    /// @notice A new price of `token` everywhere it is read: its feed in every market's LPOracle, the vault price of
    /// every market whose price follows its composition, the rate of every route into or out of it, and the USDC
    /// DebtOracle when the token is USDC. Call it step by step with `vm.warp` for a crash over time.
    function _moveTokenPrice(
        address token,
        uint256 price8
    ) internal {
        tokenPrice8[token] = price8;
        for (uint256 i = 0; i < marketIds.length; ++i) {
            uint256 id = marketIds[i];
            address[] memory tokens = configTokens[id];
            bool inMarket = false;
            for (uint256 k = 0; k < tokens.length; ++k) {
                if (tokens[k] == token) inMarket = true;
            }
            if (!inMarket) continue;
            markets[id].oracle.setTokenPrice(token, price8);
            if (derivedPrice[id]) {
                markets[id].oracle.setAnswer(int256(_derivedPrice(tokens, configRates[id], configVtDecimals[id])));
            }
        }
        for (uint256 i = 0; i < routePairs.length; ++i) {
            (address a, address b) = (routePairs[i][0], routePairs[i][1]);
            if (a != token && b != token) continue;
            uint256 num = tokenPrice8[a] * 10 ** CollPoolToken(b).decimals();
            uint256 den = tokenPrice8[b] * 10 ** CollPoolToken(a).decimals();
            routePools[a][b][0].setRate(num, den);
            routePools[a][b][1].setRate(num, den);
        }
        if (token == address(usdc)) usdcOracle.setAnswer(int256(price8));
    }

    function _ir() internal pure returns (bytes memory) {
        return abi.encode(CollInterestRateData(9000, 0, 400, 6000));
    }

    function _pair(
        address a,
        address b
    ) internal pure returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (a, b);
    }

    function _two(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        (list[0], list[1]) = (a, b);
    }
}
