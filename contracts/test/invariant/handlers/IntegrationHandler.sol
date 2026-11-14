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
import {IRiskModuleErrors} from "../../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {MockAaveV3Pool} from "../../utils/mocks/AaveV3PoolMocks.sol";
import {CollPoolToken} from "../../utils/mocks/CollateralizationMocks.sol";
import {IntegLPVaultMock} from "../../utils/mocks/IntegLPVaultMock.sol";
import {IntegDebtOracleMock, IntegLPOracleMock} from "../../utils/mocks/IntegOracleMocks.sol";
import {IntegRegistryMock} from "../../utils/mocks/IntegrationMocks.sol";
import {MockCLPool} from "../../utils/mocks/SwapRouteMocks.sol";
import {Held, IntegrationBalanceChecks} from "./IntegrationBalanceChecks.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title IntegrationHandler
/// @notice Actions of the integration invariant suite on the deployed stack, every one through a real entry point:
/// borrowers (pledge, borrow GHO and USDC, repay by any payer, debt-free withdrawal, `repayAllAndWithdraw`, repay with
/// collateral) through the AaveAdapter; liquidators (Avana's keeper, unregistered addresses and the public flash
/// liquidation helper, both route modes) and `settlePending` through LPVaultSwap; an attacker's direct
/// `liquidationCall`; the guardians (pause state and reason, address freeze); and the environment (vault price, feed
/// time, route rates). Ghosts record every rule an action must keep, so the suite asserts them after every call.
/// @dev Liveness (TEST-100, fail_on_revert for the live actions): an account the Lens reports liquidatable with every
/// gate open must settle with the Lens's own parameters; exits must settle whenever their own checks pass. Their
/// failures are counted, not swallowed.
contract IntegrationHandler is CommonBase, StdCheats, StdUtils {
    struct Env {
        IAaveAdapter adapter;
        ILPVaultSwap lvs;
        address helper;
        ILens lens;
        IntegRegistryMock reg;
        IntegLPOracleMock lpo;
        IntegDebtOracleMock usdcOracle;
        IntegLPVaultMock vault;
        MockAaveV3Pool v3Pool;
        MockCLPool primaryPool;
        CollPoolToken usdc;
        CollPoolToken usdt;
        CollPoolToken gho;
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
        // Holders a liquidation's unwind and swaps pay each debt asset from: the LPVault and the route pools into it.
        address[] usdcSources;
        address[] ghoSources;
    }

    Env internal env;
    mapping(address => bytes32[]) internal _keys;
    uint256 internal _nonce;

    uint256 public liquidations;
    /// @notice Direct liquidations that completed (each checked on balances).
    uint256 public directLiquidations;
    /// @notice Liquidations through the public flash liquidation helper that completed.
    uint256 public helperLiquidations;
    uint256 public settlementBreaks;
    /// @notice Liquidations (direct or through the helper) whose debt-asset balances do not balance (TEST-104 on
    /// balances).
    uint256 public conservationBreaks;
    /// @notice Liquidations whose result (direct) or `FlashLiquidated` event (helper) does not report the balance
    /// changes.
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
        bytes32 key = keccak256(abi.encode("handler position", ++_nonce));
        env.vault.mintPosition(key, wallet, env.marketId, uint128(units));
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
        CollPoolToken asset = gho ? env.gho : env.usdc;
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
    /// liquidatable has the LPOracle price lowered so its health factor is 0.85 to 0.99.
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
            _toHealth(proxy, w >> 16);
        }
        LiquidationPreview memory p = env.lens.previewLiquidation(proxy, reserveId, block.timestamp);
        if (!p.aaveLiquidatable || p.params.debtToCover == 0) return;
        bool open = p.pricesUsable && p.sharesEqualAssets && !p.debtReservePaused && !p.vaultTokenReservePaused;
        if (backupOnly) p.params.routeMode = RouteMode.BackupOnly;
        p.params.maxShortfall = p.params.debtToCover / 20;
        address caller = env.callers[callerSeed % env.callers.length];
        if (viaHelper) _viaHelper(caller, wallet, p, open, gho ? env.gho : env.usdc);
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

    /// @dev Lowers the LPOracle price so `proxy`'s health factor is 0.85 to 0.99 (HF is linear in the collateral
    /// price; both debt assets are priced at $1).
    function _toHealth(
        address proxy,
        uint256 seed
    ) internal {
        uint256 hf = IAaveV4Spoke(env.spoke).getUserAccountData(proxy).healthFactor;
        uint256 price = uint256(env.lpo.latestAnswer()) * bound(seed, 85, 99) * 1e16 / hf;
        // At most 0.99 / HF times the current price, far below 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        env.lpo.setAnswer(int256(price));
    }

    function _direct(
        address caller,
        address wallet,
        LiquidationPreview memory p,
        bool open,
        CollPoolToken asset
    ) internal {
        uint256 funding = p.params.debtToCover + p.params.maxShortfall;
        asset.mint(caller, funding);
        vm.prank(caller);
        asset.approve(address(env.lvs), funding);
        uint256 loans = env.v3Pool.flashLoanCalls();
        uint256 supply = CollPoolToken(env.vt).totalSupply();
        Held memory before = _held(asset, caller, wallet);
        vm.prank(caller);
        try env.lvs.liquidate(p.params) returns (LiquidationResult memory r) {
            ++liquidations;
            ++directLiquidations;
            _checkSettlement(p, r, asset, supply);
            _tallyDirect(before, _held(asset, caller, wallet), r);
            if (env.v3Pool.flashLoanCalls() != loans) ++settlementBreaks;
        } catch (bytes memory err) {
            if (open) _livenessFailed(err);
        }
        vm.prank(caller);
        asset.approve(address(env.lvs), 0);
    }

    function _viaHelper(
        address caller,
        address wallet,
        LiquidationPreview memory p,
        bool open,
        CollPoolToken asset
    ) internal {
        uint256 f = p.params.debtToCover;
        asset.mint(caller, f + p.params.maxShortfall);
        vm.prank(caller);
        asset.approve(env.helper, f + p.params.maxShortfall);
        FlashLiquidationRequest memory q = FlashLiquidationRequest({
            params: p.params, flashAmount: f, maxPremium: (f * 5 + 9999) / 10_000, maxTopUp: f, minPayout: 0
        });
        Held memory before = _held(asset, caller, wallet);
        vm.recordLogs();
        vm.prank(caller);
        try IFlashLiquidator(env.helper).flashLiquidate(q) returns (uint256 payout) {
            ++liquidations;
            ++helperLiquidations;
            _tallyHelper(before, _held(asset, caller, wallet), q, payout);
        } catch (bytes memory err) {
            if (open) _livenessFailed(err);
        }
        if (asset.balanceOf(env.helper) != 0) ++settlementBreaks;
        vm.prank(caller);
        asset.approve(env.helper, 0);
    }

    /// @dev TEST-104 on balances of a direct liquidation (IntegrationBalanceChecks.direct, a linked library, so the
    /// handler stays within EIP-170).
    function _tallyDirect(
        Held memory b,
        Held memory a,
        LiquidationResult memory r
    ) internal {
        (bool conserved, bool reported) = IntegrationBalanceChecks.direct(b, a, r);
        if (!conserved) ++conservationBreaks;
        if (!reported) ++reportBreaks;
    }

    /// @dev TEST-104 on balances through the helper, with its `FlashLiquidated` report (IntegrationBalanceChecks.viaHelper).
    function _tallyHelper(
        Held memory b,
        Held memory a,
        FlashLiquidationRequest memory q,
        uint256 payout
    ) internal {
        (bool conserved, bool reported) =
            IntegrationBalanceChecks.viaHelper(b, a, q, payout, vm.getRecordedLogs(), env.helper);
        if (!conserved) ++conservationBreaks;
        if (!reported) ++reportBreaks;
    }

    /// @dev TEST-104: conservation, floor, `D <= Kf`, Avana fee, waterfall, burn and neutrality of one settlement.
    function _checkSettlement(
        LiquidationPreview memory p,
        LiquidationResult memory r,
        CollPoolToken asset,
        uint256 supplyBefore
    ) internal {
        uint256 rf = r.recovered + r.shortfall;
        uint256 s = rf > r.debtRepaid ? rf - r.debtRepaid : 0;
        bool broken = r.callerFunds + rf != r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut || rf < r.minOut
            || r.debtRepaid > r.callerFunds || r.callerFunds != p.params.debtToCover
            || r.avanaFee + r.keeperReward + r.borrowerSurplus != s || r.avanaFee > s
            || r.shortfall > p.params.maxShortfall || r.unitsSeized == 0
            || supplyBefore - CollPoolToken(env.vt).totalSupply() != r.unitsSeized
            || asset.balanceOf(address(env.lvs)) != 0 || env.usdt.balanceOf(address(env.lvs)) != 0
            || CollPoolToken(env.vt).balanceOf(address(env.lvs)) != 0;
        if (broken) ++settlementBreaks;
    }

    function _held(
        CollPoolToken asset,
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
        b.lender = asset.balanceOf(env.v3Pool.getReserveAToken(address(asset)));
        b.helper = asset.balanceOf(env.helper);
        b.helperEscrowed = env.escrow.claimable(address(asset), env.helper);
        address[] memory sources = asset == env.gho ? env.ghoSources : env.usdcSources;
        for (uint256 i = 0; i < sources.length; ++i) {
            b.sources += asset.balanceOf(sources[i]);
        }
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
        if (CollPoolToken(env.vt).balanceOf(env.attacker) != 0) ++directSeizures;
    }

    // ─── Guardians and environment ───

    function setPause(
        uint256 seed
    ) external {
        uint256 i = seed % 4;
        PauseState s = i == 0 ? PauseState.None : i == 1 ? PauseState.Frozen : PauseState.Paused;
        PauseReason r = i == 2 ? PauseReason.General : i == 3 ? PauseReason.MintPathSuspect : PauseReason.None;
        env.reg.setPause(env.hub, s, r);
    }

    function freeze(
        uint256 w,
        bool on
    ) external {
        env.reg.setFrozen(env.wallets[w % env.wallets.length], on);
    }

    function movePrice(
        uint256 price8
    ) external {
        env.lpo.setAnswer(int256(bound(price8, 150_000_000, 230_000_000)));
    }

    function moveRoutes(
        uint256 rate
    ) external {
        env.primaryPool.setRate(bound(rate, 9950, 10_040), 10_000);
    }

    function warp(
        uint256 secs
    ) external {
        vm.warp(block.timestamp + bound(secs, 1, 1 days));
        vm.roll(block.number + 1);
        env.lpo.refresh(uint64(block.timestamp));
        env.usdcOracle.setLeg(uint64(block.timestamp));
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
        CollPoolToken asset,
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
