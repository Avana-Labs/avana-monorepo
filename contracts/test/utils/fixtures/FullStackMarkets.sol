// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleCL} from "../../../src/oracle/lp-oracle/LPOracleCL.sol";
import {InitParams} from "../../../src/oracle/lp-oracle/types/InitParams.sol";
import {FeedDef} from "../../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/MarketParams.sol";
import {MarketSpeedLimits} from "../../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {MarketDef} from "../../../src/types/MarketDef.sol";
import {OracleConfig} from "../../../src/types/OracleConfig.sol";
import {OracleRoute} from "../../../src/types/OracleRoute.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {TokenOracleConfig} from "../../../src/types/TokenOracleConfig.sol";
import {RegistryRouteMock} from "../mocks/MarketRegistryMocks.sol";
import {IClPool} from "./ClPoolFixture.sol";
import {
    CollHubSpokeConfig,
    CollSpokeDynamicReserveConfig,
    CollSpokeReserveConfig,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "./CollateralizationFixture.sol";
import {FullStackFixture} from "./FullStackFixture.sol";
import {LPOracleCLDeployer} from "./LPOracleCLFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FullStackMarkets
/// @notice Collateral markets of `FullStackFixture` listed and activated through the real MarketRegistry and
/// ParameterStore, each priced by its own real concentrated-liquidity LPOracle (also the AaveOracle source of its
/// vault-token reserve), and the borrower flows through the real AaveAdapter.
/// @dev `_addMarket(pool)` lists the full range of a USDC/USDT pool as market `marketCount + 1`: 6-decimal vault tokens
/// at $2.00 (one raw unit of each token per unit of liquidity), twapWindow 1,800 s, consistency tolerance 50 bps,
/// slippage 250 / 30 bps, pool risk factor 4,000, `minPledgeUsd` $10, caps $1,000,000 / slice $100,000 / floor $1.00,
/// Aave CF 3,000 (the expected `min(7,800, 7,500) × 40 %`), bonus 10,500, Hub add cap 2,000,000 vault tokens, and a
/// primary and a backup route (`RegistryRouteMock`, a stand-in for the swap routes) from each pool token into each
/// debt asset it is not.
abstract contract FullStackMarkets is FullStackFixture {
    uint32 internal constant POKE_FLOOR = 900_000;
    uint32 internal constant POKE_CEILING = 3_000_000;
    uint8 internal constant VT_DECIMALS = 6;
    uint16 internal constant VT_CF = 3000;
    uint40 internal constant VT_ADD_CAP = 2_000_000;
    uint256 internal constant DEADLINE_SLACK = 600;
    /// @dev 10,000 whole vault tokens, $20,000 at $2.00.
    uint128 internal constant UNITS = 10_000_000_000;

    struct MarketInfo {
        IClPool pool;
        address vaultToken;
        LPOracleCL oracle;
        uint256 assetId;
        uint256 reserveId;
    }

    mapping(uint256 marketId => MarketInfo) internal mkt;
    uint256 internal keyNonce;
    uint256 internal opNonce;

    // ─── Listing ───

    /// @dev Lists and activates the full range of `p` as the next market.
    function _addMarket(
        IClPool p
    ) internal returns (uint256 id) {
        id = registry.marketCount() + 1;
        MarketInfo storage m = mkt[id];
        m.pool = p;
        m.oracle = _deployOracle(id, p);
        m.vaultToken = _deployVaultToken(id, p, address(m.oracle));
        lpVault.prepare(id, _poolTokens(), _two(1e18, 1e18), VT_DECIMALS);
        _listMarket(p, m.vaultToken, address(m.oracle));
        _storeListing(id);
        _aaveListing(m);
        _routes(id);
        vm.prank(address(timelock));
        registry.activateMarket(id);
        vm.label(m.vaultToken, string.concat("VaultToken ", vm.toString(id)));
        vm.label(address(m.oracle), string.concat("LPOracle ", vm.toString(id)));
    }

    function _deployVaultToken(
        uint256 id,
        IClPool p,
        address oracle
    ) private returns (address vt) {
        (int24 lower, int24 upper) = _fullRange(p);
        string memory n = vm.toString(id);
        vm.prank(address(timelock));
        vt = vtFactory.deployVaultToken(
            V3,
            address(p),
            bytes32(0),
            PositionShape(ShapeKind.TickRange, lower, upper),
            aave.hub,
            aave.cdpSpoke,
            id,
            oracle,
            VT_DECIMALS,
            string.concat("Avana USDC/USDT ", n),
            string.concat("avUSDC-USDT-", n)
        );
    }

    function _listMarket(
        IClPool p,
        address vt,
        address oracle
    ) private {
        (int24 lower, int24 upper) = _fullRange(p);
        MarketDef memory d;
        (d.hub, d.spoke, d.integrationId, d.pool) = (aave.hub, aave.cdpSpoke, V3, address(p));
        d.shape = PositionShape(ShapeKind.TickRange, lower, upper);
        (d.vaultToken, d.lpOracle) = (vt, oracle);
        vm.prank(address(timelock));
        registry.listCollateralMarket(d);
    }

    function _deployOracle(
        uint256 id,
        IClPool p
    ) private returns (LPOracleCL o) {
        (int24 lower, int24 upper) = _fullRange(p);
        LPOracleCL impl = LPOracleCLDeployer.deploy(address(timelock), BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        InitParams memory ip;
        ip.timelock = address(timelock);
        ip.parameterStore = address(store);
        ip.marketRegistry = address(registry);
        ip.marketId = id;
        ip.integration = address(lpVault);
        ip.isUsdStable = new bool[](2);
        (ip.isUsdStable[0], ip.isUsdStable[1]) = (true, true);
        ip.description = "USDC/USDT LP / USD";
        ip.pokeMinGas = POKE_FLOOR;
        ip.config = _oracleConfig(id);
        // USDC/USDT at $1 on any tier lists its one-spacing range at d <= 16, so the pool's unit exponent is 0.
        ip.market = abi.encode(address(p), lower, upper, uint256(0));
        o = LPOracleCL(address(new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (ip)))));
    }

    /// @dev The configuration the ParameterStore serves the market's LPOracle (`getOracleConfig`), built from the
    /// store's feed definitions, tolerances and second sources and the registry's routes in force.
    function _oracleConfig(
        uint256 id
    ) internal view returns (OracleConfig memory c) {
        address[] memory toks = _poolTokens();
        c.marketId = id;
        c.tokens = new TokenOracleConfig[](2);
        for (uint256 i = 0; i < 2; ++i) {
            TokenOracleConfig memory t = c.tokens[i];
            t.token = toks[i];
            (address[] memory primary, address[] memory alternate,) = registry.activePriceRoutes(toks[i]);
            t.routes[0] = _route(primary);
            t.routes[1] = _route(alternate);
            t.feedAgreementToleranceBps = store.feedAgreementToleranceBps(toks[i]);
            t.secondSource = store.secondSource(toks[i]);
        }
        c.twapWindow = 1800;
        c.twapMinObservations = 151;
        c.consistencyToleranceBps = 50;
        c.maxQuoteChangeBps = 100;
        (c.usdBandLow, c.usdBandHigh) = (store.usdBandLow(), store.usdBandHigh());
        c.cachedWindow = store.cachedWindow();
        c.disagreementPauseMax = store.disagreementPauseMax();
        c.graceDuration = store.graceDuration();
    }

    function _route(
        address[] memory feeds
    ) private view returns (OracleRoute memory r) {
        r.legCount = uint8(feeds.length);
        for (uint256 i = 0; i < feeds.length; ++i) {
            FeedDef memory f = store.getFeed(feeds[i]);
            r.legs[i].aggregator = feeds[i];
            r.legs[i].decimals = f.decimals;
            r.legs[i].heartbeat = f.feedHeartbeat;
            r.legs[i].heartbeatMargin = uint16(f.heartbeatMargin);
            r.legs[i].feedDeviationThresholdBps = f.feedDeviationThresholdBps;
            r.legs[i].minAnswer = int128(f.minAnswer);
            r.legs[i].maxAnswer = f.maxAnswer > type(int128).max ? type(int128).max : int128(f.maxAnswer);
            r.legs[i].borrowPriceMaxAge = f.borrowPriceMaxAge;
            r.legs[i].liquidationPriceMaxAge = f.liquidationPriceMaxAge;
        }
    }

    /// @dev The ParameterStore's listing writes of a registered market.
    function _storeListing(
        uint256 id
    ) private {
        MarketParams memory p;
        // Slippage allowance 195: the largest the LIQ-I1 fee bound admits at minLB = 10,250 and a 20 % fee share.
        (p.twapWindow, p.consistencyToleranceBps, p.slippageAllowanceBps, p.slippageAllowanceMinBps) =
        (1800, 50, 195, 30);
        (p.poolRiskFactor, p.minPledgeUsd) = (4000, MIN_PLEDGE_USD);
        vm.startPrank(address(timelock));
        store.setInitialMarketParams(id, p);
        store.setInitialMarketCaps(id, 1_000_000e8, 100_000e8, 1e8);
        // Launch speed limits (IParameterStoreSpeed example): 6-hour window, 25 % per window.
        store.loosenMarketSpeedLimits(
            id, MarketSpeedLimits(21_600, 2500, 2500, 250_000e8, 2_500_000e8, 1_000_000e8, 10_000_000e8)
        );
        if (id == 1) {
            store.setInitialTokenCap(aave.hub, address(usdc), 10_000_000e8);
            store.setInitialTokenCap(aave.hub, address(usdt), 10_000_000e8);
        }
        vm.stopPrank();
    }

    /// @dev The Aave DAO's payload: the vault token as a Hub asset (the CDP Spoke and the fee receiver only) and the
    /// CDP Spoke's collateral reserve priced by the market's LPOracle.
    function _aaveListing(
        MarketInfo storage m
    ) private {
        uint24 maxRp = IAaveV4Hub(aave.hub).MAX_RISK_PREMIUM_THRESHOLD();
        vm.startPrank(aaveDao);
        m.assetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(
                aave.hub, m.vaultToken, VT_DECIMALS, aave.treasurySpoke, 0, aave.irStrategy, _irData()
            );
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, aave.cdpSpoke, m.assetId, CollHubSpokeConfig(VT_ADD_CAP, 0, maxRp, true, false));
        m.reserveId = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.cdpSpoke,
                aave.hub,
                m.assetId,
                address(m.oracle),
                CollSpokeReserveConfig(0, false, false, false, false),
                CollSpokeDynamicReserveConfig(VT_CF, 10_500, 0)
            );
        // The fee receiver is listed on the vault-token asset with no add cap (REQ-RISK drift: FeeReceiverAddCap).
        (bool ok,) = aave.hubConfigurator
            .call(
                abi.encodeWithSignature(
                    "updateSpokeAddCap(address,uint256,address,uint256)", aave.hub, m.assetId, aave.treasurySpoke, 0
                )
            );
        require(ok, "fee receiver add cap");
        vm.stopPrank();
    }

    /// @dev A primary and a backup route from each pool token into each debt asset other than itself.
    function _routes(
        uint256 id
    ) private {
        address[] memory toks = _poolTokens();
        address[2] memory debts = [address(gho), address(usdc)];
        for (uint256 i = 0; i < toks.length; ++i) {
            for (uint256 j = 0; j < debts.length; ++j) {
                if (toks[i] == debts[j]) continue;
                for (uint8 kind = 0; kind < 2; ++kind) {
                    address[] memory deps = _list(makeAddr(string.concat("dex ", vm.toString(kind))));
                    address route = address(new RegistryRouteMock(toks[i], debts[j], address(swap), deps));
                    vm.prank(address(timelock));
                    registry.setRoute(id, toks[i], debts[j], kind, route);
                }
            }
        }
    }

    // ─── Flows through the Adapter ───

    function _ref(
        bytes32 key
    ) internal pure returns (PositionRef memory) {
        return PositionRef(V3, key);
    }

    function _newKey() internal returns (bytes32 key) {
        key = keccak256(abi.encode("position", ++keyNonce));
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + DEADLINE_SLACK;
    }

    /// @dev Mints a position of `units` for `wallet` in `marketId` and pledges it through the Adapter.
    function _pledgeAs(
        address wallet,
        uint256 marketId,
        uint128 units
    ) internal returns (bytes32 key, address proxy) {
        key = _newKey();
        lpVault.mintPosition(key, wallet, marketId, units);
        vm.prank(wallet);
        (proxy,,) = adapterC.pledge(marketId, _ref(key), _deadline());
    }

    function _borrowAs(
        address wallet,
        uint256 marketId,
        uint256 reserveId,
        uint256 amount
    ) internal {
        address proxy = adapterC.proxyOf(wallet, marketId);
        uint256 nonce = adapterC.borrowNonce(proxy);
        vm.prank(wallet);
        adapterC.borrow(marketId, reserveId, amount, wallet, _deadline(), 0, nonce);
    }

    /// @dev Funds `payer` with `amount` of the reserve's asset and approves the Adapter for exactly that.
    function _fund(
        address payer,
        uint256 reserveId,
        uint256 amount
    ) internal {
        address asset = reserveId == usdcReserveId ? address(usdc) : address(gho);
        if (asset == address(usdc)) usdc.mint(payer, amount);
        else gho.mint(payer, amount);
        vm.prank(payer);
        ERC20(asset).approve(adapter, amount);
    }

    function _debtOf(
        address proxy,
        uint256 reserveId
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(reserveId, proxy);
    }

    function _hf(
        address proxy
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(proxy).healthFactor;
    }

    function _sharesOf(
        address proxy,
        uint256 reserveId
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(reserveId, proxy);
    }

    /// @dev The Emergency Guardian moves the Hub to `state` for `reason` (None unpauses and unfreezes).
    function _pause(
        PauseState state,
        PauseReason reason
    ) internal {
        vm.startPrank(emergencyGuardian);
        if (state == PauseState.Frozen) registry.freeze(aave.hub);
        else if (state == PauseState.Paused) registry.pause(aave.hub, reason);
        vm.stopPrank();
    }

    function _mins() internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
    }

    // ─── Governance ───

    /// @dev Schedules `data` on `target` through the real timelock at its required delay, waits it (republishing every
    /// feed so prices stay fresh) and executes it on the public path; returns the delay.
    function _govern(
        address target,
        bytes memory data
    ) internal returns (uint256 delay) {
        delay = _requiredDelay(target, data);
        bytes32 salt = bytes32(++opNonce);
        vm.prank(governanceMultisig);
        timelock.schedule(target, 0, data, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        vm.roll(block.number + delay / BLOCK_TIME);
        _refreshFeeds();
        vm.prank(attacker);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    function _requiredDelay(
        address target,
        bytes memory data
    ) internal view returns (uint256) {
        address[] memory t = new address[](1);
        t[0] = target;
        bytes[] memory p = new bytes[](1);
        p[0] = data;
        return timelock.requiredDelay(t, p);
    }

    // ─── Helpers ───

    function _poolTokens() internal view returns (address[] memory toks) {
        toks = new address[](2);
        (toks[0], toks[1]) =
            address(usdc) < address(usdt) ? (address(usdc), address(usdt)) : (address(usdt), address(usdc));
    }

    function _two(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory l) {
        l = new uint256[](2);
        (l[0], l[1]) = (a, b);
    }
}
