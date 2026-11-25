// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "./dependencies/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "./interfaces/ILPOracle.sol";
import {ILPVault} from "./interfaces/ILPVault.sol";
import {ILiquidationModule} from "./interfaces/ILiquidationModule.sol";
import {IRiskModule} from "./interfaces/IRiskModule.sol";
import {IVaultToken} from "./interfaces/IVaultToken.sol";
import {ClTickMath} from "./libraries/ClTickMath.sol";
import {LPPriceMath} from "./libraries/LPPriceMath.sol";
import {LiquidationMath} from "./libraries/LiquidationMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title LiquidationModule
/// @notice Partial liquidation in kind for every band market: Aave's `liquidationCall`, then an unwind of only the
/// liquidity worth the seized units, paid out in both pool tokens with Avana's share of the bonus split off.
/// @dev Not upgradeable, no admin. Holds tokens only inside `liquidate`.
contract LiquidationModule is ILiquidationModule, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc ILiquidationModule
    address public immutable override RISK_MODULE;
    /// @inheritdoc ILiquidationModule
    address public immutable override LP_VAULT;

    /// @dev One position of the plan, before ordering.
    struct Candidate {
        bytes32 key;
        uint256 credit;
        uint256 cap;
        uint256 ratio;
    }

    /// @dev Prices of one market at the oracle, read once per plan.
    struct Pricing {
        uint160 sqrtPrice;
        uint256 p0;
        uint256 p1;
        uint8 d0;
        uint8 d1;
        uint256 unitValue;
        uint256 unitScale;
    }

    /// @dev Reverts `InvalidAddress` for a zero RiskModule and `InvalidDeployment` unless the RiskModule names this
    /// module as its LiquidationModule and has an LPVault.
    constructor(
        address riskModule
    ) {
        if (riskModule == address(0)) revert InvalidAddress(riskModule);
        RISK_MODULE = riskModule;
        LP_VAULT = IRiskModule(riskModule).LP_VAULT();
        if (LP_VAULT == address(0) || IRiskModule(riskModule).LIQUIDATION_MODULE() != address(this)) {
            revert InvalidDeployment();
        }
    }

    /// @inheritdoc ILiquidationModule
    function liquidate(
        LiquidationParams calldata p
    ) external override nonReentrant returns (LiquidationResult memory r) {
        if (p.account == address(0)) revert InvalidAddress(p.account);
        if (p.receiver == address(0) || p.receiver == address(this)) revert InvalidAddress(p.receiver);
        if (p.debtToCover == 0) revert InvalidAmount();
        IRiskModule.Market memory m = IRiskModule(RISK_MODULE).getMarket(p.marketId);
        if (!m.active) revert MarketNotActive(p.marketId);

        uint256 bonusBps;
        (r.debtRepaid, r.seized, bonusBps) = _liquidationCall(m, p);
        IVaultToken(m.vaultToken).burn(address(this), r.seized);

        address recipient = IRiskModule(RISK_MODULE).feeRecipient();
        if (recipient != address(0)) {
            r.feeUnits = LiquidationMath.feeUnits(r.seized, bonusBps, IRiskModule(RISK_MODULE).feeShareBps());
        }
        // An account Aave emptied gives up all its credit, so no rounding dust stays pledged.
        bool emptied = IAaveV4Spoke(m.spoke).getUserSuppliedAssets(m.reserveId, p.account) == 0;
        (UnwindStep[] memory steps,) = _plan(p.account, p.marketId, m, emptied ? type(uint256).max : r.seized);
        _unwind(steps, r);
        _payout(p, r, recipient);

        // forge-lint: disable-start(reentrancy-events)
        emit Liquidated(
            p.account,
            p.marketId,
            msg.sender,
            p.debtReserveId,
            r.debtRepaid,
            r.seized,
            r.creditUnwound,
            r.amount0,
            r.amount1
        );
        if (r.feeUnits != 0) emit FeePaid(p.account, p.marketId, recipient, r.feeUnits, r.fee0, r.fee1);
        // forge-lint: disable-end(reentrancy-events)
    }

    /// @inheritdoc ILiquidationModule
    function previewUnwind(
        address account,
        uint256 marketId,
        uint256 units
    ) external view override returns (UnwindStep[] memory steps, uint256 shortfall) {
        return _plan(account, marketId, IRiskModule(RISK_MODULE).getMarket(marketId), units);
    }

    // ─── Internals ───

    /// @dev Pulls `debtToCover`, runs Aave's liquidation for this module, refunds what Aave did not take, and returns
    /// the debt repaid, the units seized and Aave's bonus at the account's health factor before the call.
    function _liquidationCall(
        IRiskModule.Market memory m,
        LiquidationParams calldata p
    ) internal returns (uint256 repaid, uint256 seized, uint256 bonusBps) {
        IAaveV4Spoke spoke = IAaveV4Spoke(m.spoke);
        uint256 healthFactor = spoke.getUserAccountData(p.account).healthFactor;
        // Aave's bonus curve underflows at or above 1; such an account is refused by `liquidationCall` itself, with
        // Aave's own error.
        if (healthFactor < LiquidationMath.HEALTH_FACTOR_ONE) {
            bonusBps = spoke.getLiquidationBonus(m.reserveId, p.account, healthFactor);
        }
        IERC20 debt = IERC20(spoke.getReserve(p.debtReserveId).underlying);
        IERC20 vt = IERC20(m.vaultToken);
        uint256 debtBefore = debt.balanceOf(address(this));
        uint256 vtBefore = vt.balanceOf(address(this));
        debt.safeTransferFrom(msg.sender, address(this), p.debtToCover);
        debt.forceApprove(address(spoke), p.debtToCover);
        spoke.liquidationCall(m.reserveId, p.debtReserveId, p.account, p.debtToCover, false);
        debt.forceApprove(address(spoke), 0);
        uint256 left = debt.balanceOf(address(this)) - debtBefore;
        repaid = p.debtToCover - left;
        if (left != 0) debt.safeTransfer(msg.sender, left);
        seized = vt.balanceOf(address(this)) - vtBefore;
        if (seized == 0) revert NothingSeized(p.account);
    }

    /// @dev Unwinds each step to this module; the sums land in `r.amount0` and `r.amount1` before the fee split.
    function _unwind(
        UnwindStep[] memory steps,
        LiquidationResult memory r
    ) internal {
        for (uint256 i; i < steps.length; ++i) {
            // The liquidity removed is not needed: the credit removed and the token amounts are.
            // forge-lint: disable-start(calls-loop, unused-return)
            (, uint128 removed, uint256 a0, uint256 a1) =
                ILPVault(LP_VAULT).unwind(steps[i].positionKey, steps[i].credit, 0, 0, address(this));
            // forge-lint: disable-end(calls-loop, unused-return)
            r.creditUnwound += removed;
            r.amount0 += a0;
            r.amount1 += a1;
        }
    }

    /// @dev Splits the unwound tokens: Avana's share of the bonus to `recipient`, the rest to the receiver.
    function _payout(
        LiquidationParams calldata p,
        LiquidationResult memory r,
        address recipient
    ) internal {
        r.fee0 = LiquidationMath.feePart(r.amount0, r.feeUnits, r.seized);
        r.fee1 = LiquidationMath.feePart(r.amount1, r.feeUnits, r.seized);
        r.amount0 -= r.fee0;
        r.amount1 -= r.fee1;
        if (r.amount0 < p.minAmount0) revert BelowMinimum(0, r.amount0, p.minAmount0);
        if (r.amount1 < p.minAmount1) revert BelowMinimum(1, r.amount1, p.minAmount1);
        ILPVault.Market memory pool = ILPVault(LP_VAULT).getMarket(p.marketId);
        _send(pool.token0, p.receiver, r.amount0);
        _send(pool.token1, p.receiver, r.amount1);
        _send(pool.token0, recipient, r.fee0);
        _send(pool.token1, recipient, r.fee1);
    }

    /// @dev The unwind plan: the account's positions in the market ordered by excess per credit unit, least first, each
    /// covering at most its worth at the oracle price.
    function _plan(
        address account,
        uint256 marketId,
        IRiskModule.Market memory m,
        uint256 units
    ) internal view returns (UnwindStep[] memory steps, uint256 shortfall) {
        Candidate[] memory c = _candidates(account, marketId, m);
        _sort(c);
        UnwindStep[] memory all = new UnwindStep[](c.length);
        uint256 n = 0;
        for (uint256 i = 0; i < c.length && units != 0; ++i) {
            uint256 take = units < c[i].cap ? units : c[i].cap;
            units -= take;
            // A position whose whole worth is taken is unwound whole, with no rounding dust left behind.
            uint256 credit = take == c[i].cap ? c[i].credit : LiquidationMath.creditFor(take, c[i].credit, c[i].cap);
            // Below one credit unit of this position: dust the liquidator forgoes.
            if (credit == 0) continue;
            // At most the record's uint128 credit (take <= cap).
            // forge-lint: disable-next-line(unsafe-typecast)
            all[n++] = UnwindStep({positionKey: c[i].key, credit: uint128(credit), units: take});
        }
        // Copied into an array of the final length (no in-place length rewrite, which formal tools cannot follow).
        steps = new UnwindStep[](n);
        for (uint256 i = 0; i < n; ++i) {
            steps[i] = all[i];
        }
        shortfall = units;
    }

    /// @dev The account's positions in the market with credit, valued at the market's oracle.
    function _candidates(
        address account,
        uint256 marketId,
        IRiskModule.Market memory m
    ) internal view returns (Candidate[] memory c) {
        ILPVault vault = ILPVault(LP_VAULT);
        bytes32[] memory keys = vault.positionsOf(account);
        if (keys.length == 0) return c;
        Candidate[] memory all = new Candidate[](keys.length);
        Pricing memory pr = _pricing(ILPOracle(m.lpOracle));
        uint256 n = 0;
        for (uint256 i; i < keys.length; ++i) {
            // forge-lint: disable-start(calls-loop, unused-return)
            ILPVault.Position memory pos = vault.getPosition(keys[i]);
            if (pos.marketId != marketId || pos.credit == 0) continue;
            // Only the ticks: the record's liquidity is what backs the credit.
            (, int24 lower, int24 upper,) = vault.positionInfo(keys[i]);
            // forge-lint: disable-end(calls-loop, unused-return)
            (uint256 a0, uint256 a1) = LPPriceMath.amounts(
                pr.sqrtPrice, ClTickMath.getSqrtPriceAtTick(lower), ClTickMath.getSqrtPriceAtTick(upper), pos.liquidity
            );
            uint256 cap = LiquidationMath.capacity(
                LiquidationMath.value(a0, a1, pr.p0, pr.p1, pr.d0, pr.d1), pr.unitValue, pr.unitScale, pos.credit
            );
            all[n++] = Candidate({
                key: keys[i], credit: pos.credit, cap: cap, ratio: LiquidationMath.excessRatio(cap, pos.credit)
            });
        }
        // Copied into an array of the final length (no in-place length rewrite).
        c = new Candidate[](n);
        for (uint256 i = 0; i < n; ++i) {
            c[i] = all[i];
        }
    }

    /// @dev The oracle's prices and the value of one whole vault token.
    function _pricing(
        ILPOracle oracle
    ) internal view returns (Pricing memory pr) {
        (pr.p0, pr.p1, pr.sqrtPrice) = oracle.getPrices();
        (address t0, address t1) = oracle.tokens();
        (pr.d0, pr.d1) = (IERC20Metadata(t0).decimals(), IERC20Metadata(t1).decimals());
        (uint256 u0, uint256 u1) = oracle.getUnitAmounts();
        pr.unitValue = LiquidationMath.value(u0, u1, pr.p0, pr.p1, pr.d0, pr.d1);
        if (pr.unitValue == 0) pr.unitValue = 1;
        pr.unitScale = 10 ** oracle.unitDecimals();
    }

    /// @dev Insertion sort by excess ratio, least first; ties keep the LPVault's order. At most `MAX_POSITIONS` items.
    function _sort(
        Candidate[] memory c
    ) internal pure {
        for (uint256 i = 1; i < c.length; ++i) {
            Candidate memory x = c[i];
            uint256 j = i;
            while (j != 0 && c[j - 1].ratio > x.ratio) {
                c[j] = c[j - 1];
                --j;
            }
            c[j] = x;
        }
    }

    function _send(
        address token,
        address to,
        uint256 amount
    ) internal {
        if (amount != 0) IERC20(token).safeTransfer(to, amount);
    }
}
