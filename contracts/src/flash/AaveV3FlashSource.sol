// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV3ACLManager} from "../interfaces/external/aave/IAaveV3ACLManager.sol";
import {IAaveV3FlashLoanReceiver} from "../interfaces/external/aave/IAaveV3FlashLoanReceiver.sol";
import {IAaveV3Pool} from "../interfaces/external/aave/IAaveV3Pool.sol";
import {IAaveV3PoolAddressesProvider} from "../interfaces/external/aave/IAaveV3PoolAddressesProvider.sol";
import {SettlementMath} from "../liquidation/lp-vault-swap/SettlementMath.sol";
import {IParameterStoreViews} from "../policy/parameter-store/IParameterStoreViews.sol";
import {IFlashReceiver} from "./IFlashReceiver.sol";
import {IFlashSource} from "./IFlashSource.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AaveV3FlashSource
/// @notice The chain's flash source (2.11 Flash source): lends LPVaultSwap the debt asset itself from the chain's Aave
/// V3 Pool for the duration of one call, with `flashLoan` of one asset and interest-rate mode 0, so no debt is opened.
/// @dev Immutable, with no owner, role, setter, sweep, rescue, fallback, `receive`, `delegatecall` or `selfdestruct`; no
/// persistent storage. A loan runs as: `flashLoan` (LPVaultSwap only) checks the caller, that no loan is open, that the
/// lender is not the liquidated Spoke's Hub, the lender's idle liquidity and the premium against `maxFlashFeeBps`
/// (exact, `SettlementMath.flashPremiumWithinCap`), opens a transient context and calls `LENDER.flashLoan`; the Pool
/// calls `executeOperation`, which authenticates the Pool, the initiator, the single asset and the context, re-checks
/// the charged premium, forwards to LPVaultSwap exactly what the Pool delivered (the rise of its balance over the
/// snapshot `flashLoan` took before calling the Pool; a donation is never forwarded), calls `onFlashLoan`, checks the magic value
/// and that the source holds `amount + premium`, and approves the Pool for exactly that; the Pool pulls it, and
/// `flashLoan` requires that the callback ran, clears the context, zeroes any allowance left and emits
/// `FlashLoanServed`. External calls: the Pool (`flashLoan`, `getConfiguration`, `getReserveAToken`,
/// `getVirtualUnderlyingBalance`,
/// `FLASHLOAN_PREMIUM_TOTAL`, `ADDRESSES_PROVIDER`), the PoolAddressesProvider (`getACLManager`), the ACLManager
/// (`isFlashBorrower`), the ParameterStore (`maxFlashFeeBps`), LPVaultSwap (`onFlashLoan`) and the debt asset
/// (`balanceOf`, `transfer`, `approve`, `allowance`).
/// @custom:spec REQ-FLASH-001, REQ-FLASH-002, REQ-FLASH-003, REQ-FLASH-004, REQ-FLASH-005, REQ-FLASH-009, REQ-FLASH-010, SPEC-LIQ-015, INV-040, INV-095, Q-334, Q-335, Q-373, Q-386, Q-390
contract AaveV3FlashSource is IFlashSource, IAaveV3FlashLoanReceiver {
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Uint256Slot;
    using TransientSlot for TransientSlot.AddressSlot;
    using TransientSlot for TransientSlot.Bytes32Slot;

    /// @notice Value `onFlashLoan` returns on success: `keccak256("IFlashReceiver.onFlashLoan")`.
    bytes32 public constant ON_FLASH_LOAN_MAGIC = 0xc99b2efbd4a3126f78eb0b8a8822446a13d4407f62732d30b5cc5cb0f957115c;

    /// @notice Basis-point denominator.
    uint256 private constant BPS = 10_000;

    /// @notice Aave V3 `ReserveConfigurationMap` bits read by `maxFlashLoan`: active (56), paused (60), flash-loan
    /// enabled (63). The frozen bit (57) is not read: a frozen reserve can still be flash-loaned.
    uint256 private constant ACTIVE_BIT = 1 << 56;
    uint256 private constant PAUSED_BIT = 1 << 60;
    uint256 private constant FLASHLOAN_ENABLED_BIT = 1 << 63;

    /// @notice Context state: no loan open, loan open awaiting the Pool's callback, callback ran.
    uint256 private constant STATE_NONE = 0;
    uint256 private constant STATE_OPEN = 1;
    uint256 private constant STATE_CALLED = 2;

    /// @notice ERC-7201 transient base slot of the flash context:
    /// `keccak256(abi.encode(uint256(keccak256("avana.flashsource.context")) - 1)) & ~bytes32(uint256(0xff))`.
    /// The state sits at the base and the asset, amount, `keccak256(context)`, recorded premium and the source's balance
    /// of the asset before the Pool's transfer at the next five slots.
    bytes32 private constant STATE_SLOT = 0x3dd4a9cecb999f03d2423efc21c510feeb421fa879036dfdc0b79752da3c8a00;
    bytes32 private constant ASSET_SLOT = 0x3dd4a9cecb999f03d2423efc21c510feeb421fa879036dfdc0b79752da3c8a01;
    bytes32 private constant AMOUNT_SLOT = 0x3dd4a9cecb999f03d2423efc21c510feeb421fa879036dfdc0b79752da3c8a02;
    bytes32 private constant PARAMS_HASH_SLOT = 0x3dd4a9cecb999f03d2423efc21c510feeb421fa879036dfdc0b79752da3c8a03;
    bytes32 private constant PREMIUM_SLOT = 0x3dd4a9cecb999f03d2423efc21c510feeb421fa879036dfdc0b79752da3c8a04;
    bytes32 private constant BALANCE_BEFORE_SLOT = 0x3dd4a9cecb999f03d2423efc21c510feeb421fa879036dfdc0b79752da3c8a05;

    /// @inheritdoc IFlashSource
    address public immutable override LENDER;

    /// @inheritdoc IFlashSource
    address public immutable override LP_VAULT_SWAP;

    /// @inheritdoc IFlashSource
    address public immutable override PARAMETER_STORE;

    /// @notice Fixes the chain's Aave V3 Pool, LPVaultSwap and the ParameterStore; none needs code at deployment.
    /// @param lender The chain's Aave V3 Pool.
    /// @param lpVaultSwap The chain's LPVaultSwap fixed proxy address, the only borrower.
    /// @param parameterStore The chain's ParameterStore, which holds `maxFlashFeeBps`.
    /// @custom:spec REQ-FLASH-001
    constructor(
        address lender,
        address lpVaultSwap,
        address parameterStore
    ) {
        if (lender == address(0) || lpVaultSwap == address(0) || parameterStore == address(0)) revert ZeroAddress();
        LENDER = lender;
        LP_VAULT_SWAP = lpVaultSwap;
        PARAMETER_STORE = parameterStore;
    }

    /// @inheritdoc IFlashSource
    /// @custom:spec REQ-FLASH-001, REQ-FLASH-002, REQ-FLASH-003, REQ-FLASH-005, REQ-FLASH-009, SPEC-LIQ-015, INV-040, INV-095, Q-335, Q-386
    function flashLoan(
        address asset,
        uint256 amount,
        address spokeHub,
        bytes calldata context
    ) external override returns (uint256 premium) {
        if (msg.sender != LP_VAULT_SWAP) revert NotLPVaultSwap();
        if (STATE_SLOT.asUint256().tload() != STATE_NONE) revert FlashLoanActive();
        if (LENDER == spokeHub) revert FlashSourceIsHub();
        uint256 available = maxFlashLoan(asset);
        if (amount > available) revert InsufficientFlashLiquidity(available);
        _checkPremium(flashPremium(asset, amount), amount);

        STATE_SLOT.asUint256().tstore(STATE_OPEN);
        ASSET_SLOT.asAddress().tstore(asset);
        AMOUNT_SLOT.asUint256().tstore(amount);
        PARAMS_HASH_SLOT.asBytes32().tstore(keccak256(context));
        // What the source already holds (a donation) is excluded from what it forwards.
        BALANCE_BEFORE_SLOT.asUint256().tstore(IERC20(asset).balanceOf(address(this)));

        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        // Interest-rate mode 0 (NONE): the loan is repaid in this call and never opens debt.
        uint256[] memory modes = new uint256[](1);
        IAaveV3Pool(LENDER).flashLoan(address(this), assets, amounts, modes, address(this), context, 0);

        if (STATE_SLOT.asUint256().tload() != STATE_CALLED) revert InvalidFlashCallback();
        premium = PREMIUM_SLOT.asUint256().tload();
        _clearContext();

        // The Pool pulls exactly `amount + premium`; an allowance left by a short pull is withdrawn.
        if (IERC20(asset).allowance(address(this), LENDER) != 0) IERC20(asset).forceApprove(LENDER, 0);

        // The event reports the premium the lender charged, known only after its callback ran; a reentrant
        // `flashLoan` reverts `FlashLoanActive` and only LPVaultSwap may call, so no log can be reordered.
        // forge-lint: disable-next-line(reentrancy-events)
        emit FlashLoanServed(asset, amount, premium);
    }

    /// @inheritdoc IAaveV3FlashLoanReceiver
    /// @custom:spec REQ-FLASH-003, REQ-FLASH-004, REQ-SWAP-122, SPEC-LIQ-015, INV-040, INV-095, Q-045, Q-335, Q-390
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        if (
            msg.sender != LENDER || initiator != address(this) || assets.length != 1 || amounts.length != 1
                || premiums.length != 1 || STATE_SLOT.asUint256().tload() != STATE_OPEN
                || assets[0] != ASSET_SLOT.asAddress().tload() || amounts[0] != AMOUNT_SLOT.asUint256().tload()
                || keccak256(params) != PARAMS_HASH_SLOT.asBytes32().tload()
        ) revert InvalidFlashCallback();

        IERC20 asset = IERC20(assets[0]);
        uint256 amount = amounts[0];
        uint256 premium = premiums[0];
        _checkPremium(premium, amount);

        STATE_SLOT.asUint256().tstore(STATE_CALLED);
        PREMIUM_SLOT.asUint256().tstore(premium);

        // Forward what the Pool delivered, measured against the snapshot: less than `amount` only if the asset charges a
        // transfer fee. A balance held before the loan stays here and is never forwarded.
        uint256 balanceBefore = BALANCE_BEFORE_SLOT.asUint256().tload();
        uint256 balanceNow = asset.balanceOf(address(this));
        uint256 received = balanceNow > balanceBefore ? balanceNow - balanceBefore : 0;
        if (received != 0) asset.safeTransfer(LP_VAULT_SWAP, received);

        bytes32 magic = IFlashReceiver(LP_VAULT_SWAP).onFlashLoan(address(asset), amount, premium, params);
        if (magic != ON_FLASH_LOAN_MAGIC) revert InvalidFlashCallback();

        uint256 owed = amount + premium;
        uint256 balance = asset.balanceOf(address(this));
        if (balance < owed) revert FlashRepayShort(balance, owed);
        asset.forceApprove(LENDER, owed);
        return true;
    }

    /// @inheritdoc IFlashSource
    /// @custom:spec REQ-FLASH-001, REQ-FLASH-002, Q-334, Q-336
    function maxFlashLoan(
        address asset
    ) public view override returns (uint256 available) {
        uint256 data = IAaveV3Pool(LENDER).getConfiguration(asset);
        if (data & ACTIVE_BIT == 0 || data & PAUSED_BIT != 0 || data & FLASHLOAN_ENABLED_BIT == 0) return 0;
        address aToken = IAaveV3Pool(LENDER).getReserveAToken(asset);
        if (aToken == address(0)) return 0;
        // V3.1+ virtual accounting: the Pool lends only its virtual balance, and only what the aToken holds can move.
        available =
            Math.min(IERC20(asset).balanceOf(aToken), uint256(IAaveV3Pool(LENDER).getVirtualUnderlyingBalance(asset)));
    }

    /// @inheritdoc IFlashSource
    /// @custom:spec REQ-FLASH-001, REQ-FLASH-002, REQ-FLASH-007, SPEC-LIQ-007, Q-334, Q-373
    function flashPremium(
        address, /* asset */
        uint256 amount
    ) public view override returns (uint256 premium) {
        address provider = IAaveV3Pool(LENDER).ADDRESSES_PROVIDER();
        address aclManager = IAaveV3PoolAddressesProvider(provider).getACLManager();
        if (IAaveV3ACLManager(aclManager).isFlashBorrower(address(this))) return 0;
        uint256 rate = IAaveV3Pool(LENDER).FLASHLOAN_PREMIUM_TOTAL();
        premium = Math.mulDiv(amount, rate, BPS, Math.Rounding.Ceil);
    }

    /// @notice Reverts `FlashFeeTooHigh` unless `premium × 10⁴ ≤ maxFlashFeeBps × amount`, exact for every input.
    /// @param premium The premium quoted (before the loan) or charged (in the callback).
    /// @param amount The flash principal.
    /// @custom:spec REQ-FLASH-001, REQ-FLASH-003, SPEC-LIQ-015
    function _checkPremium(
        uint256 premium,
        uint256 amount
    ) private view {
        uint256 cap = IParameterStoreViews(PARAMETER_STORE).maxFlashFeeBps();
        if (!SettlementMath.flashPremiumWithinCap(premium, amount, cap)) {
            revert FlashFeeTooHigh(premium, Math.mulDiv(cap, amount, BPS));
        }
    }

    /// @notice Empties the six transient context slots.
    /// @custom:spec REQ-FLASH-001
    function _clearContext() private {
        STATE_SLOT.asUint256().tstore(STATE_NONE);
        ASSET_SLOT.asAddress().tstore(address(0));
        AMOUNT_SLOT.asUint256().tstore(0);
        PARAMS_HASH_SLOT.asBytes32().tstore(bytes32(0));
        PREMIUM_SLOT.asUint256().tstore(0);
        BALANCE_BEFORE_SLOT.asUint256().tstore(0);
    }
}
