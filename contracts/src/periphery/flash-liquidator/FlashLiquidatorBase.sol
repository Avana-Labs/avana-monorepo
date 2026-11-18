// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapLiquidation} from "../../liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {ILPVaultSwapViews} from "../../liquidation/lp-vault-swap/ILPVaultSwapViews.sol";
import {SettlementMath} from "../../liquidation/lp-vault-swap/SettlementMath.sol";
import {LiquidationParams} from "../../liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IPayoutEscrow} from "../../liquidation/payout-escrow/IPayoutEscrow.sol";
import {ISettlementRoute} from "../../liquidation/settlement-routes/ISettlementRoute.sol";
import {IMarketRegistryHubs} from "../../policy/market-registry/IMarketRegistryHubs.sol";
import {IMarketRegistryRouteViews} from "../../policy/market-registry/IMarketRegistryRouteViews.sol";
import {IMarketRegistryViews} from "../../policy/market-registry/IMarketRegistryViews.sol";
import {IParameterStoreViews} from "../../policy/parameter-store/IParameterStoreViews.sol";
import {Market} from "../../types/Market.sol";
import {FlashLiquidatorLenders} from "./FlashLiquidatorLenders.sol";
import {IFlashLiquidator} from "./IFlashLiquidator.sol";
import {FlashLiquidationRequest} from "./types/FlashLiquidationRequest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FlashLiquidatorBase
/// @notice Flash liquidation flow shared by the public and operator helpers: Aave V3 loan, liquidate, repay, pay out.
/// @dev Immutable, no owner, no persistent storage: the single-use context lives in transient storage.
abstract contract FlashLiquidatorBase is FlashLiquidatorLenders {
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Uint256Slot;
    using TransientSlot for TransientSlot.AddressSlot;
    using TransientSlot for TransientSlot.Bytes32Slot;

    /// @notice Tokens LPVaultSwap may pay besides `T`, with their balance and escrow credit before the call.
    struct Watch {
        address escrow;
        address[] tokens;
        uint256[] balances;
        uint256[] credits;
        uint256 count;
    }

    uint256 private constant STATE_NONE = 0;
    uint256 private constant STATE_OPEN = 1;
    uint256 private constant STATE_USED = 2;

    /// @notice ERC-7201 transient base slot of the context (`avana.flashliquidator.context`); each field follows it.
    bytes32 private constant STATE_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec300;
    bytes32 private constant LENDER_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec301;
    bytes32 private constant INITIATOR_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec302;
    bytes32 private constant ASSET_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec303;
    bytes32 private constant AMOUNT_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec304;
    bytes32 private constant MAX_PREMIUM_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec305;
    bytes32 private constant MAX_TOP_UP_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec306;
    bytes32 private constant PARAMS_HASH_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec307;
    bytes32 private constant PAYER_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec308;
    bytes32 private constant RECIPIENT_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec309;
    bytes32 private constant PREMIUM_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec30a;
    bytes32 private constant KEEPER_OUT_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec30b;
    bytes32 private constant TOP_UP_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec30c;
    bytes32 private constant DEBT_REPAID_SLOT = 0xd2494030a1225beb0e736ad6b4942f8ec4998cd84354a526ceb29f1968bec30d;

    /// @inheritdoc IFlashLiquidator
    address public immutable override LP_VAULT_SWAP;

    /// @inheritdoc IFlashLiquidator
    address public immutable override PARAMETER_STORE;

    /// @notice Fixes the chain's Aave V3 Pool, LPVaultSwap, MarketRegistry and ParameterStore.
    /// @dev Reverts `FlashSourceIsHub` if the MarketRegistry records the Pool as a Hub.
    constructor(
        address pool,
        address lpVaultSwap,
        address marketRegistry,
        address parameterStore
    ) FlashLiquidatorLenders(pool, marketRegistry) {
        if (lpVaultSwap == address(0) || parameterStore == address(0)) revert ZeroAddress();
        LP_VAULT_SWAP = lpVaultSwap;
        PARAMETER_STORE = parameterStore;
    }

    /// @inheritdoc IFlashLiquidator
    function flashLiquidate(
        FlashLiquidationRequest calldata request
    ) external override returns (uint256 payout) {
        if (STATE_SLOT.asUint256().tload() != STATE_NONE) revert ContextActive();
        if (!_callerAllowed()) revert NotSigner();
        uint256 flashAmount = request.flashAmount;
        // Bounding X and maxShortfall to uint128 keeps X - F + maxShortfall from overflowing.
        // F = 0 only in the operator variant: no loan, the Safe funds the whole repayment.
        if (
            (flashAmount == 0 && !_zeroLoanAllowed()) || flashAmount > request.params.debtToCover
                || request.params.debtToCover > type(uint128).max || request.params.maxShortfall > type(uint128).max
        ) revert InvalidFlashAmount();
        Market memory market = IMarketRegistryViews(MARKET_REGISTRY).getMarket(request.params.marketId);
        IERC20 asset = IERC20(
            IMarketRegistryRouteViews(MARKET_REGISTRY).getDebtReserve(market.spoke, request.params.debtReserveId).asset
        );
        // With F = 0 the lender is `address(0)`, so the Pool's callback cannot bind to the context.
        address lender = address(0);
        if (flashAmount != 0) {
            lender = POOL;
            if (IMarketRegistryHubs(MARKET_REGISTRY).isRecordedHub(lender)) revert FlashSourceIsHub();
            uint256 available = maxFlashLoan(address(asset));
            if (flashAmount > available) revert InsufficientFlashLiquidity(available);
            // Pre-loan bound on the quote; the callback re-checks the charged premium.
            _checkPremium(flashPremium(address(asset), flashAmount), flashAmount);
        }

        // The payout and the forwarded tokens are rises over these balances.
        uint256 assetBefore = asset.balanceOf(address(this));
        Watch memory w = _watch(request.params.marketId, market.tokens, address(asset));
        address payer = _openContext(lender, address(asset), request);
        uint256 prefund = request.params.debtToCover - flashAmount + request.params.maxShortfall;
        // The payer is fixed by the variant, never by the request.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        if (prefund != 0) asset.safeTransferFrom(payer, address(this), prefund);
        if (flashAmount == 0) {
            // No loan: mark the context used first so no callback can bind; the prefund covers everything.
            STATE_SLOT.asUint256().tstore(STATE_USED);
            _liquidate(asset, request.params);
        } else {
            _borrow(address(asset), flashAmount, abi.encode(request.params));
            if (STATE_SLOT.asUint256().tload() != STATE_USED) revert InvalidFlashCallback();
        }

        payout = _payOut(asset, assetBefore, request.minPayout, prefund, w);
        // Cleared last, so a reentrant `flashLiquidate` during the payout reverts `ContextActive`.
        _clearContext();
    }

    /// @inheritdoc IFlashLiquidator
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool success) {
        if (
            STATE_SLOT.asUint256().tload() != STATE_OPEN || msg.sender != POOL
                || LENDER_SLOT.asAddress().tload() != POOL || initiator != INITIATOR_SLOT.asAddress().tload()
                || assets.length != 1 || amounts.length != 1 || premiums.length != 1
                || assets[0] != ASSET_SLOT.asAddress().tload() || amounts[0] != AMOUNT_SLOT.asUint256().tload()
                || keccak256(params) != PARAMS_HASH_SLOT.asBytes32().tload()
        ) revert InvalidFlashCallback();
        _runLoan(IERC20(assets[0]), amounts[0], premiums[0], params);
        return true;
    }

    /// @inheritdoc IFlashLiquidator
    function claimEscrowed(
        address token
    ) external override returns (uint256 amount) {
        // Not while a call is open, so a token callback cannot divert that call's new credit.
        if (STATE_SLOT.asUint256().tload() != STATE_NONE) revert ContextActive();
        address recipient = _claimRecipient();
        address escrow = ILPVaultSwapViews(LP_VAULT_SWAP).PAYOUT_ESCROW();
        amount = IPayoutEscrow(escrow).claim(token, recipient);
    }

    /// @notice Whether a request may name `F = 0`, a liquidation funded wholly by the payer with no loan.
    function _zeroLoanAllowed() internal pure virtual returns (bool allowed);

    /// @notice Whether `msg.sender` may call `flashLiquidate`; `flashLiquidate` reverts `NotSigner` otherwise.
    function _callerAllowed() internal view virtual returns (bool allowed);

    /// @notice The address the inventory `X − F`, the shortfall budget and every top-up are pulled from.
    function _payer() internal view virtual returns (address payer);

    /// @notice The address the payout and every market token are sent to.
    function _recipient() internal view virtual returns (address recipient);

    /// @notice The address `claimEscrowed` pays, after the variant's caller check.
    function _claimRecipient() internal view virtual returns (address recipient);

    /// @notice The most top-up one call may pull.
    function _topUpBound(
        uint256 maxTopUp,
        uint256 debtRepaid
    ) internal view virtual returns (uint256 bound);

    /// @notice Refuses, in the operator variant, a loan above what the liquidation needed.
    function _checkLoanNeed(
        uint256 flashAmount,
        uint256 debtRepaid
    ) internal view virtual;

    /// @notice Refuses, in the operator variant, a call whose net outlay from the payer exceeds its bound.
    /// @param outlay What left the payer: the prefund `X − F + maxShortfall` and the top-up.
    function _checkOutlay(
        uint256 outlay,
        uint256 payout,
        uint256 debtRepaid
    ) internal view virtual;

    /// @notice Records the single-use context.
    /// @param lender `POOL`, or `address(0)` when the call takes no loan.
    function _openContext(
        address lender,
        address asset,
        FlashLiquidationRequest calldata request
    ) private returns (address payer) {
        payer = _payer();
        STATE_SLOT.asUint256().tstore(STATE_OPEN);
        LENDER_SLOT.asAddress().tstore(lender);
        INITIATOR_SLOT.asAddress().tstore(address(this));
        ASSET_SLOT.asAddress().tstore(asset);
        AMOUNT_SLOT.asUint256().tstore(request.flashAmount);
        MAX_PREMIUM_SLOT.asUint256().tstore(request.maxPremium);
        MAX_TOP_UP_SLOT.asUint256().tstore(request.maxTopUp);
        PARAMS_HASH_SLOT.asBytes32().tstore(keccak256(abi.encode(request.params)));
        PAYER_SLOT.asAddress().tstore(payer);
        RECIPIENT_SLOT.asAddress().tstore(_recipient());
    }

    /// @notice The body of the Pool's callback once bound: checks the premium, liquidates and repays.
    function _runLoan(
        IERC20 asset,
        uint256 amount,
        uint256 premium,
        bytes calldata params
    ) private {
        // Single use: set before any external call, so a second callback in this transaction fails.
        STATE_SLOT.asUint256().tstore(STATE_USED);
        uint256 maxPremium = MAX_PREMIUM_SLOT.asUint256().tload();
        if (premium > maxPremium) revert PremiumTooHigh(premium, maxPremium);
        _checkPremium(premium, amount);
        PREMIUM_SLOT.asUint256().tstore(premium);

        (uint256 keeperOut, uint256 unused, uint256 debtRepaid) =
            _liquidate(asset, abi.decode(params, (LiquidationParams)));
        _checkLoanNeed(amount, debtRepaid);
        _repay(asset, amount + premium, keeperOut + unused, debtRepaid);
    }

    /// @notice Funds `liquidate` with `X` plus the shortfall budget, calls it and measures `keeperOut`.
    /// @dev What LPVaultSwap pulled is the allowance it consumed; the allowance left is the unused budget.
    function _liquidate(
        IERC20 asset,
        LiquidationParams memory params
    ) private returns (uint256 keeperOut, uint256 unused, uint256 debtRepaid) {
        uint256 approved = params.debtToCover + params.maxShortfall;
        asset.forceApprove(LP_VAULT_SWAP, approved);
        uint256 balanceBefore = asset.balanceOf(address(this));
        LiquidationResult memory result = ILPVaultSwapLiquidation(LP_VAULT_SWAP).liquidate(params);
        unused = asset.allowance(address(this), LP_VAULT_SWAP);
        asset.forceApprove(LP_VAULT_SWAP, 0);
        keeperOut = asset.balanceOf(address(this)) + (approved - unused) - balanceBefore;
        debtRepaid = Math.min(result.debtRepaid, params.debtToCover);
        KEEPER_OUT_SLOT.asUint256().tstore(keeperOut);
        DEBT_REPAID_SLOT.asUint256().tstore(debtRepaid);
    }

    /// @notice Pulls any shortfall `owed − held` from the payer, within its bound, and approves the Pool for `owed`.
    /// @param owed `F + premium`.
    /// @param held `keeperOut` plus the unused shortfall budget.
    function _repay(
        IERC20 asset,
        uint256 owed,
        uint256 held,
        uint256 debtRepaid
    ) private {
        if (held < owed) {
            uint256 topUp = owed - held;
            uint256 bound = _topUpBound(MAX_TOP_UP_SLOT.asUint256().tload(), debtRepaid);
            if (topUp > bound) revert TopUpExceeded(topUp, bound);
            TOP_UP_SLOT.asUint256().tstore(topUp);
            // The payer recorded for this context, never from the request; reachable only via the bound callback.
            // forge-lint: disable-next-line(arbitrary-send-erc20)
            asset.safeTransferFrom(PAYER_SLOT.asAddress().tload(), address(this), topUp);
        }
        asset.forceApprove(LENDER_SLOT.asAddress().tload(), owed);
    }

    /// @notice Sends the recipient the payout (the `T` balance rise) and the watched tokens' rises.
    /// @dev A `T` balance below its start reverts, so nothing the helper held before pays for a call.
    function _payOut(
        IERC20 asset,
        uint256 assetBefore,
        uint256 minPayout,
        uint256 prefund,
        Watch memory w
    ) private returns (uint256 payout) {
        uint256 assetAfter = asset.balanceOf(address(this));
        if (assetAfter < assetBefore) revert PayoutTooLow(0, minPayout);
        payout = assetAfter - assetBefore;
        if (payout < minPayout) revert PayoutTooLow(payout, minPayout);
        _checkOutlay(prefund + TOP_UP_SLOT.asUint256().tload(), payout, DEBT_REPAID_SLOT.asUint256().tload());
        // The Pool pulls exactly `owed`; an allowance left by a short pull is withdrawn.
        address lender = LENDER_SLOT.asAddress().tload();
        if (lender != address(0) && asset.allowance(address(this), lender) != 0) asset.forceApprove(lender, 0);

        address recipient = RECIPIENT_SLOT.asAddress().tload();
        // The caller's payout is sent directly; a recipient the asset refuses reverts the whole call (never escrowed).
        if (payout != 0) asset.safeTransfer(recipient, payout);
        _forwardTokens(recipient, w);

        // The values are known only after the loan; reentry reverts `ContextActive` until the context is cleared.
        // forge-lint: disable-next-item(reentrancy-events)
        emit FlashLiquidated(
            msg.sender,
            recipient,
            address(asset),
            AMOUNT_SLOT.asUint256().tload(),
            PREMIUM_SLOT.asUint256().tload(),
            KEEPER_OUT_SLOT.asUint256().tload(),
            TOP_UP_SLOT.asUint256().tload(),
            payout
        );
    }

    /// @notice The market tokens and route intermediates, each once, with the helper's balance and escrow credit.
    function _watch(
        uint256 marketId,
        address[] memory tokens,
        address asset
    ) private view returns (Watch memory w) {
        w.escrow = ILPVaultSwapViews(LP_VAULT_SWAP).PAYOUT_ESCROW();
        w.tokens = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            _add(w, tokens[i], asset);
            for (uint8 kind = 0; kind < 2; ++kind) {
                // Bounded: at most 8 tokens and two route slots each. An unusable slot is still read for residues.
                // forge-lint: disable-next-line(calls-loop, unused-return)
                (address route,) = IMarketRegistryRouteViews(MARKET_REGISTRY).getRoute(marketId, tokens[i], asset, kind);
                if (route == address(0)) continue;
                // A route listed by the MarketRegistry; a reverting one is skipped, as LPVaultSwap skips it.
                // forge-lint: disable-next-line(calls-loop)
                try ISettlementRoute(route).intermediates() returns (address[] memory mid) {
                    for (uint256 j = 0; j < mid.length; ++j) {
                        _add(w, mid[j], asset);
                    }
                } catch {}
            }
        }
        w.balances = new uint256[](w.count);
        w.credits = new uint256[](w.count);
        for (uint256 i = 0; i < w.count; ++i) {
            // Bounded by the watch list above; views only.
            // forge-lint: disable-next-line(calls-loop)
            w.balances[i] = IERC20(w.tokens[i]).balanceOf(address(this));
            // forge-lint: disable-next-line(calls-loop)
            w.credits[i] = IPayoutEscrow(w.escrow).claimable(w.tokens[i], address(this));
        }
    }

    /// @notice Adds `token` to the watch list once; `T` and `address(0)` are never added.
    function _add(
        Watch memory w,
        address token,
        address asset
    ) private pure {
        if (token == asset || token == address(0)) return;
        for (uint256 k = 0; k < w.count; ++k) {
            if (w.tokens[k] == token) return;
        }
        if (w.count == w.tokens.length) {
            address[] memory grown = new address[](w.count * 2 + 1);
            for (uint256 k = 0; k < w.count; ++k) {
                grown[k] = w.tokens[k];
            }
            w.tokens = grown;
        }
        w.tokens[w.count] = token;
        ++w.count;
    }

    /// @notice Forwards each watched token's balance and escrow-credit rise to the recipient.
    function _forwardTokens(
        address recipient,
        Watch memory w
    ) private {
        for (uint256 i = 0; i < w.count; ++i) {
            // Bounded by the watch list: at most 8 market tokens and their routes' intermediates.
            // forge-lint: disable-next-line(calls-loop)
            uint256 balance = IERC20(w.tokens[i]).balanceOf(address(this));
            // forge-lint: disable-next-line(calls-loop)
            if (balance > w.balances[i]) IERC20(w.tokens[i]).safeTransfer(recipient, balance - w.balances[i]);
            // forge-lint: disable-next-line(calls-loop)
            uint256 credit = IPayoutEscrow(w.escrow).claimable(w.tokens[i], address(this));
            if (credit > w.credits[i]) {
                // A claim the recipient cannot receive stays for `claimEscrowed`, so the call never fails on a residue.
                // forge-lint: disable-next-line(calls-loop)
                try IPayoutEscrow(w.escrow).claim(w.tokens[i], recipient, credit - w.credits[i]) {} catch {}
            }
        }
    }

    /// @notice Reverts `FlashFeeTooHigh` unless `premium × 10⁴ ≤ maxFlashFeeBps × amount`.
    function _checkPremium(
        uint256 premium,
        uint256 amount
    ) private view {
        uint256 cap = IParameterStoreViews(PARAMETER_STORE).maxFlashFeeBps();
        if (!SettlementMath.flashPremiumWithinCap(premium, amount, cap)) {
            revert FlashFeeTooHigh(premium, Math.mulDiv(cap, amount, BPS));
        }
    }

    function _clearContext() private {
        STATE_SLOT.asUint256().tstore(STATE_NONE);
        LENDER_SLOT.asAddress().tstore(address(0));
        INITIATOR_SLOT.asAddress().tstore(address(0));
        ASSET_SLOT.asAddress().tstore(address(0));
        AMOUNT_SLOT.asUint256().tstore(0);
        MAX_PREMIUM_SLOT.asUint256().tstore(0);
        MAX_TOP_UP_SLOT.asUint256().tstore(0);
        PARAMS_HASH_SLOT.asBytes32().tstore(bytes32(0));
        PAYER_SLOT.asAddress().tstore(address(0));
        RECIPIENT_SLOT.asAddress().tstore(address(0));
        PREMIUM_SLOT.asUint256().tstore(0);
        KEEPER_OUT_SLOT.asUint256().tstore(0);
        TOP_UP_SLOT.asUint256().tstore(0);
        DEBT_REPAID_SLOT.asUint256().tstore(0);
    }
}
