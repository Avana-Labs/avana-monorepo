// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {LiquidationParams} from "../../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {RepayWithCollateralParams} from "../../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {ClTestToken, IClPool} from "./ClPoolFixture.sol";
import {FullStackMarkets} from "./FullStackMarkets.sol";

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
    function _realStack() internal pure override returns (bool) {
        return true;
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
