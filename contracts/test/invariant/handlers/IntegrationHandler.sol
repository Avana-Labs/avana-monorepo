// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILens} from "../../../src/lens/lens/ILens.sol";
import {LiquidationPreview} from "../../../src/lens/lens/types/LiquidationPreview.sol";
import {RecordView} from "../../../src/lens/lens/types/RecordView.sol";
import {ILPVaultSwap} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {LiquidationResult} from "../../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {IPayoutEscrow} from "../../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {IFlashLiquidator} from "../../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {IAaveAdapter} from "../../../src/policy/aave-adapter/IAaveAdapter.sol";
import {IAaveAdapterErrors} from "../../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {RepayWithCollateralParams} from "../../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {IRiskModuleErrors} from "../../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {ClTestToken} from "../../utils/fixtures/ClPoolFixture.sol";
import {MockAaveV3Pool} from "../../utils/mocks/AaveV3PoolMocks.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice What the suite does for the handler on the real stack: positions on the real NonfungiblePositionManager,
/// the guardians' calls on the real MarketRegistry, and price, route and time moves through the feeds and real pools.
interface IIntegrationWorld {
    function mintPosition(
        address wallet,
        uint128 units
    ) external returns (bytes32 key);

    function setPause(
        PauseState state,
        PauseReason reason
    ) external;

    function freezeWallet(
        address wallet,
        bool on
    ) external;

    function moveUsdt(
        uint256 price8
    ) external;

    function toHealth(
        address wallet,
        uint256 reserveId,
        uint256 seed
    ) external;

    function moveRoutes(
        uint256 rateBps
    ) external;

    function warp(
        uint256 secs
    ) external;
}

/// @title IntegrationHandler
/// @notice Actions of the integration invariant suite on the deployed stack, every one through a real entry point:
/// borrowers (pledge, borrow GHO and USDC, repay by any payer, debt-free withdrawal, `repayAllAndWithdraw`, repay with
/// collateral) through the AaveAdapter; liquidators (Avana's keeper, unregistered addresses and the public flash
/// liquidation helper, both route modes) and `settlePending` through LPVaultSwap; an attacker's direct
/// `liquidationCall`; the guardians (pause state and reason, address freeze); and the environment (vault price, feed
/// time, route rates), the guardians' and the environment's through the suite (`IIntegrationWorld`). Ghosts record every
/// rule an action must keep, so the suite asserts them after every call.
/// @dev Liveness (TEST-100, fail_on_revert for the live actions): an account the Lens reports liquidatable with every
/// gate open must settle with the Lens's own parameters; exits must settle whenever their own checks pass. Their
/// failures are counted, not swallowed.
contract IntegrationHandler is CommonBase, StdCheats, StdUtils {
    struct Env {
        IAaveAdapter adapter;
        ILPVaultSwap lvs;
        address helper;
        ILens lens;
        IIntegrationWorld world;
        MarketRegistry reg;
        MockAaveV3Pool v3Pool;
        ClTestToken usdc;
        ClTestToken usdt;
        ClTestToken gho;
        address vt;
        address spoke;
        address hub;
        uint256 marketId;
        uint256 vtReserveId;
        uint256 usdcReserveId;
        uint256 ghoReserveId;
        uint32 integrationId;
        address[] wallets;
        address[] callers;
        address attacker;
        address feeRecipient;
        IPayoutEscrow escrow;
        address coll;
        // Holders a liquidation's unwind and swaps pay each debt asset from: the market pool and the route pools into it.
        address[] usdcSources;
        address[] ghoSources;
    }

    /// @dev The debt asset held by every address a direct liquidation can move it between.
    struct Held {
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

    Env internal env;
    mapping(address => bytes32[]) internal _keys;

    uint256 public liquidations;
    /// @notice Direct liquidations that completed (each checked on balances).
    uint256 public directLiquidations;
    /// @notice Liquidations through the public flash liquidation helper that completed.
    uint256 public helperLiquidations;
    uint256 public settlementBreaks;
    /// @notice Direct liquidations whose debt-asset balances do not balance (TEST-104 on balances).
    uint256 public conservationBreaks;
    /// @notice Direct liquidations whose result does not report the balance changes.
    uint256 public reportBreaks;
    uint256 public livenessFailures;
    uint256 public exitFailures;
    uint256 public exitBlockedByStop;
    uint256 public gateBreaks;
    uint256 public directSeizures;
    bytes public lastFailure;

    constructor(
        Env memory e
    ) {
        env = e;
    }

    function seedKey(
        address wallet,
        bytes32 key
    ) external {
        _keys[wallet].push(key);
    }

    // ─── Borrowers through the AaveAdapter ───

    function pledge(
        uint256 w,
        uint256 units
    ) external {
        address wallet = env.wallets[w % env.wallets.length];
        units = bound(units, 100e6, 5000e6);
        bytes32 key = env.world.mintPosition(wallet, uint128(units));
        vm.prank(wallet);
        try env.adapter.pledge(env.marketId, PositionRef(env.integrationId, key), block.timestamp) {
            _keys[wallet].push(key);
        } catch {}
    }

    function borrow(
        uint256 w,
        uint256 amount,
        bool gho
    ) external {
        address wallet = env.wallets[w % env.wallets.length];
        address proxy = env.adapter.proxyOf(wallet, env.marketId);
        if (proxy == address(0)) return;
        uint256 reserveId = gho ? env.ghoReserveId : env.usdcReserveId;
        amount = bound(amount, 1, 3000) * (gho ? 1e18 : 1e6);
        uint256 nonce = env.adapter.borrowNonce(proxy);
        PauseState state = env.reg.pauseState(env.hub);
        bool frozen = env.reg.isFrozenAddress(wallet);
        vm.prank(wallet);
        try env.adapter.borrow(env.marketId, reserveId, amount, wallet, block.timestamp, 0, nonce) {
            // REQ-ADAPTER-072/073/082: no borrow in Frozen or Paused, none by a frozen wallet.
            if (state != PauseState.None || frozen) ++gateBreaks;
        } catch (bytes memory err) {
            bytes4 s = bytes4(err);
            if (state == PauseState.Frozen && !frozen && s != IAaveAdapterErrors.ApplicationFrozen.selector) {
                ++gateBreaks;
            }
            if (state == PauseState.Paused && !frozen && s != IAaveAdapterErrors.ApplicationPaused.selector) {
                ++gateBreaks;
            }
        }
    }

    /// @notice Any payer repays part or all of one debt reserve; never refused by a stop (INV-043, INV-081).
    function repay(
        uint256 w,
        uint256 payerSeed,
        uint256 shareBps,
        bool gho
    ) external {
        address wallet = env.wallets[w % env.wallets.length];
        address proxy = env.adapter.proxyOf(wallet, env.marketId);
        uint256 reserveId = gho ? env.ghoReserveId : env.usdcReserveId;
        if (proxy == address(0) || _debt(proxy, reserveId) == 0) return;
        address payer = payerSeed % 2 == 0 ? wallet : env.callers[payerSeed % env.callers.length];
        bool all = shareBps % 3 == 0;
        uint256 spend = all
            ? env.lens.quoteRepayAll(wallet, env.marketId, reserveId, block.timestamp)
            : _debt(proxy, reserveId) * bound(shareBps, 1, 9999) / 10_000 + 1;
        ClTestToken asset = gho ? env.gho : env.usdc;
        asset.mint(payer, spend);
        vm.prank(payer);
        asset.approve(address(env.adapter), spend);
        vm.prank(payer);
        try env.adapter.repay(wallet, env.marketId, reserveId, spend, all, block.timestamp) {}
        catch (bytes memory err) {
            _exitFailed(err);
        }
        vm.prank(payer);
        asset.approve(address(env.adapter), 0);
    }

    /// @notice A debt-free withdrawal of one whole record; never refused while the account has no debt (INV-045).
    function withdrawDebtFree(
        uint256 w,
        uint256 k
    ) external {
        address wallet = env.wallets[w % env.wallets.length];
        address proxy = env.adapter.proxyOf(wallet, env.marketId);
        if (proxy == address(0) || IAaveV4Spoke(env.spoke).getUserAccountData(proxy).borrowCount != 0) return;
        RecordView[] memory recs = env.lens.getRecords(proxy, 0, 16);
        if (recs.length == 0) return;
        RecordView memory r = recs[k % recs.length];
        if (r.creditedAfterReconcile == 0) return;
        vm.prank(wallet);
        try env.adapter
            .withdraw(
                env.marketId, PositionRef(r.integrationId, r.positionKey), r.creditedAfterReconcile, block.timestamp, 0
            ) {}
        catch (bytes memory err) {
            _exitFailed(err);
        }
    }

    /// @notice Repay every debt reserve with the Lens's quotes and withdraw one record in one call (REQ-ADAPTER-071).
    function repayAllAndWithdraw(
        uint256 w,
        uint256 k
    ) external {
        address wallet = env.wallets[w % env.wallets.length];
        address proxy = env.adapter.proxyOf(wallet, env.marketId);
        if (proxy == address(0)) return;
        RecordView[] memory recs = env.lens.getRecords(proxy, 0, 16);
        if (recs.length == 0) return;
        RecordView memory r = recs[k % recs.length];
        if (r.creditedAfterReconcile == 0) return;
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (env.ghoReserveId, env.usdcReserveId);
        uint256[] memory spends = new uint256[](2);
        spends[0] = env.lens.quoteRepayAll(wallet, env.marketId, ids[0], block.timestamp);
        spends[1] = env.lens.quoteRepayAll(wallet, env.marketId, ids[1], block.timestamp);
        _fundApprove(env.gho, wallet, spends[0]);
        _fundApprove(env.usdc, wallet, spends[1]);
        vm.prank(wallet);
        try env.adapter
            .repayAllAndWithdraw(
                env.marketId,
                PositionRef(r.integrationId, r.positionKey),
                r.creditedAfterReconcile,
                ids,
                spends,
                block.timestamp
            ) {}
        catch (bytes memory err) {
            _exitFailed(err);
        }
        _fundApprove(env.gho, wallet, 0);
        _fundApprove(env.usdc, wallet, 0);
    }

    /// @notice Repay with collateral: refused under MintPathSuspect, never lowers the health factor otherwise.
    function repayWithCollateral(
        uint256 w,
        uint256 k,
        uint256 unitsBps,
        bool gho
    ) external {
        address wallet = env.wallets[w % env.wallets.length];
        address proxy = env.adapter.proxyOf(wallet, env.marketId);
        uint256 reserveId = gho ? env.ghoReserveId : env.usdcReserveId;
        if (proxy == address(0) || _debt(proxy, reserveId) == 0) return;
        RecordView[] memory recs = env.lens.getRecords(proxy, 0, 16);
        if (recs.length == 0) return;
        RecordView memory r = recs[k % recs.length];
        uint128 units = uint128(r.creditedAfterReconcile * bound(unitsBps, 1, 3000) / 10_000);
        if (units == 0) return;
        RepayWithCollateralParams memory p = RepayWithCollateralParams({
            marketId: env.marketId,
            position: PositionRef(r.integrationId, r.positionKey),
            units: units,
            debtReserveId: reserveId,
            minAmounts: new uint256[](2),
            minDebtRepaid: 0,
            minAssetOut: 0,
            deadline: block.timestamp,
            minHealthFactor: 0
        });
        bool suspect = env.reg.pauseState(env.hub) == PauseState.Paused
            && env.reg.pauseReason(env.hub) == PauseReason.MintPathSuspect;
        uint256 hfBefore = IAaveV4Spoke(env.spoke).getUserAccountData(proxy).healthFactor;
        vm.prank(wallet);
        try env.adapter.repayWithCollateral(p) {
            if (suspect) ++gateBreaks;
            uint256 hfAfter = IAaveV4Spoke(env.spoke).getUserAccountData(proxy).healthFactor;
            if (_anyDebt(proxy) && hfAfter < hfBefore) ++gateBreaks;
        } catch {}
    }

    // ─── Liquidators through LPVaultSwap ───

    /// @notice Liquidates with the Lens's parameters when it reports the account liquidatable; with every gate open the
    /// call must settle (TEST-100) and keep every settlement postcondition (TEST-104).
    /// @dev Steered so most calls reach a settlement: the wallet is the first from `w` with debt in the chosen reserve
    /// (the other reserve when none has any), and for three seeds in four an account the Lens does not report
    /// liquidatable is borrowed close to its maximum and has USDT's price lowered so its health factor is 0.85 to 0.99
    /// where USDT's floor allows (`IIntegrationWorld.toHealth`).
    function liquidate(
        uint256 w,
        uint256 callerSeed,
        bool gho,
        bool viaHelper,
        bool backupOnly
    ) external {
        (address wallet, address proxy, bool inGho) = _withDebt(w, gho);
        if (proxy == address(0)) return;
        gho = inGho;
        uint256 reserveId = gho ? env.ghoReserveId : env.usdcReserveId;
        if ((w >> 8) % 4 != 0 && !env.lens.previewLiquidation(proxy, reserveId, block.timestamp).aaveLiquidatable) {
            env.world.toHealth(wallet, reserveId, w >> 16);
        }
        LiquidationPreview memory p = env.lens.previewLiquidation(proxy, reserveId, block.timestamp);
        if (!p.aaveLiquidatable || p.params.debtToCover == 0) return;
        bool open = p.pricesUsable && p.sharesEqualAssets && !p.debtReservePaused && !p.vaultTokenReservePaused;
        if (backupOnly) p.params.routeMode = RouteMode.BackupOnly;
        p.params.maxShortfall = p.params.debtToCover / 20;
        address caller = env.callers[callerSeed % env.callers.length];
        if (viaHelper) _viaHelper(caller, p, open, gho ? env.gho : env.usdc);
        else _direct(caller, wallet, p, open, gho ? env.gho : env.usdc);
    }

    /// @dev The first wallet from `w` whose proxy owes the GHO (`gho`) or USDC reserve, else the first that owes the
    /// other; a zero proxy when no account has debt.
    function _withDebt(
        uint256 w,
        bool gho
    ) internal view returns (address wallet, address proxy, bool inGho) {
        uint256 n = env.wallets.length;
        for (uint256 pass = 0; pass < 2; ++pass) {
            inGho = pass == 0 ? gho : !gho;
            uint256 reserveId = inGho ? env.ghoReserveId : env.usdcReserveId;
            for (uint256 j = 0; j < n; ++j) {
                wallet = env.wallets[(w + j) % n];
                proxy = env.adapter.proxyOf(wallet, env.marketId);
                if (proxy != address(0) && _debt(proxy, reserveId) != 0) return (wallet, proxy, inGho);
            }
        }
        return (address(0), address(0), gho);
    }

    function _direct(
        address caller,
        address wallet,
        LiquidationPreview memory p,
        bool open,
        ClTestToken asset
    ) internal {
        uint256 funding = p.params.debtToCover + p.params.maxShortfall;
        asset.mint(caller, funding);
        vm.prank(caller);
        asset.approve(address(env.lvs), funding);
        uint256 loans = env.v3Pool.flashLoanCalls();
        uint256 supply = ClTestToken(env.vt).totalSupply();
        Held memory before = _held(asset, caller, wallet);
        vm.prank(caller);
        try env.lvs.liquidate(p.params) returns (LiquidationResult memory r) {
            ++liquidations;
            ++directLiquidations;
            _checkSettlement(p, r, asset, supply);
            _checkBalances(before, _held(asset, caller, wallet), r);
            if (env.v3Pool.flashLoanCalls() != loans) ++settlementBreaks;
        } catch (bytes memory err) {
            if (open) _livenessFailed(err);
        }
        vm.prank(caller);
        asset.approve(address(env.lvs), 0);
    }

    function _viaHelper(
        address caller,
        LiquidationPreview memory p,
        bool open,
        ClTestToken asset
    ) internal {
        uint256 f = p.params.debtToCover;
        asset.mint(caller, f + p.params.maxShortfall);
        vm.prank(caller);
        asset.approve(env.helper, f + p.params.maxShortfall);
        FlashLiquidationRequest memory q = FlashLiquidationRequest({
            params: p.params, flashAmount: f, maxPremium: (f * 5 + 9999) / 10_000, maxTopUp: f, minPayout: 0
        });
        vm.prank(caller);
        try IFlashLiquidator(env.helper).flashLiquidate(q) {
            ++liquidations;
            ++helperLiquidations;
        } catch (bytes memory err) {
            if (open) _livenessFailed(err);
        }
        if (asset.balanceOf(env.helper) != 0) ++settlementBreaks;
        vm.prank(caller);
        asset.approve(env.helper, 0);
    }

    /// @dev TEST-104: conservation, floor, `D <= Kf`, Avana fee, waterfall, burn and neutrality of one settlement.
    function _checkSettlement(
        LiquidationPreview memory p,
        LiquidationResult memory r,
        ClTestToken asset,
        uint256 supplyBefore
    ) internal {
        uint256 rf = r.recovered + r.shortfall;
        uint256 s = rf > r.debtRepaid ? rf - r.debtRepaid : 0;
        bool broken = r.callerFunds + rf != r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut || rf < r.minOut
            || r.debtRepaid > r.callerFunds || r.callerFunds != p.params.debtToCover
            || r.avanaFee + r.keeperReward + r.borrowerSurplus != s || r.avanaFee > s
            || r.shortfall > p.params.maxShortfall || r.unitsSeized == 0
            || supplyBefore - ClTestToken(env.vt).totalSupply() != r.unitsSeized
            || asset.balanceOf(address(env.lvs)) != 0 || env.usdt.balanceOf(address(env.lvs)) != 0
            || ClTestToken(env.vt).balanceOf(address(env.lvs)) != 0;
        if (broken) ++settlementBreaks;
    }

    function _held(
        ClTestToken asset,
        address caller,
        address wallet
    ) internal view returns (Held memory b) {
        b.caller = asset.balanceOf(caller);
        b.lvs = asset.balanceOf(address(env.lvs));
        b.hub = asset.balanceOf(env.hub);
        b.fee = asset.balanceOf(env.feeRecipient);
        b.feeEscrowed = env.escrow.claimable(address(asset), env.feeRecipient);
        b.wallet = asset.balanceOf(wallet);
        b.walletEscrowed = env.escrow.claimable(address(asset), wallet);
        b.escrow = asset.balanceOf(address(env.escrow));
        b.parked = asset.balanceOf(env.coll);
        address[] memory sources = asset == env.gho ? env.ghoSources : env.usdcSources;
        for (uint256 i = 0; i < sources.length; ++i) {
            b.sources += asset.balanceOf(sources[i]);
        }
    }

    /// @dev TEST-104 on balances: the debt asset that left the caller and the sources (the LPVault and the route
    /// pools) equals what reached the Hub, the fee recipient and the borrower (paid or escrowed) and Collateralization
    /// (pool tokens of a reconcile, held for `settlePending`); LPVaultSwap's balance is unchanged and the escrow rose by
    /// exactly the escrowed credit. The result's `D`, `A`, `B`, `R` and the caller's net equal those changes.
    function _checkBalances(
        Held memory b,
        Held memory a,
        LiquidationResult memory r
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
    }

    function settlePending(
        uint256 callerSeed,
        bool gho
    ) external {
        vm.prank(env.callers[callerSeed % env.callers.length]);
        try env.lvs.settlePending(env.marketId, gho ? env.ghoReserveId : env.usdcReserveId) {} catch {}
    }

    /// @notice The attacker repays a borrower's debt on the Spoke directly: the vault token admits no seizure to it.
    function directLiquidation(
        uint256 w,
        uint256 amount
    ) external {
        address proxy = env.adapter.proxyOf(env.wallets[w % env.wallets.length], env.marketId);
        if (proxy == address(0)) return;
        amount = bound(amount, 1, 2000e6);
        env.usdc.mint(env.attacker, amount);
        vm.startPrank(env.attacker);
        env.usdc.approve(env.spoke, amount);
        try IAaveV4Spoke(env.spoke).liquidationCall(env.vtReserveId, env.usdcReserveId, proxy, amount, false) {}
            catch {}
        env.usdc.approve(env.spoke, 0);
        vm.stopPrank();
        if (ClTestToken(env.vt).balanceOf(env.attacker) != 0) ++directSeizures;
    }

    // ─── Guardians and environment ───

    function setPause(
        uint256 seed
    ) external {
        uint256 i = seed % 4;
        PauseState s = i == 0 ? PauseState.None : i == 1 ? PauseState.Frozen : PauseState.Paused;
        PauseReason r = i == 2 ? PauseReason.General : i == 3 ? PauseReason.MintPathSuspect : PauseReason.None;
        env.world.setPause(s, r);
    }

    function freeze(
        uint256 w,
        bool on
    ) external {
        env.world.freezeWallet(env.wallets[w % env.wallets.length], on);
    }

    /// @notice USDT at $0.82 to $1.02 (the vault token about -9.4 % to +1.0 %), the market pool at the new rate.
    function movePrice(
        uint256 price8
    ) external {
        env.world.moveUsdt(bound(price8, 82_000_000, 102_000_000));
    }

    function moveRoutes(
        uint256 rate
    ) external {
        env.world.moveRoutes(bound(rate, 9950, 10_040));
    }

    function warp(
        uint256 secs
    ) external {
        env.world.warp(bound(secs, 1, 1 days));
    }

    // ─── Internals ───

    function _debt(
        address proxy,
        uint256 reserveId
    ) internal view returns (uint256) {
        return IAaveV4Spoke(env.spoke).getUserTotalDebt(reserveId, proxy);
    }

    function _anyDebt(
        address proxy
    ) internal view returns (bool) {
        return IAaveV4Spoke(env.spoke).getUserAccountData(proxy).borrowCount != 0;
    }

    function _fundApprove(
        ClTestToken asset,
        address wallet,
        uint256 amount
    ) internal {
        if (amount != 0) asset.mint(wallet, amount);
        vm.prank(wallet);
        asset.approve(address(env.adapter), amount);
    }

    /// @dev An exit refused: by a stop (INV-081) it is a stop violation; any refusal is an exit failure.
    function _exitFailed(
        bytes memory err
    ) internal {
        bytes4 s = bytes4(err);
        if (
            s == IAaveAdapterErrors.ApplicationFrozen.selector || s == IAaveAdapterErrors.ApplicationPaused.selector
                || s == IAaveAdapterErrors.AddressIsFrozen.selector || s == IRiskModuleErrors.BreakerTripped.selector
                || s == IRiskModuleErrors.DebtBreakerTripped.selector
        ) ++exitBlockedByStop;
        ++exitFailures;
        lastFailure = err;
    }

    function _livenessFailed(
        bytes memory err
    ) internal {
        ++livenessFailures;
        lastFailure = err;
    }
}
