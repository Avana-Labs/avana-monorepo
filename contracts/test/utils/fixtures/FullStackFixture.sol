// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IDebtOracle} from "../../../src/oracle/debt-oracle/IDebtOracle.sol";
import {DebtOracleInitParams} from "../../../src/oracle/debt-oracle/types/DebtOracleInitParams.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IssuerProbe} from "../../../src/policy/market-registry/types/IssuerProbe.sol";
import {RiskTier} from "../../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../../src/policy/market-registry/types/SpokeDef.sol";
import {TokenDef} from "../../../src/policy/market-registry/types/TokenDef.sol";
import {DebtReserveParams} from "../../../src/policy/parameter-store/types/DebtReserveParams.sol";
import {FeedDef} from "../../../src/policy/parameter-store/types/FeedDef.sol";
import {SpeedLimit} from "../../../src/policy/parameter-store/types/SpeedLimit.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {FullStackCoverageSpokeMock} from "../mocks/FullStackLPVaultMock.sol";
import {OracleFeedMock} from "../mocks/LPOracleMocks.sol";
import {RegistryFlashSourceMock} from "../mocks/MarketRegistryMocks.sol";
import {ClTestToken, IClPool} from "./ClPoolFixture.sol";
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
import {FullStackDeploy} from "./FullStackDeploy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title FullStackFixture
/// @notice `FullStackDeploy` with the chain's listings done through the real contracts, as the listing payloads run
/// them: the Stable LP Hub recorded, integration 1 (Uniswap v3) registered and its contracts finalized, the standard CDP
/// Spoke recorded with its liquidation expectations, USDC and USDT listed with a one-leg primary, alternate and standby
/// route and an oracle-network second source each (8-decimal feeds at $1.00, heartbeat 86,400 s, margin 1,800 s, 25
/// bps deviation and drift), GHO listed for monitoring and enabled as a fixed-price debt reserve, and USDC enabled as a
/// debt reserve priced by its real DebtOracle (`debtStressRiseBps = 500`). Both debt assets are funded by the Hub
/// through the Lend Spoke (1,000,000 each, draw caps 1,000,000, credit lines 2,000,000).
/// @dev Markets come from `FullStackMarkets`. Stand-ins beyond `FullStackDeploy`, each named: the Coverage Spokes
/// (`FullStackCoverageSpokeMock`, funded) and the flash source (`RegistryFlashSourceMock`, 5 bps); Chainlink feeds are
/// `OracleFeedMock`s and GHO's fixed price a `CollPriceSource`.
abstract contract FullStackFixture is FullStackDeploy {
    uint32 internal constant FEED_AGE = 88_200;
    uint40 internal constant DEBT_DRAW_CAP = 1_000_000;
    uint256 internal constant CREDIT_LINE = 2_000_000;
    uint16 internal constant TOLERANCE_BPS = 150;
    uint16 internal constant USDC_CF = 7800;
    uint16 internal constant USDT_CF = 7500;

    ClTestToken internal usdc;
    ClTestToken internal usdt;
    ClTestToken internal gho;
    IClPool internal poolA;
    IClPool internal poolB;
    CollPriceSource internal ghoPrice;
    OracleFeedMock internal ghoFeed;
    IDebtOracle internal usdcOracle;
    RegistryFlashSourceMock internal flash;
    uint256 internal ghoAssetId;
    uint256 internal usdcAssetId;
    uint256 internal ghoReserveId;
    uint256 internal usdcReserveId;
    /// @dev Per pool token: primary, alternate, standby, second source.
    mapping(address token => OracleFeedMock[4] feeds) internal feedsOf;

    /// @dev Aave V4, two real Uniswap v3 USDC/USDT pools (0.01 % and 0.05 %), the core, the Spoke and both debt reserves.
    function _setUpFullStack() internal {
        vm.warp(T0 - 7200);
        vm.roll(100);
        _deployAaveV4();
        _deployPools();
        _deployCore();
        // The LPVault stand-in pays unwinds from its own float of each pool token.
        usdc.mint(address(lpVault), 1e30);
        usdt.mint(address(lpVault), 1e30);
        _recordSpoke();
        _listPoolToken(usdc, "USDC");
        _listPoolToken(usdt, "USDT");
        _enableGho();
        _enableUsdc();
    }

    // ─── Pools ───

    /// @dev Both pools are created two hours before `T0` at $1.00 per token, so their observation buffers cover the
    /// 1,800 s TWAP window at `T0`.
    function _deployPools() private {
        _deployFactory();
        (usdc, usdt,) = _sortedTokens("USDC", 6, "USDT", 6);
        (ClTestToken t0, ClTestToken t1) = address(usdc) < address(usdt) ? (usdc, usdt) : (usdt, usdc);
        poolA = _createPool(t0, t1, 100, 1e8, 1e8, 151, 1e15);
        poolB = _createPool(t0, t1, 500, 1e8, 1e8, 151, 1e15);
        vm.warp(T0 - 3600);
        _touch(poolA);
        _touch(poolB);
        vm.warp(T0);
        vm.roll(block.number + 300);
        gho = new ClTestToken("GHO", 18);
        vm.label(address(gho), "GHO");
    }

    // ─── Hub, integration and Spoke ───

    function _recordSpoke() private {
        address tl = address(timelock);
        flash = new RegistryFlashSourceMock(makeAddr("aaveV3Pool"), address(swap));
        address[] memory amm = new address[](2);
        (amm[0], amm[1]) = (address(factory), address(actor));
        vm.startPrank(tl);
        vtFactory.registerIntegration(V3, address(lpVault));
        registry.recordHub(aave.hub, RiskTier.Stable);
        registry.registerIntegration(V3, address(lpVault), makeAddr("clPricing"));
        registry.recordIntegrationContracts(V3, amm);
        registry.finalizeIntegrationContracts(V3);
        registry.setFlashSource(address(flash));
        registry.deployCdpSpoke(
            SpokeDef({
                approved: false,
                hub: aave.hub,
                integrationId: V3,
                riskTier: RiskTier.Stable,
                implementation: aave.cdpSpokeImplementation,
                aaveOracle: aave.cdpOracle
            })
        );
        store.setLiquidationExpectations(aave.cdpSpoke, TARGET_HEALTH_FACTOR, 200);
        store.setInitialHubCaps(aave.hub, DEPOSITOR_CAP);
        vm.stopPrank();
        vm.prank(aaveDao);
        ICollSpokeConfigurator(aave.spokeConfigurator)
            .updateLiquidationConfig(aave.cdpSpoke, CollSpokeLiquidationConfig(1.1e18, 0.95e18, 5000));
    }

    // ─── Tokens and feeds ───

    /// @dev An 8-decimal feed at `price`, published now, defined in the ParameterStore.
    function _feed(
        string memory label,
        uint256 price
    ) internal returns (OracleFeedMock f) {
        f = new OracleFeedMock(8, 1, 1e18);
        f.push(int256(price), block.timestamp);
        vm.label(address(f), label);
        vm.prank(address(timelock));
        store.setFeed(address(f), _feedDef());
    }

    function _feedDef() internal pure returns (FeedDef memory d) {
        d.feedHeartbeat = 86_400;
        d.heartbeatMargin = 1800;
        d.feedMaxAge = FEED_AGE;
        d.liquidationPriceMaxAge = FEED_AGE;
        d.borrowPriceMaxAge = FEED_AGE;
        d.feedDeviationThresholdBps = 25;
        d.heartbeatDriftBps = 25;
        d.maxAnswerCap = type(int256).max;
    }

    /// @dev Lists a USD stable pool token with its three routes, then its tolerance, second source and collateral
    /// factor in the ParameterStore.
    function _listPoolToken(
        ClTestToken token,
        string memory label
    ) private {
        OracleFeedMock p = _feed(string.concat(label, "/USD"), 1e8);
        OracleFeedMock a = _feed(string.concat(label, "/USD alternate"), 1e8);
        OracleFeedMock s = _feed(string.concat(label, "/USD standby"), 1e8);
        OracleFeedMock n = _feed(string.concat(label, "/USD second source"), 1e8);
        feedsOf[address(token)] = [p, a, s, n];
        TokenDef memory d;
        d.isUsdStable = true;
        d.primaryRoute = _list(address(p));
        d.alternateRoute = _list(address(a));
        d.standbyRoute = _list(address(s));
        d.replacedSlot = RouteSlot.None;
        d.issuerProbe = IssuerProbe.None;
        SecondSource memory none;
        vm.startPrank(address(timelock));
        registry.listToken(address(token), d);
        store.setFeedAgreementToleranceBps(address(token), TOLERANCE_BPS);
        store.setSecondSource(
            address(token), SecondSource(SecondSourceKind.OracleNetwork, address(n), bytes32(0), FEED_AGE, 0, 100), none
        );
        store.setTokenCollateralFactorBps(address(token), address(token) == address(usdc) ? USDC_CF : USDT_CF);
        vm.stopPrank();
    }

    /// @dev A new round at the current time on every route and the second source of `token`, at `price`, in the next
    /// block (an LPOracle caps its fair price's move from a price accepted in the same block, REQ-ORACLE-103).
    function _publish(
        address token,
        uint256 price
    ) internal {
        vm.roll(block.number + 1);
        OracleFeedMock[4] storage f = feedsOf[token];
        for (uint256 i = 0; i < 4; ++i) {
            f[i].push(int256(price), block.timestamp);
        }
    }

    /// @dev Every feed republished at the current time with its answer.
    function _refreshFeeds() internal {
        address[2] memory toks = [address(usdc), address(usdt)];
        for (uint256 t = 0; t < 2; ++t) {
            OracleFeedMock[4] storage f = feedsOf[toks[t]];
            for (uint256 i = 0; i < 4; ++i) {
                f[i].push(f[i].answer(), block.timestamp);
            }
        }
        ghoFeed.push(ghoFeed.answer(), block.timestamp);
    }

    // ─── Debt reserves ───

    /// @dev GHO: monitoring listing, Hub asset lent through the Lend Spoke, a borrowable CDP reserve at a fixed $1.00.
    function _enableGho() private {
        ghoFeed = _feed("GHO/USD", 1e8);
        TokenDef memory d;
        d.primaryRoute = _list(address(ghoFeed));
        vm.prank(address(timelock));
        registry.listToken(address(gho), d);
        ghoPrice = new CollPriceSource(1e8);
        (ghoAssetId, ghoReserveId) = _addDebtAsset(gho, 18, address(ghoPrice));
        FullStackCoverageSpokeMock cs = _coverage(address(gho), ghoAssetId);
        _enableDebt(
            DebtReserveDef({
                reserveId: ghoReserveId,
                asset: address(gho),
                decimals: 18,
                fundingHub: aave.hub,
                hubAssetId: ghoAssetId,
                priceSource: address(ghoPrice),
                fixedPrice: true,
                coverageSpoke: address(cs),
                crossHub: false,
                approved: false
            }),
            FLOOR_ROUNDING_ALLOWANCE_GHO
        );
    }

    /// @dev USDC (the pools' own token): its DebtOracle, then the Hub asset and a CDP reserve priced by it.
    function _enableUsdc() private {
        vm.prank(address(timelock));
        store.tightenDebtStressRiseBps(address(usdc), 500);
        IDebtOracle impl = IDebtOracle(deployCode("DebtOracle.sol:DebtOracle", abi.encode(address(timelock))));
        DebtOracleInitParams memory p = DebtOracleInitParams({
            timelock: address(timelock),
            asset: address(usdc),
            marketRegistry: address(registry),
            parameterStore: address(store),
            description: "USDC / USD",
            pokeMinGas: 600_000
        });
        usdcOracle = IDebtOracle(address(new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (p)))));
        vm.label(address(usdcOracle), "DebtOracle USDC");
        (usdcAssetId, usdcReserveId) = _addDebtAsset(usdc, 6, address(usdcOracle));
        FullStackCoverageSpokeMock cs = _coverage(address(usdc), usdcAssetId);
        _enableDebt(
            DebtReserveDef({
                reserveId: usdcReserveId,
                asset: address(usdc),
                decimals: 6,
                fundingHub: aave.hub,
                hubAssetId: usdcAssetId,
                priceSource: address(usdcOracle),
                fixedPrice: false,
                coverageSpoke: address(cs),
                crossHub: false,
                approved: false
            }),
            FLOOR_ROUNDING_ALLOWANCE_USDC
        );
    }

    /// @dev The asset on the Hub with the Lend Spoke supplying 1,000,000 whole tokens and the CDP Spoke drawing up to
    /// `DEBT_DRAW_CAP`, and its borrowable CDP reserve priced by `source`.
    function _addDebtAsset(
        ClTestToken asset,
        uint8 dec,
        address source
    ) private returns (uint256 assetId, uint256 reserveId) {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        ICollHubConfigurator hubCfg = ICollHubConfigurator(aave.hubConfigurator);
        ICollSpokeConfigurator spokeCfg = ICollSpokeConfigurator(aave.spokeConfigurator);
        CollPriceSource lendPrice = new CollPriceSource(1e8);
        vm.startPrank(aaveDao);
        assetId = hubCfg.addAssetWithDecimals(
            aave.hub, address(asset), dec, aave.treasurySpoke, 0, aave.irStrategy, _irData()
        );
        hubCfg.addSpoke(aave.hub, aave.lendSpoke, assetId, CollHubSpokeConfig(maxCap, 0, maxRp, true, false));
        hubCfg.addSpoke(aave.hub, aave.cdpSpoke, assetId, CollHubSpokeConfig(0, DEBT_DRAW_CAP, maxRp, true, false));
        uint256 lendReserve = spokeCfg.addReserve(
            aave.lendSpoke,
            aave.hub,
            assetId,
            address(lendPrice),
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
        vm.stopPrank();
        uint256 amount = 1_000_000 * 10 ** dec;
        asset.mint(daoTreasury, amount);
        vm.startPrank(daoTreasury);
        asset.approve(aave.lendSpoke, amount);
        IAaveV4Spoke(aave.lendSpoke).supply(lendReserve, amount, daoTreasury);
        vm.stopPrank();
    }

    function _coverage(
        address asset,
        uint256 assetId
    ) private returns (FullStackCoverageSpokeMock cs) {
        cs = new FullStackCoverageSpokeMock(aave.hub, asset, assetId, 100_000 * 10 ** ClTestToken(asset).decimals());
        cs.setFunded(1e40, false);
        vm.startPrank(address(timelock));
        registry.setCoverageSpoke(aave.hub, asset, address(cs));
        registry.recordCreditLine(aave.hub, asset, CREDIT_LINE);
        vm.stopPrank();
    }

    function _enableDebt(
        DebtReserveDef memory def,
        uint256 floorRounding
    ) private {
        vm.startPrank(address(timelock));
        registry.enableDebtReserve(aave.cdpSpoke, def);
        store.setDebtAssetParams(def.asset, DebtReserveParams(floorRounding));
        // Launch borrow-speed limit (IParameterStoreSpeed example for GHO), in the asset's units.
        uint96 unit = uint96(10 ** def.decimals);
        store.loosenDebtSpeedLimit(aave.hub, def.asset, SpeedLimit(2500, 21_600, 500_000 * unit, 5_000_000 * unit));
        vm.stopPrank();
    }

    function _irData() internal pure returns (bytes memory) {
        return abi.encode(CollInterestRateData(9000, 0, 400, 6000));
    }

    function _list(
        address a
    ) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    /// @dev Full range of the pool's tick spacing.
    function _fullRange(
        IClPool p
    ) internal view returns (int24 lower, int24 upper) {
        int24 s = p.tickSpacing();
        // forge-lint: disable-next-line(divide-before-multiply)
        upper = (ClPriceMath.MAX_TICK / s) * s;
        lower = -upper;
    }
}
