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
import {IPayoutEscrow} from "../../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {LVSLPOracleMock, LVSMarketRegistryMock} from "../../utils/mocks/LPVaultSwapMocks.sol";
import {PayoutToken} from "../../utils/mocks/PayoutToken.sol";
import {MockCLPool} from "../../utils/mocks/SwapRouteMocks.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title LPVaultSwapHandler
/// @notice Actions of the LPVaultSwap invariant suite: liquidations by registered and unregistered callers in either
/// route mode with any shortfall budget, price and route moves, donations to LPVaultSwap, direct `liquidationCall`
/// attempts by an attacker with either `receiveShares` value, and a pending settlement. Every completed liquidation is
/// checked against token balances: the USDC of every holder it can move (the caller, LPVaultSwap, the Hub, the fee
/// recipient, the borrower's wallet, the PayoutEscrow, the LPVault and both route pools) is read before and after, and
/// the suite asserts that no USDC appeared or vanished, that the caller's and the unwind's USDC went to the Hub, the
/// fee recipient and the borrower, and that each field of the returned result equals the balance change it reports.
/// @dev Steered so most liquidations complete: three seeds in four pick a liquidatable account (pushing the price down
/// to a health factor of 0.85 to 0.99 when none is) and cover all of its debt or a bounded part. A liquidation or
/// settlement refused with a named error reverts `Skipped()`, so the campaign's metrics count it as a revert; an
/// unnamed refusal is recorded instead and fails `invariant_TEST_093_refusalsAreNamed`.
contract LPVaultSwapHandler is CommonBase, StdCheats, StdUtils {
    /// @notice A named refusal (or nothing to act on): the call is counted as a revert.
    error Skipped();

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
        address[] wallets;
        address[] callers;
        address attacker;
        address feeRecipient;
        IPayoutEscrow escrow;
        address lpVault;
        address coll;
        uint256 keptUnits;
    }

    /// @dev USDC of every holder a liquidation can move; `sources` is the LPVault plus both route pools, the holders
    /// the unwind and the swaps pay from; `parked` is Collateralization, which keeps the pool tokens a reconcile of
    /// kept units removes until `settlePending`.
    struct Usdc {
        uint256 caller;
        uint256 lvs;
        uint256 hub;
        uint256 fee;
        uint256 feeEscrowed;
        uint256 wallet;
        uint256 walletEscrowed;
        uint256 escrow;
        uint256 sources;
        uint256 parked;
    }

    /// @dev A route rate at or above this (per 10,000) meets the per-leg minimum at the fixture's 1 % slippage
    /// allowance and the USDT leg price of $0.9995, so the route works (INV-046).
    uint256 internal constant WORKING_ROUTE_BPS = 9900;

    Env internal env;

    uint256 public liquidations;
    uint256 public conservationBreaks;
    uint256 public reportBreaks;
    uint256 public floorBreaks;
    uint256 public directSeizures;
    uint256 public zeroDirectCalls;
    uint256 public donatedUsdc;
    uint256 public donatedUsdt;
    uint256 public hfDrops;
    uint256 public liquidationsWhilePaused;
    uint256 public backupOnlyLiquidations;
    uint256 public unregisteredLiquidations;
    uint256 public shortfallLiquidations;
    uint256 public surplusLiquidations;
    uint256 public settlements;
    /// @notice Vault-token units an earlier implementation seized and kept, that LPVaultSwap still holds (set-up seeds
    /// them; `settlePending` burns them once a liquidation of the account has reconciled them into pending).
    uint256 public keptUnits;
    uint256 public unexpectedReverts;
    bytes public lastUnexpected;

    constructor(
        Env memory e
    ) {
        env = e;
        keptUnits = e.keptUnits;
    }

    function liquidate(
        uint256 accountSeed,
        uint256 debtToCover,
        bool backupOnly,
        uint256 maxShortfall,
        uint256 callerSeed
    ) external {
        uint256 i = accountSeed % env.proxies.length;
        bool steered = (accountSeed >> 8) % 4 != 0;
        if (steered) {
            i = _steerToLiquidatable(i, accountSeed >> 16);
            uint256 owed = IAaveV4Spoke(env.spoke).getUserTotalDebt(env.usdcReserveId, env.proxies[i]);
            debtToCover = debtToCover % 2 == 0 ? owed : bound(debtToCover, 1, owed);
        } else {
            debtToCover = bound(debtToCover, 1, 6000e6);
        }
        address proxy = env.proxies[i];
        address caller = env.callers[callerSeed % env.callers.length];
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
        Usdc memory before = _usdc(caller, env.wallets[i]);
        vm.prank(caller);
        try env.lvs.liquidate(p) returns (LiquidationResult memory r) {
            _checkBalances(before, _usdc(caller, env.wallets[i]), r, p);
            ++liquidations;
            if (env.registry.pauseState() != 0) ++liquidationsWhilePaused;
            if (backupOnly) ++backupOnlyLiquidations;
            if (!env.lvs.isApprovedKeeper(caller)) ++unregisteredLiquidations;
            if (r.shortfall != 0) ++shortfallLiquidations;
            if (r.borrowerSurplus != 0) ++surplusLiquidations;
            uint256 hfAfter = IAaveV4Spoke(env.spoke).getUserAccountData(proxy).healthFactor;
            // INV-076: while the account was solvent at the bonus (HF >= LB x CF = 1.05 x 0.8) HF does not fall.
            if (
                hfBefore >= 0.84e18 && hfAfter < hfBefore
                    && IAaveV4Spoke(env.spoke).getUserTotalDebt(env.usdcReserveId, proxy) != 0
            ) {
                ++hfDrops;
            }
        } catch (bytes memory reason) {
            if (_named(reason)) revert Skipped();
            ++unexpectedReverts;
            lastUnexpected = reason;
        }
        // Whatever the outcome, the caller keeps no approval to LPVaultSwap from this action.
        vm.prank(caller);
        env.usdc.approve(address(env.lvs), 0);
    }

    /// @notice Liveness probe of INV-046 (run by the suite after every call, from a snapshot it reverts): every account
    /// with HF < 1 and debt is liquidated by an unregistered caller funding all of its debt with a shortfall budget of
    /// the debt, in whatever pause state, price and routes the run reached; the call succeeds and leaves the account at
    /// HF >= 1, with no debt or with no collateral. With no working route (both below `WORKING_ROUTE_BPS`) only
    /// `NoRouteAvailable` may refuse it. Returns the number of failed probes, the last failure and the probes made.
    function probeLiveness() external returns (uint256 failures, bytes memory last, uint256 probes) {
        IAaveV4Spoke spoke = IAaveV4Spoke(env.spoke);
        address caller = env.callers[1];
        for (uint256 i = 0; i < env.proxies.length; ++i) {
            address proxy = env.proxies[i];
            uint256 owed = spoke.getUserTotalDebt(env.usdcReserveId, proxy);
            if (owed == 0 || spoke.getUserAccountData(proxy).healthFactor >= 1e18) continue;
            ++probes;
            uint256 snapshot = vm.snapshotState();
            env.usdc.mint(caller, 2 * owed);
            vm.startPrank(caller);
            env.usdc.approve(address(env.lvs), 2 * owed);
            LiquidationParams memory p = LiquidationParams({
                proxy: proxy,
                marketId: env.marketId,
                debtReserveId: env.usdcReserveId,
                debtToCover: owed,
                routeMode: RouteMode.PrimaryThenBackup,
                minAmounts: new uint256[](0),
                deadline: block.timestamp,
                minPayout: 0,
                maxShortfall: owed
            });
            try env.lvs.liquidate(p) {
                if (
                    spoke.getUserAccountData(proxy).healthFactor < 1e18
                        && spoke.getUserTotalDebt(env.usdcReserveId, proxy) != 0
                        && spoke.getUserSuppliedShares(env.vtReserveId, proxy) != 0
                ) {
                    ++failures;
                    last = abi.encodePacked("account still liquidatable after a full-size liquidation");
                }
            } catch (bytes memory reason) {
                if (bytes4(reason) != ILPVaultSwapErrors.NoRouteAvailable.selector || _routeWorks()) {
                    ++failures;
                    last = reason;
                }
            }
            vm.stopPrank();
            vm.revertToState(snapshot);
        }
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
        try env.lvs.settlePending(env.marketId, env.usdcReserveId) returns (uint256 units, uint256[] memory, uint256) {
            keptUnits -= units;
            ++settlements;
        } catch {
            revert Skipped();
        }
    }

    function deficit() external view returns (uint256) {
        return IAaveV4Hub(env.hub).getSpokeDeficitRay(env.usdcAssetId, env.spoke);
    }

    // ─── Steering ───

    /// @dev The first account from `i` with HF < 1 and debt; when there is none, lowers the LPOracle price so account
    /// `i` sits at a health factor of 0.85 to 0.99 (HF is linear in the collateral price; USDC debt is priced at $1).
    function _steerToLiquidatable(
        uint256 i,
        uint256 seed
    ) internal returns (uint256) {
        IAaveV4Spoke spoke = IAaveV4Spoke(env.spoke);
        uint256 n = env.proxies.length;
        for (uint256 j = 0; j < n; ++j) {
            address proxy = env.proxies[(i + j) % n];
            if (
                spoke.getUserTotalDebt(env.usdcReserveId, proxy) != 0
                    && spoke.getUserAccountData(proxy).healthFactor < 1e18
            ) return (i + j) % n;
        }
        for (uint256 j = 0; j < n; ++j) {
            address proxy = env.proxies[(i + j) % n];
            if (spoke.getUserTotalDebt(env.usdcReserveId, proxy) == 0) continue;
            uint256 hf = spoke.getUserAccountData(proxy).healthFactor;
            uint256 price = uint256(env.lpOracle.latestAnswer()) * bound(seed, 85, 99) * 1e16 / hf;
            // At most 0.99 / HF times the current price, far below 2^255.
            // forge-lint: disable-next-line(unsafe-typecast)
            env.lpOracle.setAnswer(int256(price));
            return (i + j) % n;
        }
        revert Skipped();
    }

    function _routeWorks() internal view returns (bool) {
        return _rateBps(env.primaryPool) >= WORKING_ROUTE_BPS || _rateBps(env.backupPool) >= WORKING_ROUTE_BPS;
    }

    function _rateBps(
        MockCLPool pool
    ) internal view returns (uint256) {
        return pool.num() * 10_000 / pool.den();
    }

    // ─── Balance checks ───

    function _usdc(
        address caller,
        address wallet
    ) internal view returns (Usdc memory b) {
        PayoutToken usdc = env.usdc;
        b.caller = usdc.balanceOf(caller);
        b.lvs = usdc.balanceOf(address(env.lvs));
        b.hub = usdc.balanceOf(env.hub);
        b.fee = usdc.balanceOf(env.feeRecipient);
        b.feeEscrowed = env.escrow.claimable(address(usdc), env.feeRecipient);
        b.wallet = usdc.balanceOf(wallet);
        b.walletEscrowed = env.escrow.claimable(address(usdc), wallet);
        b.escrow = usdc.balanceOf(address(env.escrow));
        b.sources = usdc.balanceOf(env.lpVault) + usdc.balanceOf(address(env.primaryPool))
            + usdc.balanceOf(address(env.backupPool));
        b.parked = usdc.balanceOf(env.coll);
    }

    /// @dev TEST-093 conservation on balances. With `in = caller's fall + sources' fall` and `out = rise of the Hub,
    /// the fee recipient (paid or escrowed), the borrower (paid or escrowed) and Collateralization (pool tokens of a
    /// reconcile, held for `settlePending`)`: `in == out`, LPVaultSwap's USDC is
    /// unchanged and the escrow's rise is exactly the escrowed credit, so no USDC appeared or vanished. The result must
    /// report what the balances show: `D` the Hub's rise, `A` the fee recipient's, `B` the borrower's, `R` the sources'
    /// fall less Collateralization's rise and `keeperOut − Kf − shortfall` the caller's change. Floor: `R + shortfall >= minOut` and `D <= Kf <=
    /// debtToCover`, `shortfall <= maxShortfall`.
    function _checkBalances(
        Usdc memory b,
        Usdc memory a,
        LiquidationResult memory r,
        LiquidationParams memory p
    ) internal {
        int256 callerIn = int256(b.caller) - int256(a.caller);
        int256 parked = int256(a.parked) - int256(b.parked);
        int256 recovered = int256(b.sources) - int256(a.sources) - parked;
        int256 toHub = int256(a.hub) - int256(b.hub);
        int256 toFee = int256(a.fee + a.feeEscrowed) - int256(b.fee + b.feeEscrowed);
        int256 toBorrower = int256(a.wallet + a.walletEscrowed) - int256(b.wallet + b.walletEscrowed);
        int256 escrowed = int256(a.feeEscrowed + a.walletEscrowed) - int256(b.feeEscrowed + b.walletEscrowed);
        if (
            callerIn + recovered != toHub + toFee + toBorrower || a.lvs != b.lvs || parked < 0
                || int256(a.escrow) - int256(b.escrow) != escrowed
        ) ++conservationBreaks;
        if (
            toHub != int256(r.debtRepaid) || toFee != int256(r.avanaFee) || toBorrower != int256(r.borrowerSurplus)
                || recovered != int256(r.recovered)
                || -callerIn != int256(r.keeperOut) - int256(r.callerFunds) - int256(r.shortfall)
        ) ++reportBreaks;
        if (
            recovered + int256(r.shortfall) < int256(r.minOut) || toHub > int256(r.callerFunds)
                || r.callerFunds > p.debtToCover || r.shortfall > p.maxShortfall
        ) ++floorBreaks;
    }
}
