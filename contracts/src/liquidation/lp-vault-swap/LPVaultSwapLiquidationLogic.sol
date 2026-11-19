// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaFirstLossReserve} from "../../coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ICollateralization} from "../../legacy/ICollateralization.sol";
import {ILegacyLPOracle} from "../../legacy/ILegacyLPOracle.sol";
import {ILegacyVaultToken} from "../../legacy/ILegacyVaultToken.sol";
import {ILock} from "../../legacy/ILock.sol";
import {IAaveAdapter} from "../../policy/aave-adapter/IAaveAdapter.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/MarketRegistryTypes.sol";
import {IParameterStore} from "../../policy/parameter-store/IParameterStore.sol";
import {Market} from "../../types/MarketTypes.sol";
import {SettlementReport} from "../../types/PositionTypes.sol";
import {ILPVaultSwapLogic} from "./ILPVaultSwapLogic.sol";
import {LPVaultSwapSettlement} from "./LPVaultSwapSettlement.sol";
import {LPVaultSwapStorage} from "./LPVaultSwapStorage.sol";
import {SettlementMath} from "./SettlementMath.sol";
import {LPVaultSwapImmutables, LiquidationParams, LiquidationResult} from "./types/LPVaultSwapTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// The events report amounts known only after the transfers; the whole body runs under the Lock.
// forge-lint: disable-start(reentrancy-events)
/// @title LPVaultSwapLiquidationLogic
/// @notice Body of `liquidate`, run by delegatecall from the LPVaultSwap implementation in the proxy's storage.
// Inherits no LPVaultSwap interface piece: each piece also declares functions another logic contract serves.
// solhint-disable comprehensive-interface
contract LPVaultSwapLiquidationLogic is LPVaultSwapSettlement, ILPVaultSwapLogic {
    using SafeERC20 for IERC20;

    struct Liq {
        Market m;
        DebtReserveDef d;
        uint256 hf;
        uint256 kf;
        uint256 debtRepaid;
        uint256 units;
        uint256 pc;
        uint256 pdebt;
        uint256 bNet;
        uint256 s;
        uint256 value;
        uint256 minRec;
        uint256 recovered;
        uint256[] amounts;
        uint8[] routeUsed;
        Tracked t;
        uint256 deficitBefore;
        uint256 funded;
        uint256 fundedShares;
        uint256 collateralValue;
        uint256 debtValueRay;
        bool otherDebt;
        bool deficit;
        bool underwater;
    }

    /// @notice Fixes the implementation immutables; they must equal the implementation's.
    constructor(
        LPVaultSwapImmutables memory im
    ) LPVaultSwapStorage(im) {}

    /// @inheritdoc ILPVaultSwapLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("LPVaultSwapLiquidationLogic"), _IMMUTABLES_HASH);
    }

    /// @notice Body of `liquidate`.
    function liquidate(
        LiquidationParams calldata p
    ) external returns (LiquidationResult memory result) {
        _onlyDelegated();
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        ILock(_LOCK).acquire();
        Liq memory c = _entryChecks(p);
        _fund(c, p);
        _seize(c, p);
        _unwindAndSwap(c, p);
        result = _waterfall(c, p);
        // Clears the indebted mark if the account has no Aave borrow left; Collateralization checks it itself.
        ICollateralization(_COLLATERALIZATION).markDebtFree(p.proxy);
        ILock(_LOCK).release();
    }

    /// @dev HF is read after both pokes so it matches the one Aave applies in `liquidationCall`.
    function _entryChecks(
        LiquidationParams calldata p
    ) private returns (Liq memory c) {
        if (p.debtToCover == 0 || p.debtToCover > type(uint128).max || p.maxShortfall > type(uint128).max) {
            revert InvalidAmount();
        }
        c.m = _loadMarket(p.marketId);
        if (p.minAmounts.length != 0 && p.minAmounts.length != c.m.tokens.length) revert InvalidAmount();
        if (!ILegacyVaultToken(c.m.vaultToken).isValidProxy(p.proxy)) revert UnknownProxy();
        c.d = _loadDebtReserve(c.m.spoke, p.debtReserveId);
        _requireSharesEqualAssets(c.m.hub, c.m.hubAssetId);
        _checkCollateralPrice(c.m.lpOracle);
        _checkDebtPrice(c.d, p.debtReserveId);
        IAaveV4Spoke.UserAccountData memory account = IAaveV4Spoke(c.m.spoke).getUserAccountData(p.proxy);
        c.hf = account.healthFactor;
        // Debt in more than one reserve; nothing before `liquidationCall` changes it (the Lock is held).
        c.otherDebt = account.borrowCount > 1;
        c.collateralValue = account.totalCollateralValue;
        c.debtValueRay = account.totalDebtValueRay;
        if (c.hf >= _HF_ONE) revert NotLiquidatable();
    }

    function _fund(
        Liq memory c,
        LiquidationParams calldata p
    ) private {
        IERC20 asset = IERC20(c.d.asset);
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), p.debtToCover);
        uint256 afterFunding = asset.balanceOf(address(this));
        if (afterFunding <= before || afterFunding - before > p.debtToCover) revert FundingMismatch();
        c.kf = afterFunding - before;
    }

    function _seize(
        Liq memory c,
        LiquidationParams calldata p
    ) private {
        IAaveV4Spoke spoke = IAaveV4Spoke(c.m.spoke);
        uint256 collateralReserve = c.m.reserveId;
        uint256 bonus = spoke.getLiquidationBonus(collateralReserve, p.proxy, c.hf);
        c.underwater = _underwater(c.collateralValue, c.debtValueRay, bonus);
        uint32 key = spoke.getUserPosition(collateralReserve, p.proxy).dynamicConfigKey;
        c.bNet = SettlementMath.netBonus(bonus, spoke.getDynamicReserveConfig(collateralReserve, key).liquidationFee);
        c.pc = _collateralPrice(c.m);
        c.pdebt = _debtPrice(c.m.spoke, p.debtReserveId, c.d);
        ICollateralization(_COLLATERALIZATION).beginSeizure(p.proxy, c.m.vaultToken);
        IERC20 asset = IERC20(c.d.asset);
        IERC20 vt = IERC20(c.m.vaultToken);
        uint256 units0 = vt.balanceOf(address(this));
        uint256 debt0 = asset.balanceOf(address(this));
        // Under the Lock only this call can raise the Spoke's deficit.
        c.deficitBefore = _spokeDeficit(c.d, address(spoke));
        asset.forceApprove(address(spoke), c.kf);
        spoke.liquidationCall(collateralReserve, p.debtReserveId, p.proxy, c.kf, false);
        asset.forceApprove(address(spoke), 0);
        uint256 units1 = vt.balanceOf(address(this));
        uint256 debt1 = asset.balanceOf(address(this));
        c.units = units1 > units0 ? units1 - units0 : 0;
        c.debtRepaid = debt0 > debt1 ? debt0 - debt1 : 0;
        if (c.units == 0) revert NothingSeized();
        c.deficit = _spokeDeficit(c.d, address(spoke)) > c.deficitBefore
            || (c.otherDebt && spoke.getUserAccountData(p.proxy).borrowCount == 0);
    }

    /// @dev Collateral value below debt value times the bonus, so the collateral runs out first.
    function _underwater(
        uint256 collateralValue,
        uint256 debtValueRay,
        uint256 bonus
    ) private pure returns (bool) {
        return collateralValue * SettlementMath.BPS < Math.mulDiv(debtValueRay, bonus, 1e27, Math.Rounding.Ceil);
    }

    /// @dev The Spoke's deficit of the debt asset on its funding Hub (ray).
    function _spokeDeficit(
        DebtReserveDef memory d,
        address spoke
    ) private view returns (uint256) {
        return IAaveV4Hub(d.fundingHub).getSpokeDeficitRay(d.hubAssetId, spoke);
    }

    function _unwindAndSwap(
        Liq memory c,
        LiquidationParams calldata p
    ) private {
        IERC20 asset = IERC20(c.d.asset);
        uint256 n = c.m.tokens.length;
        c.t = _snapshot(c.m.tokens, c.d.asset);
        uint256 r0 = asset.balanceOf(address(this));
        IAaveAdapter(_AAVE_ADAPTER).burnSeized(p.marketId, c.m.vaultToken, c.units);
        uint256[] memory mins = p.minAmounts.length == 0 ? new uint256[](n) : p.minAmounts;
        // The released amounts are measured as balance changes, never read from returns.
        // forge-lint: disable-next-line(unused-return)
        ICollateralization(_COLLATERALIZATION).settleSeizure(p.proxy, c.m.vaultToken, c.units, mins);
        c.amounts = _released(c.t, n);
        LegArgs memory l = _legArgs(c, p);
        c.value = SettlementMath.seizedValue(c.units, c.pc, c.m.decimals, c.d.decimals, c.pdebt);
        c.minRec = SettlementMath.recoveryFloor(c.value, c.s, _unitSum(l), l.allowance);
        l.sLeg = SettlementMath.legSlippage(
            c.s, p.maxShortfall, c.value, IParameterStore(_PARAMETER_STORE).maxShortfallBps()
        );
        c.routeUsed = _swapLegs(l, c.t);
        uint256 r1 = asset.balanceOf(address(this));
        c.recovered = r1 > r0 ? r1 - r0 : 0;
    }

    function _legArgs(
        Liq memory c,
        LiquidationParams calldata p
    ) private view returns (LegArgs memory l) {
        IParameterStore ps = IParameterStore(_PARAMETER_STORE);
        c.s = SettlementMath.effectiveSlippage(c.bNet, ps.getMarketParams(p.marketId).slippageAllowanceBps);
        // Only the leg prices are used; the decimals come from the market record.
        // forge-lint: disable-next-line(unused-return)
        (uint256[] memory prices,) = ILegacyLPOracle(c.m.lpOracle).getTokenPrices();
        l = LegArgs({
            marketId: p.marketId,
            asset: c.d.asset,
            assetDecimals: c.d.decimals,
            assetPrice: c.pdebt,
            sLeg: c.s,
            allowance: ps.floorRoundingAllowance(c.d.asset),
            mode: p.routeMode,
            tokens: c.m.tokens,
            decimals: c.m.tokenDecimals,
            prices: prices,
            amounts: c.amounts
        });
    }

    /// @dev A revert in `fund` is caught; a return shorter than 32 bytes still reverts the liquidation.
    function _fundReserve(
        Liq memory c,
        uint256 amount
    ) private {
        address reserve = c.d.firstLossReserve;
        if (reserve.code.length == 0) return;
        IERC20 asset = IERC20(c.d.asset);
        uint256 before = asset.balanceOf(address(this));
        asset.forceApprove(reserve, amount);
        try IAvanaFirstLossReserve(reserve).fund(amount) returns (uint256 shares) {
            c.fundedShares = shares;
        } catch {}
        asset.forceApprove(reserve, 0);
        uint256 balance = asset.balanceOf(address(this));
        if (balance < before) c.funded = before - balance > amount ? amount : before - balance;
    }

    function _waterfall(
        Liq memory c,
        LiquidationParams calldata p
    ) private returns (LiquidationResult memory res) {
        IERC20 asset = IERC20(c.d.asset);
        SettlementMath.Payouts memory pay = SettlementMath.payouts(
            c.value,
            c.debtRepaid,
            SettlementMath.recoveryWithFloor(c.minRec, c.recovered),
            IParameterStore(_PARAMETER_STORE).avanaFeeShareBps()
        );
        uint256 gap = SettlementMath.roundingGap(c.debtRepaid, pay.avanaFee, pay.borrowerSurplus, c.kf, c.recovered);
        uint256 shortfall = SettlementMath.shortfallTopUp(c.minRec, c.recovered, gap, p.maxShortfall);
        if (shortfall != 0) {
            uint256 before = asset.balanceOf(address(this));
            asset.safeTransferFrom(msg.sender, address(this), shortfall);
            // Exact balance-delta check of the shortfall pull.
            // forge-lint: disable-next-line(incorrect-strict-equality)
            if (asset.balanceOf(address(this)) != before + shortfall) revert FundingMismatch();
        }
        uint256 keeperOut =
            SettlementMath.keeperPayout(c.kf, c.recovered + shortfall, c.debtRepaid, pay.avanaFee, pay.borrowerSurplus);
        if (keeperOut < p.minPayout) revert PayoutTooLow(keeperOut, p.minPayout);
        address feeRecipient = IParameterStore(_PARAMETER_STORE).feeRecipient();
        if (feeRecipient == address(0)) revert InvalidFeeRecipient();
        uint256[] memory residues = _residues(c.t);
        _deliver(address(asset), feeRecipient, pay.avanaFee);
        uint256 toWallet = pay.borrowerSurplus;
        if (toWallet != 0 && (c.deficit || c.underwater)) {
            _fundReserve(c, toWallet);
            if (c.funded != 0) {
                toWallet -= c.funded;
                emit DeficitSurplusFunded(p.proxy, c.d.firstLossReserve, address(asset), c.funded, c.fundedShares);
            }
        }
        if (toWallet != 0) {
            address wallet = IAaveAdapter(_AAVE_ADAPTER).walletOf(p.proxy);
            bool escrowed = _deliver(address(asset), wallet, toWallet);
            emit BorrowerSurplusPaid(p.proxy, wallet, address(asset), toWallet, escrowed);
        }
        if (keeperOut != 0) asset.safeTransfer(msg.sender, keeperOut);
        for (uint256 i = 0; i < c.t.count; ++i) {
            if (residues[i] == 0) continue;
            bool escrowed = _deliver(c.t.tokens[i], msg.sender, residues[i]);
            emit ResidueReturned(msg.sender, c.t.tokens[i], residues[i], escrowed);
        }
        res = LiquidationResult({
            debtAsset: address(asset),
            debtRepaid: c.debtRepaid,
            unitsSeized: c.units,
            amountsOut: c.amounts,
            callerFunds: c.kf,
            recovered: c.recovered,
            minOut: c.minRec,
            avanaFee: pay.avanaFee,
            keeperReward: pay.keeperReward,
            keeperOut: keeperOut,
            borrowerSurplus: pay.borrowerSurplus,
            shortfall: shortfall
        });
        _emitSettled(c, p, pay, res);
    }

    function _emitSettled(
        Liq memory c,
        LiquidationParams calldata p,
        SettlementMath.Payouts memory pay,
        LiquidationResult memory res
    ) private {
        emit LiquidationSettled(
            msg.sender,
            p.proxy,
            p.marketId,
            SettlementReport({
                debtReserveId: p.debtReserveId,
                debtAsset: res.debtAsset,
                debtRepaid: res.debtRepaid,
                unitsSeized: res.unitsSeized,
                amountsOut: res.amountsOut,
                recovered: res.recovered,
                minOut: res.minOut,
                effectiveSlippageBps: c.s,
                bonusBps: c.bNet,
                callerFunds: res.callerFunds,
                surplus: pay.surplus,
                avanaFee: res.avanaFee,
                keeperReward: res.keeperReward,
                borrowerSurplus: res.borrowerSurplus,
                keeperOut: res.keeperOut,
                minPayout: p.minPayout,
                routeMode: p.routeMode,
                routeUsed: c.routeUsed,
                shortfall: res.shortfall
            })
        );
    }
}
// forge-lint: disable-end(reentrancy-events)
