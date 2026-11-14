// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {LiquidationParams} from "../../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {IDebtOracle} from "../../../src/oracle/debt-oracle/IDebtOracle.sol";
import {DebtOracleInitParams} from "../../../src/oracle/debt-oracle/types/DebtOracleInitParams.sol";
import {RepayWithCollateralParams} from "../../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IssuerProbe} from "../../../src/policy/market-registry/types/IssuerProbe.sol";
import {TokenDef} from "../../../src/policy/market-registry/types/TokenDef.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {OracleFeedMock} from "../mocks/LPOracleMocks.sol";
import {ClTestToken, IClPool} from "./ClPoolFixture.sol";
import {FullStackMarkets} from "./FullStackMarkets.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title RealStackFlows
/// @notice `FullStackMarkets` on the real stack: every Avana contract and every Aave V4 contract is the real one,
/// deployed and listed as the listing payloads do it. The chain's MarketRegistry, ParameterStore, RiskModule,
/// AaveAdapter, LPVaultSwap (router and three logic contracts), Collateralization, Lock, VaultTokenFactory, vault
/// tokens, ProxyManager and PositionProxies, PayoutEscrow, AvanaFirstLossReserves, AaveV3FlashSource, FlashLiquidator,
/// Lens, the markets' LPOracleCLs, the USDC DebtOracle, the Uniswap v3 LPVault on the real NonfungiblePositionManager,
/// real Uniswap v3 pools and real `DexPathRoute` swap routes. Wallet-level flows call the real AaveAdapter or
/// LPVaultSwap as the wallet, payer or caller would.
/// @dev Stand-ins left, each external to Avana and Aave V4: the Chainlink feeds (`OracleFeedMock`), GHO's fixed price
/// (`CollPriceSource`) and the Aave V3 Pool lending the flash paths (`MockAaveV3Pool`, 5 bps). A price move is a new
/// round on every feed of a token (`_publish`), the route-DEX pools swapped to the new rates (`_alignRoutes`), then a
/// poke of each market's LPOracle so Aave reads it.
abstract contract RealStackFlows is FullStackMarkets {
    /// @dev WETH's listing price, 8 decimals.
    uint256 internal constant WETH_PRICE = 3000e8;
    /// @dev WETH's floor rounding allowance: 0.0003 WETH ($0.90, within the $1.00 bound at $3,000).
    uint256 internal constant FLOOR_ROUNDING_ALLOWANCE_WETH = 3e14;

    ClTestToken internal weth;
    IDebtOracle internal wethOracle;
    uint256 internal wethAssetId;
    uint256 internal wethReserveId;

    function _realStack() internal pure override returns (bool) {
        return true;
    }

    /// @dev A route-DEX pool starts at its tokens' published prices (GHO and a token without feeds at $1.00).
    function _routeStartPrice(
        address token
    ) internal view override returns (uint256) {
        if (address(feedsOf[token][0]) == address(0)) return 1e8;
        return uint256(feedsOf[token][0].answer());
    }

    // ─── Listing beyond the fixture ───

    /// @notice Lists `token` as the fixture lists USDC and USDT: a primary, alternate and standby one-leg route and an
    /// oracle-network second source, each an 8-decimal feed at `price8` defined in the ParameterStore, and the launch
    /// feed-agreement tolerance.
    function _listPricedToken(
        ClTestToken token,
        string memory label,
        uint256 price8,
        bool usdStable
    ) internal {
        OracleFeedMock p = _feed(string.concat(label, "/USD"), price8);
        OracleFeedMock a = _feed(string.concat(label, "/USD alternate"), price8);
        OracleFeedMock st = _feed(string.concat(label, "/USD standby"), price8);
        OracleFeedMock n = _feed(string.concat(label, "/USD second source"), price8);
        feedsOf[address(token)] = [p, a, st, n];
        pricedTokens.push(address(token));
        TokenDef memory d;
        d.isUsdStable = usdStable;
        d.primaryRoute = _list(address(p));
        d.alternateRoute = _list(address(a));
        d.standbyRoute = _list(address(st));
        d.replacedSlot = RouteSlot.None;
        d.issuerProbe = IssuerProbe.None;
        SecondSource memory none;
        vm.startPrank(address(timelock));
        registry.listToken(address(token), d);
        store.setFeedAgreementToleranceBps(address(token), TOLERANCE_BPS);
        store.setSecondSource(
            address(token), SecondSource(SecondSourceKind.OracleNetwork, address(n), bytes32(0), FEED_AGE, 0, 100), none
        );
        vm.stopPrank();
    }

    /// @notice WETH as a DebtOracle-priced debt reserve of the CDP Spoke, as the fixture enables USDC: WETH listed with
    /// its feeds at $3,000 (`_listPricedToken`), its real DebtOracle (`debtStressRiseBps = 500`), the Hub asset funded
    /// with 1,000,000 WETH through the Lend Spoke, the CDP reserve priced by the DebtOracle (draw cap
    /// `DEBT_DRAW_CAP`), its real First-Loss Reserve (100,000 WETH) and credit line, the Aave V3 Pool stand-in lending
    /// it, a primary and a backup route from each pool token of every listed market into WETH (real `DexPathRoute`s
    /// over route-DEX pools at the feed rate), then `registry.enableDebtReserve` with a 0.0003 WETH floor rounding
    /// allowance. `weth` is created here unless a suite created it first.
    function _addWethDebtReserve() internal {
        if (address(weth) == address(0)) {
            weth = new ClTestToken("WETH", 18);
            vm.label(address(weth), "WETH");
        }
        if (address(feedsOf[address(weth)][0]) == address(0)) _listPricedToken(weth, "WETH", WETH_PRICE, false);
        vm.prank(address(timelock));
        store.tightenDebtStressRiseBps(address(weth), 500);
        IDebtOracle impl = IDebtOracle(deployCode("DebtOracle.sol:DebtOracle", abi.encode(address(timelock))));
        DebtOracleInitParams memory p = DebtOracleInitParams({
            timelock: address(timelock),
            asset: address(weth),
            marketRegistry: address(registry),
            parameterStore: address(store),
            description: "WETH / USD",
            pokeMinGas: 600_000
        });
        wethOracle = IDebtOracle(address(new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (p)))));
        vm.label(address(wethOracle), "DebtOracle WETH");
        (wethAssetId, wethReserveId) = _addDebtAsset(weth, 18, address(wethOracle));
        address cs = _coverage(address(weth), wethAssetId);
        // Every active market needs its routes into the asset before the reserve is enabled (REQ-MREG-032).
        uint256 n = registry.marketCount();
        for (uint256 id = 1; id <= n; ++id) {
            _routesInto(id, address(weth));
        }
        _enableDebt(
            DebtReserveDef({
                reserveId: wethReserveId,
                asset: address(weth),
                decimals: 18,
                fundingHub: aave.hub,
                hubAssetId: wethAssetId,
                priceSource: address(wethOracle),
                fixedPrice: false,
                firstLossReserve: cs,
                crossHub: false,
                approved: false
            }),
            FLOOR_ROUNDING_ALLOWANCE_WETH
        );
    }

    /// @notice A primary and a backup route from each pool token of `marketId` into `debtAsset`, set by the timelock.
    function _routesInto(
        uint256 marketId,
        address debtAsset
    ) internal {
        address[] memory toks = registry.getMarket(marketId).tokens;
        for (uint256 i = 0; i < toks.length; ++i) {
            if (toks[i] == debtAsset) continue;
            address[2] memory r = _realRoutes(toks[i], debtAsset);
            vm.startPrank(address(timelock));
            registry.setRoute(marketId, toks[i], debtAsset, 0, r[0]);
            registry.setRoute(marketId, toks[i], debtAsset, 1, r[1]);
            vm.stopPrank();
        }
    }

    /// @notice Every feed of `token` at `price8` in the next block, the route-DEX pools aligned, the token's DebtOracle
    /// (when it has one) and every LPOracle poked.
    function _moveToken(
        address token,
        uint256 price8
    ) internal {
        _publish(token, price8);
        _alignRoutes();
        if (token == address(weth) && address(wethOracle) != address(0)) wethOracle.poke();
        if (token == address(usdc)) usdcOracle.poke();
        _pokeAll();
    }

    // ─── Accounts through the AaveAdapter ───

    /// @notice `payer` funds and approves `maxSpend` of the reserve's asset and repays `wallet`'s debt in `marketId`.
    function _repayVia(
        address payer,
        address wallet,
        uint256 marketId,
        uint256 reserveId,
        uint256 maxSpend,
        bool repayAll
    ) internal returns (uint256 spent) {
        ClTestToken asset = _assetOf(reserveId);
        asset.mint(payer, maxSpend);
        vm.startPrank(payer);
        asset.approve(adapter, maxSpend);
        spent = adapterC.repay(wallet, marketId, reserveId, maxSpend, repayAll, _deadline());
        asset.approve(adapter, 0);
        vm.stopPrank();
    }

    function _withdrawVia(
        address wallet,
        uint256 marketId,
        bytes32 key,
        uint256 units
    ) internal {
        vm.prank(wallet);
        adapterC.withdraw(marketId, _ref(key), units, _deadline(), 0);
    }

    function _rwcParams(
        uint256 marketId,
        bytes32 key,
        uint128 units,
        uint256 reserveId
    ) internal view returns (RepayWithCollateralParams memory p) {
        p = RepayWithCollateralParams({
            marketId: marketId,
            position: _ref(key),
            units: units,
            debtReserveId: reserveId,
            minAmounts: new uint256[](2),
            minDebtRepaid: 0,
            minAssetOut: 0,
            deadline: _deadline(),
            minHealthFactor: 0
        });
    }

    // ─── Prices ───

    /// @notice Both pool tokens at `price8` on every feed, the route-DEX pools swapped to the new rates, then every
    /// listed market's LPOracle poked, in the next block. The markets' own USDC/USDT pools keep their 1:1 rate.
    function _movePoolTokens(
        uint256 price8
    ) internal {
        _publish(address(usdc), price8);
        _publish(address(usdt), price8);
        _alignRoutes();
        _pokeAll();
    }

    /// @notice The USD price of `token` the feeds publish (GHO: its fixed $1.00), 8 decimals.
    function _usdPrice(
        address token
    ) internal view returns (uint256) {
        if (token == address(gho)) return 1e8;
        return uint256(feedsOf[token][0].answer());
    }

    /// @notice Every route-DEX pool swapped to the rate of its tokens' published prices, as arbitrage would leave it.
    function _alignRoutes() internal {
        for (uint256 i = 0; i < routePairs.length; ++i) {
            (address a, address b) = (routePairs[i][0], routePairs[i][1]);
            for (uint256 k = 0; k < 2; ++k) {
                IClPool p = routePoolOf[a][b][k];
                (ClTestToken t0, ClTestToken t1) = (ClTestToken(p.token0()), ClTestToken(p.token1()));
                _swapTo(
                    p,
                    ClPriceMath.oracleSqrtPrice(
                        _usdPrice(address(t0)), _usdPrice(address(t1)), t0.decimals(), t1.decimals()
                    )
                );
            }
        }
    }

    function _pokeAll() internal {
        uint256 n = registry.marketCount();
        for (uint256 id = 1; id <= n; ++id) {
            mkt[id].oracle.poke();
        }
    }

    /// @notice USDT alone at `price8`: every USDT feed, both markets' USDC/USDT pools swapped to the new rate, then
    /// `TWAP_WAIT` (31 minutes) so the pools' 1,800 s TWAP agrees with the feeds, every feed republished, the route-DEX
    /// pools aligned and every LPOracle poked. A full-range USDC/USDT unit is worth `2·sqrt(pUSDC·pUSDT)`, so USDT at
    /// $0.93 takes a market's vault token from $2.00 to $1.9287 (-3.56 %) while USDC debt keeps its $1.00.
    function _depegUsdt(
        uint256 price8
    ) internal {
        _publish(address(usdt), price8);
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
    }

    /// @dev Long enough after a pool move for the 1,800 s TWAP to sit at the new rate.
    uint256 internal constant TWAP_WAIT = 1860;

    // ─── Pause and freeze, by the Emergency Guardian ───

    /// @notice Moves the Hub to `state` for `reason` from whatever it is now (None clears it), as the Emergency
    /// Guardian does.
    function _setPause(
        PauseState state,
        PauseReason reason
    ) internal {
        PauseState now_ = registry.pauseState(aave.hub);
        vm.startPrank(emergencyGuardian);
        if (now_ == PauseState.Paused) registry.unpause(aave.hub);
        else if (now_ == PauseState.Frozen) registry.unfreeze(aave.hub);
        if (state == PauseState.Frozen) registry.freeze(aave.hub);
        else if (state == PauseState.Paused) registry.pause(aave.hub, reason);
        vm.stopPrank();
    }

    /// @notice The Emergency Guardian freezes `account`.
    function _freezeWallet(
        address account
    ) internal {
        vm.prank(emergencyGuardian);
        registry.freezeAddress(account);
    }

    // ─── Liquidation through LPVaultSwap ───

    function _liqParams(
        address proxy,
        uint256 marketId,
        uint256 reserveId,
        uint256 debtToCover
    ) internal view returns (LiquidationParams memory p) {
        p = LiquidationParams({
            proxy: proxy,
            marketId: marketId,
            debtReserveId: reserveId,
            debtToCover: debtToCover,
            routeMode: RouteMode.PrimaryThenBackup,
            minAmounts: new uint256[](0),
            deadline: block.timestamp + 120,
            minPayout: 0,
            maxShortfall: 0
        });
    }

    /// @notice Funds `caller` with `debtToCover + maxShortfall` of the debt asset, approves LPVaultSwap for exactly
    /// that and calls `liquidate` as `caller`.
    function _liquidateAs(
        address caller,
        LiquidationParams memory p
    ) internal returns (LiquidationResult memory r) {
        _fundCaller(caller, p);
        vm.prank(caller);
        r = lvs.liquidate(p);
    }

    function _fundCaller(
        address caller,
        LiquidationParams memory p
    ) internal {
        ClTestToken asset = _assetOf(p.debtReserveId);
        asset.mint(caller, p.debtToCover + p.maxShortfall);
        vm.prank(caller);
        asset.approve(lpVaultSwap, p.debtToCover + p.maxShortfall);
    }

    // ─── Reads ───

    /// @notice The debt asset of `reserveId` on the CDP Spoke.
    function _assetOf(
        uint256 reserveId
    ) internal view returns (ClTestToken) {
        return ClTestToken(registry.getDebtReserve(aave.cdpSpoke, reserveId).asset);
    }
}
