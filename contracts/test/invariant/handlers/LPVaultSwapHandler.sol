// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwap} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {ILPVaultSwapErrors} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {LVSLPOracleMock, LVSMarketRegistryMock} from "../../utils/mocks/LPVaultSwapMocks.sol";
import {PayoutToken} from "../../utils/mocks/PayoutToken.sol";
import {MockCLPool} from "../../utils/mocks/SwapRouteMocks.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title LPVaultSwapHandler
/// @notice Actions of the LPVaultSwap invariant suite: liquidations by registered and unregistered callers in either
/// route mode with any shortfall budget, price and route moves, donations to LPVaultSwap, direct `liquidationCall`
/// attempts by an attacker with either `receiveShares` value, and a pending settlement. Ghosts record what every
/// completed liquidation moved, so the suite checks conservation per call and LPVaultSwap's neutrality after every
/// call.
contract LPVaultSwapHandler is CommonBase, StdCheats, StdUtils {
    struct Env {
        ILPVaultSwap lvs;
        PayoutToken usdc;
        PayoutToken usdt;
        address vt;
        address spoke;
        address hub;
        uint256 usdcAssetId;
        uint256 vtReserveId;
        uint256 usdcReserveId;
        uint256 marketId;
        LVSLPOracleMock lpOracle;
        LVSMarketRegistryMock registry;
        MockCLPool primaryPool;
        MockCLPool backupPool;
        address[] proxies;
        address[] callers;
        address attacker;
    }

    Env internal env;

    uint256 public liquidations;
    uint256 public conservationBreaks;
    uint256 public floorBreaks;
    uint256 public directSeizures;
    uint256 public zeroDirectCalls;
    uint256 public donatedUsdc;
    uint256 public donatedUsdt;
    uint256 public hfDrops;
    uint256 public liquidationsWhilePaused;
    uint256 public unexpectedReverts;
    bytes public lastUnexpected;

    constructor(
        Env memory e
    ) {
        env = e;
    }

    function liquidate(
        uint256 accountSeed,
        uint256 debtToCover,
        bool backupOnly,
        uint256 maxShortfall,
        uint256 callerSeed
    ) external {
        address proxy = env.proxies[accountSeed % env.proxies.length];
        address caller = env.callers[callerSeed % env.callers.length];
        debtToCover = bound(debtToCover, 1, 6000e6);
        maxShortfall = bound(maxShortfall, 0, 300e6);
        uint256 hfBefore = IAaveV4Spoke(env.spoke).getUserAccountData(proxy).healthFactor;
        LiquidationParams memory p = LiquidationParams({
            proxy: proxy,
            marketId: env.marketId,
            debtReserveId: env.usdcReserveId,
            debtToCover: debtToCover,
            routeMode: backupOnly ? RouteMode.BackupOnly : RouteMode.PrimaryThenBackup,
            minAmounts: new uint256[](0),
            deadline: block.timestamp,
            minPayout: 0,
            maxShortfall: maxShortfall
        });
        env.usdc.mint(caller, debtToCover + maxShortfall);
        vm.prank(caller);
        env.usdc.approve(address(env.lvs), debtToCover + maxShortfall);
        vm.prank(caller);
        try env.lvs.liquidate(p) returns (LiquidationResult memory r) {
            ++liquidations;
            if (env.registry.pauseState() != 0) ++liquidationsWhilePaused;
            if (
                r.callerFunds + r.recovered + r.shortfall != r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut
            ) {
                ++conservationBreaks;
            }
            if (r.recovered + r.shortfall < r.minOut || r.debtRepaid > r.callerFunds) ++floorBreaks;
            uint256 hfAfter = IAaveV4Spoke(env.spoke).getUserAccountData(proxy).healthFactor;
            // INV-076: while the account was solvent at the bonus (HF >= LB x CF = 1.05 x 0.8) HF does not fall.
            if (
                hfBefore >= 0.84e18 && hfAfter < hfBefore
                    && IAaveV4Spoke(env.spoke).getUserTotalDebt(env.usdcReserveId, proxy) != 0
            ) {
                ++hfDrops;
            }
        } catch (bytes memory reason) {
            if (!_named(reason)) {
                ++unexpectedReverts;
                lastUnexpected = reason;
            }
        }
        // Whatever the outcome, the caller keeps no approval to LPVaultSwap from this action.
        vm.prank(caller);
        env.usdc.approve(address(env.lvs), 0);
    }

    /// @dev The refusals the spec names for a liquidation whose account, price or routes moved: not liquidatable, no
    /// route meeting its leg minimum, recovery below the floor with the budget spent, nothing seized, or Aave's dust
    /// rule on a repayment that would leave a sliver of debt.
    function _named(
        bytes memory reason
    ) internal pure returns (bool) {
        bytes4 s = bytes4(reason);
        return s == ILPVaultSwapErrors.NotLiquidatable.selector || s == ILPVaultSwapErrors.NoRouteAvailable.selector
            || s == ILPVaultSwapErrors.RecoveryBelowFloor.selector || s == ILPVaultSwapErrors.NothingSeized.selector
            || s == bytes4(keccak256("MustNotLeaveDust()"));
    }

    /// @notice Moves the MarketRegistry through None, Frozen, Paused(General) and Paused(MintPathSuspect).
    function movePause(
        uint256 state,
        uint256 reason
    ) external {
        uint8 st = uint8(bound(state, 0, 2));
        env.registry.setPause(st, st == 2 ? uint8(bound(reason, 1, 2)) : 0);
    }

    function movePrice(
        uint256 price8
    ) external {
        env.lpOracle.setAnswer(int256(bound(price8, 150_000_000, 230_000_000)));
    }

    function moveRoutes(
        uint256 primaryBps,
        uint256 backupBps
    ) external {
        env.primaryPool.setRate(bound(primaryBps, 9500, 10_500), 10_000);
        env.backupPool.setRate(bound(backupBps, 9500, 10_500), 10_000);
    }

    function donate(
        uint256 usdcAmount,
        uint256 usdtAmount
    ) external {
        usdcAmount = bound(usdcAmount, 0, 1e6);
        usdtAmount = bound(usdtAmount, 0, 1e6);
        env.usdc.mint(address(env.lvs), usdcAmount);
        env.usdt.mint(address(env.lvs), usdtAmount);
        donatedUsdc += usdcAmount;
        donatedUsdt += usdtAmount;
    }

    function directLiquidation(
        uint256 accountSeed,
        uint256 amount,
        bool receiveShares
    ) external {
        address proxy = env.proxies[accountSeed % env.proxies.length];
        amount = bound(amount, 1, 5000e6);
        env.usdc.mint(env.attacker, amount);
        vm.startPrank(env.attacker);
        env.usdc.approve(env.spoke, amount);
        uint256 sharesBefore = IAaveV4Spoke(env.spoke).getUserSuppliedShares(env.vtReserveId, proxy);
        try IAaveV4Spoke(env.spoke).liquidationCall(env.vtReserveId, env.usdcReserveId, proxy, amount, receiveShares) {
            // A call that rounds the seizure to zero repays debt for nothing and moves no collateral; a seizure is a
            // fall of the proxy's supplied shares.
            if (IAaveV4Spoke(env.spoke).getUserSuppliedShares(env.vtReserveId, proxy) < sharesBefore) ++directSeizures;
            else ++zeroDirectCalls;
        } catch {}
        env.usdc.approve(env.spoke, 0);
        vm.stopPrank();
    }

    function settlePending(
        uint256 callerSeed
    ) external {
        vm.prank(env.callers[callerSeed % env.callers.length]);
        try env.lvs.settlePending(env.marketId, env.usdcReserveId) {} catch {}
    }

    function deficit() external view returns (uint256) {
        return IAaveV4Hub(env.hub).getSpokeDeficitRay(env.usdcAssetId, env.spoke);
    }
}
