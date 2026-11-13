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
/// @notice The flash liquidation helper's whole flow (2.11 Flash liquidation helper), shared by the public helper and
/// the operator variant: request checks, the bound single-use context, the loan from the chain's Aave V3 Pool, the
/// liquidation inside the Pool's callback, the repayment with a bounded top-up, the net payout after the loan returns
/// and the claim of the helper's escrowed credits.
/// @dev Immutable, with no owner, role, setter, sweep, rescue, arbitrary call, `delegatecall`, fallback or `receive`;
/// no persistent storage. The context lives in transient storage at an ERC-7201 base slot, so it is empty at the start
/// of every transaction and a reverted call leaves nothing. A variant fixes only who may call (`_callerAllowed`), who
/// pays the inventory, the shortfall budget and the top-ups (`_payer`), who receives the payout (`_recipient`), who
/// receives a claimed credit (`_claimRecipient`) and the operator bounds (`_topUpBound`, `_checkLoanNeed`,
/// `_checkOutlay`). External calls beyond the Pool's: the MarketRegistry (`getMarket`, `getDebtReserve`,
/// `isRecordedHub`, `getRoute`), the market's swap routes (`intermediates`), the ParameterStore (`maxFlashFeeBps`,
/// `feeRecipient`), LPVaultSwap (`liquidate`, `PAYOUT_ESCROW`), the PayoutEscrow (`claimable`, `claim`), the debt
/// asset, the market's tokens and the routes' intermediates (`balanceOf`, `allowance`, `approve`, `transfer`,
/// `transferFrom`).
/// @custom:spec REQ-HELPER-001, REQ-HELPER-002, REQ-HELPER-003, REQ-HELPER-004, REQ-HELPER-005, REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-008, REQ-HELPER-009, REQ-HELPER-010, REQ-HELPER-012, REQ-HELPER-013, REQ-HELPER-014, REQ-HELPER-015, SPEC-LIQ-015, SPEC-LIQ-019, REQ-SWAP-012, REQ-SWAP-105, Q-045, Q-335, Q-345, Q-404
abstract contract FlashLiquidatorBase is FlashLiquidatorLenders {
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Uint256Slot;
    using TransientSlot for TransientSlot.AddressSlot;
    using TransientSlot for TransientSlot.Bytes32Slot;

    /// @notice Every token LPVaultSwap may pay the helper besides `T` in one call: the market's tokens and the
    /// intermediates of each of their primary and backup swap routes into `T`, with the helper's balance and its
    /// PayoutEscrow credit of each before the call.
    struct Watch {
        address escrow;
        address[] tokens;
        uint256[] balances;
        uint256[] credits;
        uint256 count;
    }

    /// @notice Context state: none open, open awaiting the Pool's callback, callback ran (used).
    uint256 private constant STATE_NONE = 0;
    uint256 private constant STATE_OPEN = 1;
    uint256 private constant STATE_USED = 2;

    /// @notice ERC-7201 transient base slot of the context:
    /// `keccak256(abi.encode(uint256(keccak256("avana.flashliquidator.context")) - 1)) & ~bytes32(uint256(0xff))`.
    /// The state sits at the base; the lender, the initiator, `T`, `F`, `maxPremium`, `maxTopUp`, the `params` hash,
    /// the payer and the recipient at the next nine slots; the charged premium, the measured `keeperOut`, the top-up
    /// pulled and the debt repaid at the four after them.
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
    /// @dev Reverts `ZeroAddress` for a zero address and `FlashSourceIsHub` if the MarketRegistry records the Pool as
    /// a Hub.
    /// @param pool The chain's Aave V3 Pool, the lender of every debt asset.
    /// @param lpVaultSwap The chain's LPVaultSwap.
    /// @param marketRegistry The chain's MarketRegistry.
    /// @param parameterStore The chain's ParameterStore.
    /// @custom:spec REQ-HELPER-001, REQ-HELPER-002, REQ-HELPER-015
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
    /// @custom:spec REQ-HELPER-002, REQ-HELPER-003, REQ-HELPER-004, REQ-HELPER-008, REQ-HELPER-010, REQ-HELPER-011, REQ-HELPER-012, REQ-HELPER-013, REQ-HELPER-014, REQ-HELPER-015, SPEC-LIQ-015, SPEC-LIQ-019, Q-345, Q-404
    function flashLiquidate(
        FlashLiquidationRequest calldata request
    ) external override returns (uint256 payout) {
        if (STATE_SLOT.asUint256().tload() != STATE_NONE) revert ContextActive();
        if (!_callerAllowed()) revert NotSigner();
        uint256 flashAmount = request.flashAmount;
        // X and maxShortfall within LPVaultSwap's own bound (REQ-SWAP-005), so X - F + maxShortfall cannot overflow.
        // F = 0 only in the operator variant (REQ-HELPER-003): no loan, the Safe funds the whole repayment.
        if (
            (flashAmount == 0 && !_zeroLoanAllowed()) || flashAmount > request.params.debtToCover
                || request.params.debtToCover > type(uint128).max || request.params.maxShortfall > type(uint128).max
        ) revert InvalidFlashAmount();
        Market memory market = IMarketRegistryViews(MARKET_REGISTRY).getMarket(request.params.marketId);
        IERC20 asset = IERC20(
            IMarketRegistryRouteViews(MARKET_REGISTRY).getDebtReserve(market.spoke, request.params.debtReserveId).asset
        );
        // With F = 0 the Pool is neither read nor called: the context records `address(0)` as lender, so the Pool's
        // callback cannot bind to it.
        address lender = address(0);
        if (flashAmount != 0) {
            lender = POOL;
            if (IMarketRegistryHubs(MARKET_REGISTRY).isRecordedHub(lender)) revert FlashSourceIsHub();
            uint256 available = maxFlashLoan(address(asset));
            if (flashAmount > available) revert InsufficientFlashLiquidity(available);
            // SPEC-LIQ-015 pre-loan bound on the quote; the callback re-checks the charged premium.
            _checkPremium(flashPremium(address(asset), flashAmount), flashAmount);
        }

        // Balances before anything moves: the payout and the forwarded market tokens are rises over these.
        uint256 assetBefore = asset.balanceOf(address(this));
        Watch memory w = _watch(request.params.marketId, market.tokens, address(asset));
        address payer = _openContext(lender, address(asset), request);
        // Inventory X - F and the SPEC-LIQ-019 shortfall budget; the unused part returns in the payout.
        uint256 prefund = request.params.debtToCover - flashAmount + request.params.maxShortfall;
        // The payer is fixed by the variant, never by the request: `msg.sender` (public) or the immutable
        // `FUNDING_SAFE` (operator), REQ-HELPER-010, REQ-HELPER-011.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        if (prefund != 0) asset.safeTransferFrom(payer, address(this), prefund);
        if (flashAmount == 0) {
            // No loan: the context is used before LPVaultSwap is called, so no callback can run in this call; the
            // prefund `X + maxShortfall` funds `liquidate` and nothing is owed afterwards, so no top-up is pulled.
            STATE_SLOT.asUint256().tstore(STATE_USED);
            _liquidate(asset, request.params);
        } else {
            _borrow(address(asset), flashAmount, abi.encode(request.params));
            if (STATE_SLOT.asUint256().tload() != STATE_USED) revert InvalidFlashCallback();
        }

        payout = _payOut(asset, assetBefore, request.minPayout, prefund, w);
        // The context stays open through the payout, so a reentrant `flashLiquidate` from a token transfer reverts
        // `ContextActive`; it is cleared as the last step.
        _clearContext();
    }

    /// @inheritdoc IFlashLiquidator
    /// @custom:spec REQ-HELPER-004, REQ-HELPER-005, REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-013, SPEC-LIQ-015, REQ-SWAP-081, Q-045, Q-404
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
    /// @custom:spec REQ-HELPER-010, REQ-HELPER-011
    function claimEscrowed(
        address token
    ) external override returns (uint256 amount) {
        address recipient = _claimRecipient();
        address escrow = ILPVaultSwapViews(LP_VAULT_SWAP).PAYOUT_ESCROW();
        amount = IPayoutEscrow(escrow).claim(token, recipient);
    }

    /// @notice Whether a request may name `F = 0`, a liquidation funded wholly by the payer with no loan.
    /// @return allowed False for the public helper; true for the operator variant (REQ-HELPER-011).
    /// @custom:spec REQ-HELPER-003, REQ-HELPER-011
    function _zeroLoanAllowed() internal pure virtual returns (bool allowed);

    /// @notice Whether `msg.sender` may call `flashLiquidate`; `flashLiquidate` reverts `NotSigner` otherwise.
    /// @return allowed True for every caller of the public helper and for `SIGNER` of the operator variant.
    /// @custom:spec REQ-HELPER-003, REQ-HELPER-010, REQ-HELPER-011
    function _callerAllowed() internal view virtual returns (bool allowed);

    /// @notice The address the inventory `X − F`, the shortfall budget and every top-up are pulled from.
    /// @return payer `msg.sender` (public helper) or `FUNDING_SAFE` (operator variant).
    /// @custom:spec REQ-HELPER-004, REQ-HELPER-010, REQ-HELPER-011
    function _payer() internal view virtual returns (address payer);

    /// @notice The address the payout and every market token are sent to.
    /// @return recipient `msg.sender` (public helper) or `FUNDING_SAFE` (operator variant).
    /// @custom:spec REQ-HELPER-004, REQ-HELPER-010, REQ-HELPER-011
    function _recipient() internal view virtual returns (address recipient);

    /// @notice The address `claimEscrowed` pays, after the variant's caller check.
    /// @return recipient `feeRecipient` (public helper) or `FUNDING_SAFE` (operator variant, `SIGNER` only).
    /// @custom:spec REQ-HELPER-010, REQ-HELPER-011
    function _claimRecipient() internal view virtual returns (address recipient);

    /// @notice The most top-up one call may pull.
    /// @param maxTopUp The request's `maxTopUp`.
    /// @param debtRepaid `D`, the debt LPVaultSwap repaid in this call.
    /// @return bound `maxTopUp` (public helper) or `min(maxTopUp, ⌊D × MAX_TOP_UP_BPS / 10⁴⌋)` (operator variant).
    /// @custom:spec REQ-HELPER-007, REQ-HELPER-011
    function _topUpBound(
        uint256 maxTopUp,
        uint256 debtRepaid
    ) internal view virtual returns (uint256 bound);

    /// @notice Refuses, in the operator variant, a loan above what the liquidation needed; nothing in the public helper.
    /// @param flashAmount `F`.
    /// @param debtRepaid `D`.
    /// @custom:spec REQ-HELPER-011
    function _checkLoanNeed(
        uint256 flashAmount,
        uint256 debtRepaid
    ) internal view virtual;

    /// @notice Refuses, in the operator variant, a call whose net outlay from the payer exceeds its bound; nothing in
    /// the public helper.
    /// @param outlay What left the payer: the prefund `X − F + maxShortfall` and the top-up.
    /// @param payout What returns to it.
    /// @param debtRepaid `D`.
    /// @custom:spec REQ-HELPER-011
    function _checkOutlay(
        uint256 outlay,
        uint256 payout,
        uint256 debtRepaid
    ) internal view virtual;

    /// @notice Records the single-use context: open, the lender, this helper as initiator, `T`, `F`, the two bounds,
    /// the `params` hash, the payer and the recipient.
    /// @param lender `POOL`, or `address(0)` when the call takes no loan.
    /// @param asset `T`.
    /// @param request The caller's request.
    /// @return payer The payer recorded.
    /// @custom:spec REQ-HELPER-004
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

    /// @notice The body of the Pool's callback once bound: marks the context used, checks the premium, liquidates,
    /// checks the loan against the need and repays.
    /// @param asset `T`.
    /// @param amount `F`.
    /// @param premium The premium the Pool charges.
    /// @param params The bound `abi.encode(params)`.
    /// @custom:spec REQ-HELPER-005, REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-011, SPEC-LIQ-015
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
    /// @dev LPVaultSwap may pull `X` and then the `SPEC-LIQ-019` shortfall, so it is approved for `X + maxShortfall`.
    /// What it pulled is the allowance it consumed (`X + shortfall`); the allowance left is the unused budget, still
    /// held here. `keeperOut` is the rise of the `T` balance across the call plus what was pulled. `D` is the
    /// `debtRepaid` LPVaultSwap measured (Aave's pull, by balance delta) and returned, at most `X`.
    /// @param asset `T`.
    /// @param params The bound liquidation parameters, passed unchanged.
    /// @return keeperOut `T` LPVaultSwap paid this helper.
    /// @return unused The shortfall budget LPVaultSwap did not pull.
    /// @return debtRepaid `D`.
    /// @custom:spec REQ-HELPER-006, REQ-HELPER-011, REQ-HELPER-012, REQ-SWAP-011, REQ-SWAP-026, SPEC-LIQ-019
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

    /// @notice Pulls the top-up `owed − held` from the payer when what the helper holds for the loan falls short,
    /// within its bound, and approves the Pool for exactly `owed`.
    /// @param asset `T`.
    /// @param owed `F + premium`.
    /// @param held `keeperOut` plus the unused shortfall budget.
    /// @param debtRepaid `D`, for the operator variant's bound.
    /// @custom:spec REQ-HELPER-007, REQ-HELPER-011, REQ-SWAP-081
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
            // The payer recorded by `flashLiquidate` for this context (`msg.sender` or `FUNDING_SAFE`), never from the
            // request; the context is reachable only through the Pool's bound callback (REQ-HELPER-005).
            // forge-lint: disable-next-line(arbitrary-send-erc20)
            asset.safeTransferFrom(PAYER_SLOT.asAddress().tload(), address(this), topUp);
        }
        asset.forceApprove(LENDER_SLOT.asAddress().tload(), owed);
    }

    /// @notice After the loan returned: computes the net payout as the rise of the `T` balance over the whole call,
    /// enforces `minPayout` and the variant's outlay bound, withdraws any Pool allowance left, sends the payout, every
    /// rise of a watched token and every PayoutEscrow credit this call created to the recipient and emits
    /// `FlashLiquidated`.
    /// @dev A `T` balance that ended below its start (only possible when `T` charges a transfer fee and the helper held
    /// `T` before the call) reverts `PayoutTooLow(0, minPayout)`, so nothing the helper held before pays for a call.
    /// @param asset `T`.
    /// @param assetBefore The `T` balance before the call.
    /// @param minPayout The request's net minimum.
    /// @param prefund The inventory and shortfall budget pulled before the loan.
    /// @param w The watched tokens with their balances and escrow credits before the call.
    /// @return payout The net payout sent.
    /// @custom:spec REQ-HELPER-001, REQ-HELPER-008, REQ-HELPER-010, REQ-HELPER-011, REQ-HELPER-014, Q-345
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

        // The event reports what the loan's callback measured, known only after the loan returned; a reentrant call
        // reverts `ContextActive` until the context is cleared after this event, so no log can be reordered.
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

    /// @notice The tokens LPVaultSwap may pay the helper in a liquidation of `marketId` into `asset` besides `asset`:
    /// the market's tokens and the `intermediates()` of each pool token's primary and backup route into `asset`, each
    /// once, with the helper's balance and PayoutEscrow credit of each. A route that is unset or whose
    /// `intermediates()` reverts adds nothing: LPVaultSwap does not swap through it either (REQ-SWAP-022).
    /// @param marketId The market.
    /// @param tokens The market's tokens (at most `MAX_POOL_TOKENS` = 8).
    /// @param asset `T`.
    /// @return w The watch list.
    /// @custom:spec REQ-HELPER-001, REQ-HELPER-008, REQ-HELPER-010
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
                // At most 8 market tokens and two route slots each, fixed by the MarketRegistry's records; views only.
                // Only the route address is used: an unusable slot is still read, since its route may hold residues.
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
    /// @param w The watch list.
    /// @param token A market token or route intermediate.
    /// @param asset `T`.
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

    /// @notice Sends the recipient the rise of the helper's balance of each watched token (route residues, route
    /// intermediates of a partly filled multi-hop route and dust legs LPVaultSwap paid it), then claims to the
    /// recipient every PayoutEscrow credit of a watched token that this call created: one that was 0 before the call
    /// and is not now (a residue LPVaultSwap could not deliver to the helper). A credit already standing before the
    /// call, or one whose claim the recipient cannot receive, is left to `claimEscrowed`.
    /// @param recipient The payout recipient.
    /// @param w The watch list with its balances and credits before the call.
    /// @custom:spec REQ-HELPER-001, REQ-HELPER-008, REQ-HELPER-010
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
            if (w.credits[i] == 0 && IPayoutEscrow(w.escrow).claimable(w.tokens[i], address(this)) != 0) {
                // The whole credit is this call's: it was 0 when the call started (REQ-HELPER-010). A claim the
                // recipient cannot receive leaves the credit standing for `claimEscrowed`, so the call itself never
                // fails on a residue.
                // forge-lint: disable-next-line(calls-loop)
                try IPayoutEscrow(w.escrow).claim(w.tokens[i], recipient) {} catch {}
            }
        }
    }

    /// @notice Reverts `FlashFeeTooHigh` unless `premium × 10⁴ ≤ maxFlashFeeBps × amount`, exact for every input.
    /// @param premium The premium quoted (before the loan) or charged (in the callback).
    /// @param amount `F`.
    /// @custom:spec REQ-HELPER-005, SPEC-LIQ-015
    function _checkPremium(
        uint256 premium,
        uint256 amount
    ) private view {
        uint256 cap = IParameterStoreViews(PARAMETER_STORE).maxFlashFeeBps();
        if (!SettlementMath.flashPremiumWithinCap(premium, amount, cap)) {
            revert FlashFeeTooHigh(premium, Math.mulDiv(cap, amount, BPS));
        }
    }

    /// @notice Empties the fourteen transient context slots.
    /// @custom:spec REQ-HELPER-004
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
