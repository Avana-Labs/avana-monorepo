// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILens} from "../../../src/lens/lens/ILens.sol";
import {Lens} from "../../../src/lens/lens/Lens.sol";
import {LensAccountModule} from "../../../src/lens/lens/LensAccountModule.sol";
import {LensLiquidationModule} from "../../../src/lens/lens/LensLiquidationModule.sol";
import {LensMarketModule} from "../../../src/lens/lens/LensMarketModule.sol";
import {LensMarketsModule} from "../../../src/lens/lens/LensMarketsModule.sol";
import {LensPositionsModule} from "../../../src/lens/lens/LensPositionsModule.sol";
import {LensPreviewModule} from "../../../src/lens/lens/LensPreviewModule.sol";
import {LensPriceModule} from "../../../src/lens/lens/LensPriceModule.sol";
import {LensRiskModule} from "../../../src/lens/lens/LensRiskModule.sol";
import {LensSpeedModule} from "../../../src/lens/lens/LensSpeedModule.sol";
import {PayoutEscrow} from "../../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/MarketParams.sol";
import {ProxyManager} from "../../../src/proxy/proxy-manager/ProxyManager.sol";
import {Market} from "../../../src/types/Market.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {AaveAdapterLensMock} from "../mocks/AaveAdapterLensMock.sol";
import {LPVaultSwapLensMock} from "../mocks/LPVaultSwapLensMock.sol";
import {
    LensCoverageMock,
    LensDebtOracleMock,
    LensFlashSourceMock,
    LensLPOracleMock,
    LensLPVaultMock,
    LensRegistryMock,
    LensRiskModuleMock,
    LensStoreMock
} from "../mocks/LensMocks.sol";
import {
    CollHubSpokeConfig,
    CollSpokeDynamicReserveConfig,
    CollSpokeReserveConfig,
    CollateralizationFixture,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "./CollateralizationFixture.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LensFixture
/// @notice The Lens over the real local Aave V4 (pinned release), the real Collateralization, Lock, VaultTokenFactory,
/// vault token, ProxyManager and PayoutEscrow of `CollateralizationFixture`'s USDC/USDT market (integration 1, market
/// 4, 6 decimals, $2.00 per whole vault token, CF 80 %), with two debt reserves on the CDP Spoke: GHO (18 decimals,
/// fixed $1.00) and USDC (6 decimals, priced by a DebtOracle stand-in). The MarketRegistry, ParameterStore, RiskModule,
/// the market's LPOracle and the AMM integration's extra views are settable stand-ins, so every price, pause, freeze
/// and breaker state can be set exactly; the AaveAdapter and LPVaultSwap stand-ins (`AaveAdapterLensMock`,
/// `LPVaultSwapLensMock`) sit at the two Lock members' addresses.
/// @dev Suites set `isolate = false`: the fixture's flows hold the Lock across several calls of one test.
abstract contract LensFixture is CollateralizationFixture {
    uint256 internal constant T0 = 1_762_650_000;
    uint32 internal constant FEED_AGE = 88_200;

    LensRegistryMock internal reg;
    LensStoreMock internal store;
    LensRiskModuleMock internal rm;
    LensLPOracleMock internal lpo;
    LensDebtOracleMock internal usdcOracle;
    LensCoverageMock internal ghoCov;
    LensCoverageMock internal usdcCov;
    LensFlashSourceMock internal flash;
    ProxyManager internal proxyManager;
    PayoutEscrow internal escrow;
    AaveAdapterLensMock internal adapterMock;
    LPVaultSwapLensMock internal swapMock;
    LensLPVaultMock internal vault;
    ILens internal lens;
    address[9] internal modules;
    address[9] internal core;
    address internal sizing;

    uint256 internal ghoAssetId;
    uint256 internal usdcAssetId;
    uint256 internal usdcReserveId;
    uint256 internal usdcLendReserveId;

    address internal feedUsdc = makeAddr("feed USDC/USD");
    address internal feedUsdt = makeAddr("feed USDT/USD");
    address internal feedUsdcDebt = makeAddr("feed USDC/USD debt");

    function _deployLens() internal {
        vm.warp(T0);
        vm.roll(1000);
        _deployCollateralization();
        vm.etch(address(lpVault), address(new LensLPVaultMock(INTEGRATION, address(coll), address(lock))).code);
        vault = LensLPVaultMock(address(lpVault));
        vm.etch(adapter, address(new AaveAdapterLensMock()).code);
        vm.etch(lpVaultSwap, address(new LPVaultSwapLensMock()).code);
        adapterMock = AaveAdapterLensMock(adapter);
        swapMock = LPVaultSwapLensMock(lpVaultSwap);
        reg = new LensRegistryMock();
        store = new LensStoreMock();
        rm = new LensRiskModuleMock();
        lpo = new LensLPOracleMock(address(vtPrice));
        flash = new LensFlashSourceMock();
        ghoCov = new LensCoverageMock();
        usdcCov = new LensCoverageMock();
        proxyManager = new ProxyManager(adapter, address(reg));
        escrow = new PayoutEscrow(lpVaultSwap, address(lock));
        adapterMock.setProxyManager(address(proxyManager));
        usdcOracle = new LensDebtOracleMock(0.9999e8, feedUsdcDebt, address(0));
        usdcOracle.setStore(address(store));
        _listUsdcDebt();
        _configureWorld();
        core = [
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
        sizing = deployCode("out-aave/LensAaveSizing.sol/LensAaveSizing.json");
        modules = _deployModules(core);
        lens = ILens(address(new Lens(modules)));
        vm.label(address(lens), "Lens");
    }

    function _deployModules(
        address[9] memory c
    ) internal returns (address[9] memory m) {
        m[0] = address(new LensAccountModule(c));
        m[1] = address(new LensMarketModule(c));
        m[2] = address(new LensPriceModule(c));
        m[3] = address(new LensLiquidationModule(c, sizing));
        m[4] = address(new LensRiskModule(c));
        m[5] = address(new LensPreviewModule(c));
        m[6] = address(new LensMarketsModule(c));
        m[7] = address(new LensPositionsModule(c));
        m[8] = address(new LensSpeedModule(c));
    }

    /// @dev USDC (the market's first pool token) as a debt reserve of the CDP Spoke, priced by its DebtOracle.
    function _listUsdcDebt() internal {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        bytes memory irData = abi.encode(uint16(9000), uint32(0), uint32(400), uint32(6000));
        ICollHubConfigurator hubCfg = ICollHubConfigurator(aave.hubConfigurator);
        ICollSpokeConfigurator spokeCfg = ICollSpokeConfigurator(aave.spokeConfigurator);
        vm.startPrank(aaveDao);
        usdcAssetId =
            hubCfg.addAssetWithDecimals(aave.hub, address(usdc), 6, aave.treasurySpoke, 0, aave.irStrategy, irData);
        hubCfg.addSpoke(aave.hub, aave.lendSpoke, usdcAssetId, CollHubSpokeConfig(maxCap, 0, maxRp, true, false));
        hubCfg.addSpoke(aave.hub, aave.cdpSpoke, usdcAssetId, CollHubSpokeConfig(0, 500_000, maxRp, true, false));
        usdcLendReserveId = spokeCfg.addReserve(
            aave.lendSpoke,
            aave.hub,
            usdcAssetId,
            address(usdcOracle),
            CollSpokeReserveConfig(0, false, false, true, false),
            CollSpokeDynamicReserveConfig(0, 10_000, 0)
        );
        usdcReserveId = spokeCfg.addReserve(
            aave.cdpSpoke,
            aave.hub,
            usdcAssetId,
            address(usdcOracle),
            CollSpokeReserveConfig(0, false, false, true, false),
            CollSpokeDynamicReserveConfig(0, 10_000, 0)
        );
        vm.stopPrank();
        usdc.mint(daoTreasury, 1_000_000e6);
        vm.startPrank(daoTreasury);
        ERC20(address(usdc)).approve(aave.lendSpoke, 1_000_000e6);
        IAaveV4Spoke(aave.lendSpoke).supply(usdcLendReserveId, 1_000_000e6, daoTreasury);
        vm.stopPrank();
        ghoAssetId = hubView.getAssetId(address(debt));
    }

    function _configureWorld() internal {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdc), address(usdt));
        uint8[] memory decs = new uint8[](2);
        (decs[0], decs[1]) = (6, 6);
        Market memory m;
        (m.chainId, m.hub, m.spoke, m.integrationId, m.integration) =
        (uint64(block.chainid), aave.hub, aave.cdpSpoke, INTEGRATION, address(lpVault));
        (m.pool, m.shape, m.tokens, m.tokenDecimals) = (pool, PositionShape(ShapeKind.TickRange, -50, 50), tokens, decs);
        (m.vaultToken, m.decimals, m.lpOracle, m.hubAssetId, m.reserveId) =
        (vt, VT_DECIMALS, address(lpo), vtAssetId, vtReserveId);
        m.status = MarketStatus.Active;
        reg.setMarket(MARKET_ID, m);
        reg.addSpoke(aave.cdpSpoke, aave.hub);
        reg.setDebtReserve(
            aave.cdpSpoke, _def(debtReserveId, address(debt), 18, ghoAssetId, address(debtPrice), true, ghoCov)
        );
        reg.setDebtReserve(
            aave.cdpSpoke, _def(usdcReserveId, address(usdc), 6, usdcAssetId, address(usdcOracle), false, usdcCov)
        );
        reg.setSettlementReserve(MARKET_ID, debtReserveId);
        reg.setFlashSource(address(flash));
        reg.setAvanaFirstLossReserve(aave.hub, address(debt), address(ghoCov));
        reg.setAvanaFirstLossReserve(aave.hub, address(usdc), address(usdcCov));
        reg.setCreditLine(aave.hub, address(debt), 2_000_000, 1_000_000, 0, 0);
        for (uint8 k = 0; k < 2; ++k) {
            reg.setRoute(MARKET_ID, address(usdc), address(debt), k, makeAddr("routeUsdcGho"), true);
            reg.setRoute(MARKET_ID, address(usdt), address(debt), k, makeAddr("routeUsdtGho"), true);
            reg.setRoute(MARKET_ID, address(usdt), address(usdc), k, makeAddr("routeUsdtUsdc"), true);
        }
        ghoCov.set(100_000e18, 100_000e18);
        usdcCov.set(50_000e6, 50_000e6);
        lpo.addToken(address(usdc), feedUsdc, address(0), uint64(T0 - 600), 1e8);
        lpo.addToken(address(usdt), feedUsdt, address(0), uint64(T0 - 600), 1e8);
        lpo.setAccepted(2e8, uint64(T0 - 600));
        store.setAges(feedUsdc, FEED_AGE, FEED_AGE);
        store.setAges(feedUsdt, FEED_AGE, FEED_AGE);
        store.setAges(feedUsdcDebt, 4200, 4200);
        store.setMarketParams(MARKET_ID, MarketParams(1800, 50, 100, 30, 0, 10e8, 0));
        store.setFloorRoundingAllowance(address(debt), 1e18);
        store.setFloorRoundingAllowance(address(usdc), 1e6);
        store.setCaps(MARKET_ID, 1_000_000e8, 100_000e8, 1e8);
        store.setTokenCap(aave.hub, address(usdc), 300_000e8);
        store.setTokenCap(aave.hub, address(usdt), 250_000e8);
        store.setDepositorCap(aave.hub, 500_000e8);
        swapMock.setKeeper(keeper, true, false);
        vault.setDepth(1e15, true);
    }

    function _def(
        uint256 reserveId,
        address asset,
        uint8 decimals,
        uint256 assetId,
        address source,
        bool fixedPrice,
        LensCoverageMock coverage
    ) internal view returns (DebtReserveDef memory d) {
        (d.reserveId, d.asset, d.decimals, d.fundingHub, d.hubAssetId) = (reserveId, asset, decimals, aave.hub, assetId);
        (d.priceSource, d.fixedPrice, d.firstLossReserve) = (source, fixedPrice, address(coverage));
    }

    // ─── Accounts ───

    /// @notice Binds `proxy` to `wallet` in the Adapter stand-in and pledges a position of `units` through the real
    /// Collateralization, supplying the minted vault tokens on the CDP Spoke as collateral.
    function _open(
        address wallet,
        address proxy,
        uint256 tokenId,
        uint128 units
    ) internal returns (uint256 recordId) {
        adapterMock.bind(wallet, proxy, aave.cdpSpoke, MARKET_ID, vt, vtReserveId);
        rm.setGate(proxy, true, false, PauseState.None);
        recordId = _pledge(wallet, proxy, _key(tokenId), units);
    }

    function _borrowUsdc(
        address proxy,
        uint256 amount
    ) internal {
        vm.prank(proxy);
        IAaveV4Spoke(aave.cdpSpoke).borrow(usdcReserveId, amount, proxy);
    }

    /// @notice Sets the vault-token price on Aave and the LPOracle stand-in together (8 decimals).
    function _setVtPrice(
        int256 price
    ) internal {
        vtPrice.set(price);
    }

    /// @notice Sets the GHO price on Aave (the fixed-price source of the fixture).
    function _setGhoPrice(
        int256 price
    ) internal {
        debtPrice.set(price);
    }

    /// @notice Sets the USDC DebtOracle's served answer, keeping it Live with the accepted price at `price`.
    function _setUsdcPrice(
        int256 price
    ) internal {
        usdcOracle.set(price, usdcOracle.state(), uint256(price), uint64(block.timestamp));
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

    /// @notice Holds the Lock as the Adapter for the rest of the test.
    function _holdLock() internal {
        vm.prank(adapter);
        lock.acquire();
    }

    function _releaseLock() internal {
        vm.prank(adapter);
        lock.release();
    }

    /// @notice One HubConfigurator call as the Aave DAO.
    function _hubConfig(
        bytes memory data
    ) internal {
        vm.prank(aaveDao);
        (bool ok, bytes memory ret) = aave.hubConfigurator.call(data);
        _bubble(ok, ret);
    }

    /// @notice One SpokeConfigurator call as the Aave DAO.
    function _spokeConfig(
        bytes memory data
    ) internal {
        vm.prank(aaveDao);
        (bool ok, bytes memory ret) = aave.spokeConfigurator.call(data);
        _bubble(ok, ret);
    }

    function _setDrawCap(
        uint256 assetId,
        address spoke,
        uint256 cap
    ) internal {
        _hubConfig(
            abi.encodeWithSignature(
                "updateSpokeDrawCap(address,uint256,address,uint256)", aave.hub, assetId, spoke, cap
            )
        );
    }

    function _setAddCap(
        uint256 assetId,
        address spoke,
        uint256 cap
    ) internal {
        _hubConfig(
            abi.encodeWithSignature("updateSpokeAddCap(address,uint256,address,uint256)", aave.hub, assetId, spoke, cap)
        );
    }

    function _setReservePaused(
        uint256 reserveId,
        bool paused
    ) internal {
        _spokeConfig(abi.encodeWithSignature("updatePaused(address,uint256,bool)", aave.cdpSpoke, reserveId, paused));
    }
}
