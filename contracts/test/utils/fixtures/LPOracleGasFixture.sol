// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../../src/oracle/lp-oracle/ILPOracle.sol";
import {InitParams} from "../../../src/oracle/lp-oracle/types/InitParams.sol";
import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreAdmin} from "../../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {ParameterStore} from "../../../src/policy/parameter-store/ParameterStore.sol";
import {ParameterStoreAdminOracleLogic} from "../../../src/policy/parameter-store/ParameterStoreAdminOracleLogic.sol";
import {ParameterStoreAdminRiskLogic} from "../../../src/policy/parameter-store/ParameterStoreAdminRiskLogic.sol";
import {ParameterStoreListingLogic} from "../../../src/policy/parameter-store/ParameterStoreListingLogic.sol";
import {ParameterStoreLoosenLogic} from "../../../src/policy/parameter-store/ParameterStoreLoosenLogic.sol";
import {ParameterStoreTightenLogic} from "../../../src/policy/parameter-store/ParameterStoreTightenLogic.sol";
import {FeedDef} from "../../../src/policy/parameter-store/types/FeedDef.sol";
import {ParameterStoreLogics} from "../../../src/policy/parameter-store/types/ParameterStoreLogics.sol";
import {Market} from "../../../src/types/Market.sol";
import {OracleConfig} from "../../../src/types/OracleConfig.sol";
import {OracleLeg} from "../../../src/types/OracleLeg.sol";
import {OracleRoute} from "../../../src/types/OracleRoute.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {TokenOracleConfig} from "../../../src/types/TokenOracleConfig.sol";
import {VaultTokenBindings} from "../../../src/types/VaultTokenBindings.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {LPOracleHarness, LPOracleHarnessDeployer} from "../harness/LPOracleHarness.sol";
import {EacProxyMock, OcrAggregatorMock} from "../mocks/ChainlinkCostMocks.sol";
import {GasMarketRegistry} from "../mocks/GasMarketRegistry.sol";
import {OracleTokenMock} from "../mocks/LPOracleMocks.sol";
import {MockMarketRegistry} from "../mocks/MockMarketRegistry.sol";
import {MockCollateralization} from "../mocks/ParameterStoreMocks.sol";
import {AaveV4Fixture} from "./AaveV4Fixture.sol";
import {ParameterStoreFixture} from "./ParameterStoreFixture.sol";
import {TimelockLaunchLists} from "./TimelockLaunchLists.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Hub `SpokeConfig` of aave-v4 a3ef63e.
struct GasHubSpokeConfig {
    uint40 addCap;
    uint40 drawCap;
    uint24 riskPremiumThreshold;
    bool active;
    bool halted;
}

/// @dev Spoke `ReserveConfig` of aave-v4 a3ef63e.
struct GasReserveConfig {
    uint24 collateralRisk;
    bool paused;
    bool frozen;
    bool borrowable;
    bool receiveSharesEnabled;
}

/// @dev Spoke `DynamicReserveConfig` of aave-v4 a3ef63e.
struct GasDynamicReserveConfig {
    uint16 collateralFactor;
    uint32 maxLiquidationBonus;
    uint16 liquidationFee;
}

/// @dev Spoke `LiquidationConfig` of aave-v4 a3ef63e.
struct GasLiquidationConfig {
    uint128 targetHealthFactor;
    uint64 healthFactorForMaxBonus;
    uint16 liquidationBonusFactor;
}

/// @dev `AssetInterestRateStrategy.InterestRateData` of aave-v4 a3ef63e.
struct GasInterestRateData {
    uint16 optimalUsageRatio;
    uint32 baseDrawnRate;
    uint32 rateGrowthBeforeOptimal;
    uint32 rateGrowthAfterOptimal;
}

interface IGasHubConfigurator {
    function addAssetWithDecimals(
        address hub,
        address underlying,
        uint8 decimals,
        address feeReceiver,
        uint256 liquidityFee,
        address irStrategy,
        bytes calldata irData
    ) external returns (uint256);
    function addSpoke(
        address hub,
        address spoke,
        uint256 assetId,
        GasHubSpokeConfig calldata config
    ) external;
}

interface IGasSpokeConfigurator {
    function addReserve(
        address spoke,
        address hub,
        uint256 assetId,
        address priceSource,
        GasReserveConfig calldata config,
        GasDynamicReserveConfig calldata dynamicConfig
    ) external returns (uint256);
    function updateLiquidationConfig(
        address spoke,
        GasLiquidationConfig calldata config
    ) external;
}

interface IGasAaveOracle {
    function getReservePrice(
        uint256 reserveId
    ) external view returns (uint256);
}

/// @notice 18-decimal debt asset with an open mint.
contract GasDebtAsset is ERC20 {
    constructor() ERC20("Debt", "DEBT") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @title LPOracleGasFixture
/// @notice Worst-case supported price-read setting for the LPOracle gas benchmarks: the real Aave V4 (pinned release)
/// with the standard CDP Spoke at its per-account limit of 4 reserves of each kind, the real ParameterStore, a
/// MarketRegistry with the real registry's route-view storage reads behind an ERC-1967 proxy, the LPOracle (base
/// harness module) as the price source of the vault-token reserve, and Chainlink-cost feeds (EACAggregatorProxy over
/// an OCR2 aggregator) for every leg, second source and debt reserve.
/// @dev Market: USDC/USDT, 6 decimals each, one raw unit of each per vault-token unit (`d = 6`, about $2.00 per whole
/// vault token). Each token has a one-leg primary (`TOKEN/USD`), a two-leg alternate (`TOKEN/ETH × ETH/USD`, a separate
/// ETH/USD aggregator per token), a two-leg standby recorded for the primary slot and an oracle-network second source.
/// The account (a pranked PositionProxy) holds 5,000 whole vault tokens ($10,000, CF 80 %) and borrows $1,000 of each
/// of the 4 debt reserves, so every health-factor computation prices 1 collateral and 4 debt reserves. The AaveAdapter
/// and LPVaultSwap are pranked addresses (`AaveAdapter` and `LPVaultSwap` are not written yet); `_avanaHook` is where
/// their pre-flow calls (`poke`, `getPriceState`) go once they exist.
abstract contract LPOracleGasFixture is AaveV4Fixture, ParameterStoreFixture {
    enum Scenario {
        Live,
        Alternate,
        Cached,
        SecondSourceDisagrees
    }

    uint256 internal constant T_START = 1_750_000_000;
    uint32 internal constant MAX_AGE = 88_200;
    uint256 internal constant DEBT_COUNT = 4;
    uint256 internal constant UNITS = 5_000_000_000;
    uint256 internal constant DEBT_EACH = 1000e18;
    uint32 internal constant FLOOR = 556_588;
    uint32 internal constant CEILING = 3_000_000;

    LPOracleHarness internal oracle;
    GasMarketRegistry internal gasRegistry;
    VaultToken internal vt;
    address internal adapter = makeAddr("aaveAdapter");
    address internal liquidator = makeAddr("lpVaultSwapProxy");
    address internal positionProxy = makeAddr("positionProxy");

    // Legs: [0] USDC/USD, [1] USDC/ETH, [2] ETH/USD (USDC alternate), [3] USDT/USD, [4] USDT/ETH, [5] ETH/USD (USDT
    // alternate), [6] USDC/ETH standby, [7] ETH/USD standby (USDC), [8] USDT/ETH standby, [9] ETH/USD standby (USDT),
    // [10] USDC second source, [11] USDT second source.
    EacProxyMock[12] internal legs;
    GasDebtAsset[DEBT_COUNT] internal debts;
    EacProxyMock[DEBT_COUNT] internal debtPrices;
    uint256[DEBT_COUNT] internal debtReserveIds;
    uint256 internal vtReserveId;

    // ─── Setup ───

    function _setUpGas(
        bool hasSequencer,
        uint32 floor
    ) internal {
        vm.warp(T_START);
        vm.roll(1000);
        _deployAaveV4();
        _deployGasStore(hasSequencer);
        _deployFeeds();
        _configureStore();
        oracle = _deployOracle(floor);
        _listOnAave();
        _openPosition();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    /// @dev `ParameterStoreFixture._deployStore` with the gas-faithful registry behind a proxy.
    function _deployGasStore(
        bool hasSequencer
    ) internal {
        gasRegistry = GasMarketRegistry(address(new ERC1967Proxy(address(new GasMarketRegistry()), "")));
        registry = MockMarketRegistry(address(gasRegistry));
        collateralization = new MockCollateralization();
        registry.setCollateralization(address(collateralization));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 7);
        timelock = _newTimelock(
            NORMAL_DELAY,
            true,
            TimelockLaunchLists.shortEligible(predicted, makeAddr("registryTarget"), makeAddr("swapTarget")),
            TimelockLaunchLists.daoOnlyCancel(makeAddr("registryTarget"), makeAddr("swapTarget"))
        );
        address t = address(timelock);
        address r = address(registry);
        logics = ParameterStoreLogics({
            tighten: address(new ParameterStoreTightenLogic(t, r, BLOCK_TIME, hasSequencer)),
            loosen: address(new ParameterStoreLoosenLogic(t, r, BLOCK_TIME, hasSequencer)),
            listing: address(new ParameterStoreListingLogic(t, r, BLOCK_TIME, hasSequencer)),
            adminOracle: address(new ParameterStoreAdminOracleLogic(t, r, BLOCK_TIME, hasSequencer)),
            adminRisk: address(new ParameterStoreAdminRiskLogic(t, r, BLOCK_TIME, hasSequencer))
        });
        implementation = new ParameterStore(t, r, BLOCK_TIME, hasSequencer, logics);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(IParameterStoreAdmin.initialize, (t, _launchGlobals(), 0, 10_000))
        );
        require(address(proxy) == predicted, "prediction");
        store = IParameterStore(address(proxy));
        _deployWorld();
        _etchToken(usdc);
        _etchToken(usdt);
    }

    function _deployFeeds() internal {
        uint256 at = block.timestamp - 600;
        legs[0] = _eac(8, 1e6, 1e12, 1e8, at);
        legs[1] = _eac(18, 1e10, 1e17, 2.5e14, at);
        legs[2] = _eac(8, 1e8, 1e13, 4000e8, at);
        legs[3] = _eac(8, 1e6, 1e12, 1e8, at);
        legs[4] = _eac(18, 1e10, 1e17, 2.5e14, at);
        legs[5] = _eac(8, 1e8, 1e13, 4000e8, at);
        legs[6] = _eac(18, 1e10, 1e17, 2.5e14, at);
        legs[7] = _eac(8, 1e8, 1e13, 4000e8, at);
        legs[8] = _eac(18, 1e10, 1e17, 2.5e14, at);
        legs[9] = _eac(8, 1e8, 1e13, 4000e8, at);
        legs[10] = _eac(8, 1e6, 1e12, 1e8, at);
        legs[11] = _eac(8, 1e6, 1e12, 1e8, at);
        for (uint256 i = 0; i < DEBT_COUNT; ++i) {
            debtPrices[i] = _eac(8, 1e6, 1e12, 1e8, at);
        }
        registry.setToken(
            usdc,
            _one(address(legs[0])),
            _two(address(legs[1]), address(legs[2])),
            _two(address(legs[6]), address(legs[7]))
        );
        registry.setToken(
            usdt,
            _one(address(legs[3])),
            _two(address(legs[4]), address(legs[5])),
            _two(address(legs[8]), address(legs[9]))
        );
    }

    function _configureStore() internal {
        vm.startPrank(address(timelock));
        store.setFeedAgreementToleranceBps(usdc, 150);
        store.setFeedAgreementToleranceBps(usdt, 150);
        for (uint256 i = 0; i < legs.length; ++i) {
            store.setFeed(address(legs[i]), _feedDef(86_400, 1800));
        }
        store.setTokenCollateralFactorBps(usdc, 7800);
        store.setTokenCollateralFactorBps(usdt, 7500);
        store.setInitialMarketParams(M, _launchMarketParams());
        SecondSource memory empty;
        store.setSecondSource(usdc, _secondSource(address(legs[10])), empty);
        store.setSecondSource(usdt, _secondSource(address(legs[11])), empty);
        vm.stopPrank();
    }

    function _deployOracle(
        uint32 floor
    ) internal returns (LPOracleHarness o) {
        LPOracleHarness impl = LPOracleHarnessDeployer.deploy(address(timelock), BLOCK_TIME, floor, CEILING, false);
        o = LPOracleHarness(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (_initParams(floor)))))
        );
        Market memory m = registry.getMarket(M);
        m.lpOracle = address(o);
        registry.setMarket(M, m);
        vm.label(address(o), "LPOracle");
    }

    function _listOnAave() internal {
        vt = new VaultToken(
            VaultTokenBindings({
                marketKey: keccak256("avana.gas.market.usdc-usdt"),
                integrationId: 1,
                integration: makeAddr("lpVault"),
                hub: aave.hub,
                spoke: aave.cdpSpoke,
                marketId: M,
                lpOracle: address(oracle),
                adapter: adapter,
                lpVaultSwap: liquidator,
                collateralization: makeAddr("collateralizationAddr"),
                decimals: 6,
                name: "Avana USDC/USDT",
                symbol: "avUSDC-USDT"
            })
        );
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        bytes memory irData = abi.encode(GasInterestRateData(9000, 0, 400, 6000));
        IGasHubConfigurator hubCfg = IGasHubConfigurator(aave.hubConfigurator);
        IGasSpokeConfigurator spokeCfg = IGasSpokeConfigurator(aave.spokeConfigurator);
        uint256[DEBT_COUNT] memory lendIds;
        vm.startPrank(aaveDao);
        for (uint256 i = 0; i < DEBT_COUNT; ++i) {
            debts[i] = new GasDebtAsset();
            uint256 assetId = hubCfg.addAssetWithDecimals(
                aave.hub, address(debts[i]), 18, aave.treasurySpoke, 0, aave.irStrategy, irData
            );
            hubCfg.addSpoke(aave.hub, aave.lendSpoke, assetId, GasHubSpokeConfig(maxCap, 0, maxRp, true, false));
            hubCfg.addSpoke(aave.hub, aave.cdpSpoke, assetId, GasHubSpokeConfig(0, 1_000_000, maxRp, true, false));
            lendIds[i] = spokeCfg.addReserve(
                aave.lendSpoke,
                aave.hub,
                assetId,
                address(debtPrices[i]),
                GasReserveConfig(0, false, false, true, false),
                GasDynamicReserveConfig(0, 10_000, 0)
            );
            debtReserveIds[i] = spokeCfg.addReserve(
                aave.cdpSpoke,
                aave.hub,
                assetId,
                address(debtPrices[i]),
                GasReserveConfig(0, false, false, true, false),
                GasDynamicReserveConfig(0, 10_000, 0)
            );
        }
        uint256 vtAssetId =
            hubCfg.addAssetWithDecimals(aave.hub, address(vt), 6, aave.treasurySpoke, 0, aave.irStrategy, irData);
        hubCfg.addSpoke(aave.hub, aave.cdpSpoke, vtAssetId, GasHubSpokeConfig(5_500_000, 0, maxRp, true, false));
        vtReserveId = spokeCfg.addReserve(
            aave.cdpSpoke,
            aave.hub,
            vtAssetId,
            address(oracle),
            GasReserveConfig(0, false, false, false, false),
            GasDynamicReserveConfig(8000, 10_500, 0)
        );
        spokeCfg.updateLiquidationConfig(aave.cdpSpoke, GasLiquidationConfig(1.1e18, 0.95e18, 5000));
        vm.stopPrank();
        for (uint256 i = 0; i < DEBT_COUNT; ++i) {
            debts[i].mint(daoTreasury, 100_000e18);
            vm.startPrank(daoTreasury);
            debts[i].approve(aave.lendSpoke, 100_000e18);
            IAaveV4Spoke(aave.lendSpoke).supply(lendIds[i], 100_000e18, daoTreasury);
            vm.stopPrank();
        }
    }

    function _openPosition() internal {
        vm.startPrank(adapter);
        vt.addValidProxy(positionProxy);
        vt.mint(positionProxy, UNITS);
        vm.stopPrank();
        vm.startPrank(positionProxy);
        vt.approve(aave.cdpSpoke, UNITS);
        IAaveV4Spoke(aave.cdpSpoke).supply(vtReserveId, UNITS, positionProxy);
        IAaveV4Spoke(aave.cdpSpoke).setUsingAsCollateral(vtReserveId, true, positionProxy);
        for (uint256 i = 0; i < DEBT_COUNT; ++i) {
            IAaveV4Spoke(aave.cdpSpoke).borrow(debtReserveIds[i], DEBT_EACH, positionProxy);
        }
        vm.stopPrank();
    }

    // ─── Scenarios ───

    /// @dev Moves the feeds into `s`, at the current block time.
    function _scenario(
        Scenario s
    ) internal {
        if (s == Scenario.Alternate) {
            // USDC's primary is past its feed age: USDC is quoted from its two-leg alternate.
            _round(0, 1e8, block.timestamp - 90_000);
        } else if (s == Scenario.Cached) {
            // Both USDT routes went Stale 100 s ago: the market is failed and Cached on the accepted price.
            uint256 at = block.timestamp - MAX_AGE - 100;
            _round(3, 1e8, at);
            _round(4, 2.5e14, at);
            _round(5, 4000e8, at);
        } else if (s == Scenario.SecondSourceDisagrees) {
            // USDC's second source is 5 % below the quote (tolerance 1 %): borrowing is blocked, the price is not.
            _round(10, 0.95e8, block.timestamp - 600);
        }
    }

    /// @dev Raises debt reserve 0's price to $6, so the account's health factor falls to about 0.89.
    function _makeLiquidatable() internal {
        debtPrices[0].setRound(6e8, uint32(block.timestamp));
    }

    /// @dev Hook for the Avana layer's pre-flow reads (AaveAdapter / RiskModule / LPVaultSwap call `poke()` and
    /// `getPriceState()` before the Aave call). Empty until those contracts exist.
    function _avanaHook() internal virtual {}

    // ─── Helpers ───

    function _round(
        uint256 leg,
        int192 answer,
        uint256 at
    ) internal {
        legs[leg].setRound(answer, uint32(at));
    }

    function _eac(
        uint8 dec,
        int192 lo,
        int192 hi,
        int192 answer,
        uint256 at
    ) internal returns (EacProxyMock p) {
        OcrAggregatorMock agg = new OcrAggregatorMock(dec, lo, hi);
        agg.setRound(answer, uint32(at));
        p = new EacProxyMock(agg);
    }

    function _two(
        address a,
        address b
    ) internal pure returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (a, b);
    }

    function _etchToken(
        address token
    ) internal {
        vm.etch(token, address(new OracleTokenMock(6)).code);
        vm.store(token, bytes32(uint256(1)), bytes32(uint256(6)));
    }

    function _secondSource(
        address source
    ) internal pure returns (SecondSource memory s) {
        s = SecondSource(SecondSourceKind.OracleNetwork, source, bytes32(0), MAX_AGE, 0, 100);
    }

    function _leg(
        address feed,
        uint8 dec,
        int128 lo,
        int128 hi
    ) internal pure returns (OracleLeg memory) {
        return OracleLeg(feed, dec, 86_400, 1800, 25, lo, hi, MAX_AGE, MAX_AGE);
    }

    function _oracleConfig() internal view returns (OracleConfig memory c) {
        c.marketId = M;
        c.twapWindow = 1800;
        c.twapMinObservations = 151;
        c.consistencyToleranceBps = 50;
        c.maxQuoteChangeBps = 100;
        c.usdBandLow = 0.9e8;
        c.usdBandHigh = 1.02e8;
        c.cachedWindow = 3600;
        c.disagreementPauseMax = 3600;
        c.graceDuration = 1800;
        c.tokens = new TokenOracleConfig[](2);
        for (uint256 i = 0; i < 2; ++i) {
            TokenOracleConfig memory t = c.tokens[i];
            uint256 b = 3 * i;
            t.token = i == 0 ? usdc : usdt;
            t.routes[0].legCount = 1;
            t.routes[0].legs[0] = _leg(address(legs[b]), 8, 1e6, 1e12);
            t.routes[1].legCount = 2;
            t.routes[1].legs[0] = _leg(address(legs[b + 1]), 18, 1e10, 1e17);
            t.routes[1].legs[1] = _leg(address(legs[b + 2]), 8, 1e8, 1e13);
            t.feedAgreementToleranceBps = 150;
            t.secondSource = _secondSource(address(legs[10 + i]));
        }
    }

    function _initParams(
        uint32 pokeMinGas_
    ) internal view returns (InitParams memory p) {
        p.timelock = address(timelock);
        p.parameterStore = address(store);
        p.marketRegistry = address(registry);
        p.marketId = M;
        p.integration = address(integration);
        p.isUsdStable = new bool[](2);
        (p.isUsdStable[0], p.isUsdStable[1]) = (true, true);
        p.description = "USDC/USDT / USD";
        p.pokeMinGas = pokeMinGas_;
        p.config = _oracleConfig();
        uint256[] memory k = new uint256[](2);
        (k[0], k[1]) = (1e18, 1e18);
        p.market = abi.encode(k);
    }
}
