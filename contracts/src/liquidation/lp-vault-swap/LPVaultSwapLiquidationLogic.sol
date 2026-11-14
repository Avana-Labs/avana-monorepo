// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../custody/collateralization/ICollateralization.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILock} from "../../lock/lock/ILock.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {IAaveAdapter} from "../../policy/aave-adapter/IAaveAdapter.sol";
import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {IParameterStore} from "../../policy/parameter-store/IParameterStore.sol";
import {Market} from "../../types/Market.sol";
import {SettlementReport} from "../../types/SettlementReport.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {ILPVaultSwapLogic} from "./ILPVaultSwapLogic.sol";
import {LPVaultSwapSettlement} from "./LPVaultSwapSettlement.sol";
import {LPVaultSwapStorage} from "./LPVaultSwapStorage.sol";
import {SettlementMath} from "./SettlementMath.sol";
import {LPVaultSwapImmutables} from "./types/LPVaultSwapImmutables.sol";
import {LiquidationParams} from "./types/LiquidationParams.sol";
import {LiquidationResult} from "./types/LiquidationResult.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// LiquidationSettled, BorrowerSurplusPaid and ResidueReturned report amounts known only after the transfers; the
// whole body runs under the Lock (REQ-SWAP-002), so no Avana entry point can re-enter and reorder them.
// forge-lint: disable-start(reentrancy-events)
/// @title LPVaultSwapLiquidationLogic
/// @notice Body of `liquidate`, the one liquidation entry point, run by delegatecall from the LPVaultSwap
/// implementation in the proxy's storage: entry checks, the caller's funding, Aave's seizure, burn and unwind, the
/// swap legs, the recovery floor with the caller's top-up and the waterfall.
/// @dev Order (2.11): deadline, caller freeze, Lock; amounts, market, proxy, debt reserve, HF, Hub shares, the
/// LPOracle `poke()` and collateral price rule, the debt price rule, grace; funding `Kf` by balance delta; bonus and
/// prices; `beginSeizure`; `liquidationCall` with `Kf` as Aave's bound; `D` and `c` by delta; `burnSeized` and
/// `settleSeizure`; legs at their minimums; `R`; floor, gap, shortfall pull; `keeperOut`, `minPayout`; `A`, `B`,
/// `keeperOut`, residues; `LiquidationSettled`; `markDebtFree`; Lock release. Reads no pause state, breaker or committed-operator
/// registry and takes no flash loan.
/// @custom:spec REQ-SWAP-001, REQ-SWAP-002, REQ-SWAP-003, REQ-SWAP-005, REQ-SWAP-006, REQ-SWAP-009, REQ-SWAP-011, REQ-SWAP-012, REQ-SWAP-015, REQ-SWAP-016, REQ-SWAP-017, REQ-SWAP-020, REQ-SWAP-025, REQ-SWAP-026, REQ-SWAP-028, REQ-SWAP-072, REQ-SWAP-074, REQ-SWAP-075, REQ-SWAP-105, SPEC-LIQ-006, SPEC-LIQ-010, SPEC-LIQ-019
// Each function carries the body of a selector LPVaultSwap declares and delegates here; this contract inherits no
// LPVaultSwap interface piece, since each piece also declares functions another logic contract serves.
// solhint-disable comprehensive-interface
contract LPVaultSwapLiquidationLogic is LPVaultSwapSettlement, ILPVaultSwapLogic {
    using SafeERC20 for IERC20;

    /// @dev Working values of one liquidation, in memory (REQ-SWAP-019: per-call deltas and snapshots only).
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
    }

    /// @notice Fixes the implementation immutables; they must equal the implementation's.
    /// @param im The per-chain addresses and the keeper floor.
    /// @custom:spec REQ-SWAP-040
    constructor(
        LPVaultSwapImmutables memory im
    ) LPVaultSwapStorage(im) {}

    /// @inheritdoc ILPVaultSwapLogic
    /// @custom:spec REQ-SWAP-040
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("LPVaultSwapLiquidationLogic"), _IMMUTABLES_HASH);
    }

    /// @notice Body of `liquidate`.
    /// @dev See `ILPVaultSwapLiquidation.liquidate`; the implementation forwards its calldata unchanged.
    /// @custom:spec REQ-SWAP-001, REQ-SWAP-002, REQ-SWAP-072, REQ-SWAP-073, REQ-SWAP-074, REQ-SWAP-105, REQ-SWAP-041, REQ-SWAP-093, REQ-COLL-040
    function liquidate(
        LiquidationParams calldata p
    ) external returns (LiquidationResult memory result) {
        _onlyDelegated();
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (IMarketRegistry(_MARKET_REGISTRY).isFrozenAddress(msg.sender)) revert AddressIsFrozen(msg.sender);
        ILock(_LOCK).acquire();
        Liq memory c = _entryChecks(p);
        _fund(c, p);
        _seize(c, p);
        _unwindAndSwap(c, p);
        result = _waterfall(c, p);
        // REQ-COLL-040: a liquidation that leaves the account with no Aave borrow (its last debt repaid, or the rest
        // reported as deficit) clears its indebted mark; Collateralization reads `borrowCount` itself.
        ICollateralization(_COLLATERALIZATION).markDebtFree(p.proxy);
        ILock(_LOCK).release();
    }

    /// @dev Amounts, market, proxy, debt reserve, Hub shares, the two price rules, then HF and grace. The health factor
    /// is read after both pokes: a poke can move the price Aave reads in the same block (the LPOracle's token-decimals
    /// check runs only in `poke()`), and the HF checked here, the grace check and the bonus `_seize` reads must be the
    /// one Aave applies in `liquidationCall`.
    /// @custom:spec REQ-SWAP-004, REQ-SWAP-005, REQ-SWAP-006, REQ-SWAP-007, REQ-SWAP-008, REQ-SWAP-009, REQ-SWAP-087, REQ-SWAP-091
    function _entryChecks(
        LiquidationParams calldata p
    ) private returns (Liq memory c) {
        if (p.debtToCover == 0 || p.debtToCover > type(uint128).max || p.maxShortfall > type(uint128).max) {
            revert InvalidAmount();
        }
        c.m = _loadMarket(p.marketId);
        if (p.minAmounts.length != 0 && p.minAmounts.length != c.m.tokens.length) revert InvalidAmount();
        if (!IVaultToken(c.m.vaultToken).isValidProxy(p.proxy)) revert UnknownProxy();
        c.d = _loadDebtReserve(c.m.spoke, p.debtReserveId);
        _requireSharesEqualAssets(c.m.hub, c.m.hubAssetId);
        bool inGrace = _checkCollateralPrice(c.m.lpOracle);
        _checkDebtPrice(c.d, p.debtReserveId);
        c.hf = IAaveV4Spoke(c.m.spoke).getUserAccountData(p.proxy).healthFactor;
        if (c.hf >= _HF_ONE) revert NotLiquidatable();
        if (inGrace && c.hf >= IParameterStore(_PARAMETER_STORE).graceHealthFactor()) revert GraceHealthFactor();
    }

    /// @dev Pulls `X` from `msg.sender` and measures `Kf` (`FundingMismatch` unless `0 < Kf <= X`).
    /// @custom:spec REQ-SWAP-011, REQ-SWAP-088, REQ-SWAP-098, REQ-SWAP-108
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

    /// @dev Bonus, fee and prices; `beginSeizure`; `liquidationCall(collateral, debt, proxy, Kf, false)` with an exact
    /// allowance reset to 0; `D` and `c` as deltas (`NothingSeized` if `c == 0`).
    /// @custom:spec REQ-SWAP-015, REQ-SWAP-016, REQ-SWAP-017, REQ-SWAP-090, SPEC-LIQ-001, SPEC-LIQ-004
    function _seize(
        Liq memory c,
        LiquidationParams calldata p
    ) private {
        IAaveV4Spoke spoke = IAaveV4Spoke(c.m.spoke);
        uint256 collateralReserve = c.m.reserveId;
        uint256 bonus = spoke.getLiquidationBonus(collateralReserve, p.proxy, c.hf);
        uint32 key = spoke.getUserPosition(collateralReserve, p.proxy).dynamicConfigKey;
        c.bNet = SettlementMath.netBonus(bonus, spoke.getDynamicReserveConfig(collateralReserve, key).liquidationFee);
        c.pc = _collateralPrice(c.m);
        c.pdebt = _debtPrice(c.m.spoke, p.debtReserveId, c.d);
        ICollateralization(_COLLATERALIZATION).beginSeizure(p.proxy, c.m.vaultToken);
        IERC20 asset = IERC20(c.d.asset);
        IERC20 vt = IERC20(c.m.vaultToken);
        uint256 units0 = vt.balanceOf(address(this));
        uint256 debt0 = asset.balanceOf(address(this));
        asset.forceApprove(address(spoke), c.kf);
        spoke.liquidationCall(collateralReserve, p.debtReserveId, p.proxy, c.kf, false);
        asset.forceApprove(address(spoke), 0);
        uint256 units1 = vt.balanceOf(address(this));
        uint256 debt1 = asset.balanceOf(address(this));
        c.units = units1 > units0 ? units1 - units0 : 0;
        c.debtRepaid = debt0 > debt1 ? debt0 - debt1 : 0;
        if (c.units == 0) revert NothingSeized();
    }

    /// @dev `burnSeized` and `settleSeizure` measured as deltas, then the legs and `R` over the burn, the release and
    /// the route calls only.
    /// @custom:spec REQ-SWAP-020, REQ-SWAP-021, REQ-SWAP-044, REQ-SWAP-045, REQ-SWAP-092, SPEC-LIQ-003, SPEC-LIQ-005, SPEC-LIQ-006
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
        // R and the released amounts are measured as LPVaultSwap balance changes (REQ-SWAP-108), never read from returns.
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

    /// @dev The leg inputs: leg prices after `poke()`, `ε`, and `s` from the net bonus and the market's allowance.
    function _legArgs(
        Liq memory c,
        LiquidationParams calldata p
    ) private view returns (LegArgs memory l) {
        IParameterStore ps = IParameterStore(_PARAMETER_STORE);
        c.s = SettlementMath.effectiveSlippage(c.bNet, ps.getMarketParams(p.marketId).slippageAllowanceBps);
        // Only the leg prices are used; the decimals come from the market record, the timestamp from getPriceState.
        // forge-lint: disable-next-line(unused-return)
        (uint256[] memory prices,,) = ILPOracle(c.m.lpOracle).getTokenPrices();
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

    /// @dev Floor, gap and shortfall pull; `keeperOut` and `minPayout`; payouts in order; the event.
    /// @custom:spec REQ-SWAP-025, REQ-SWAP-026, REQ-SWAP-027, REQ-SWAP-028, REQ-SWAP-075, REQ-SWAP-101, REQ-SWAP-112, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-LIQ-022
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
            // Exact balance-delta check of the shortfall pull (REQ-SWAP-112): any other arrival is FundingMismatch.
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
        if (pay.borrowerSurplus != 0) {
            address wallet = IAaveAdapter(_AAVE_ADAPTER).walletOf(p.proxy);
            bool escrowed = _deliver(address(asset), wallet, pay.borrowerSurplus);
            emit BorrowerSurplusPaid(p.proxy, wallet, address(asset), pay.borrowerSurplus, escrowed);
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

    /// @dev `LiquidationSettled` with the full settlement report.
    /// @custom:spec REQ-SWAP-026, REQ-SWAP-104
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
