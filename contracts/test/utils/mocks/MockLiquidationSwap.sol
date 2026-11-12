// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapLiquidation} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {LiquidationParams} from "../../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IPayoutEscrow} from "../../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {ILock} from "../../../src/lock/lock/ILock.sol";
import {PayoutToken} from "./PayoutToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockLiquidationSwap
/// @notice LPVaultSwap's `liquidate` as the flash liquidation helper sees it (a stand-in for LPVaultSwap in these
/// tests), following `ILPVaultSwapLiquidation` and the 2.11 settlement rules that bind a caller: `DeadlineExpired` first,
/// then `AddressIsFrozen(msg.sender)`; acquires the real Lock; pulls `X = debtToCover` from `msg.sender` with
/// `transferFrom` and measures `Kf` (`FundingMismatch` unless `0 < Kf ≤ X`); lets the Spoke take `D ≤ Kf`; mints the
/// recovery `R` of the debt asset (the unwind and the swap routes); applies the `SPEC-LIQ-019` floor top-up: with the
/// test's recovery floor `minRec`, `shortfall = max(0, minRec − R)`, `RecoveryBelowFloor` above `maxShortfall`, else
/// exactly `shortfall` pulled from `msg.sender` with `transferFrom`; pays Avana's fee `A` to `feeRecipient` and each
/// route residue or dust leg to `msg.sender` by the gas-limited delivery of `REQ-SWAP-076`, which deposits a refused
/// payout in the real PayoutEscrow credited to its recipient; pays `keeperOut = Kf + R + shortfall − D − A` to
/// `msg.sender` with a
/// plain transfer, so a refused `keeperOut` reverts the call (`REQ-SWAP-026`); applies `PayoutTooLow(keeperOut,
/// minPayout)`. Records every call. A hook can call any target while the Lock is held (a reentrant token or route).
/// @dev The outcome `(D, R, A)` and the residues are set by the test before the call.
contract MockLiquidationSwap is ILPVaultSwapLiquidation {
    using SafeERC20 for IERC20;

    /// @notice Gas forwarded to each escrowable payout transfer (`PAYOUT_TRANSFER_GAS`).
    uint256 public constant PAYOUT_TRANSFER_GAS = 100_000;
    /// @notice Where the Spoke's pull of `D` goes.
    address public constant SPOKE = address(0x5B0CE);

    ILock public lock;
    IPayoutEscrow public escrow;
    address public feeRecipient;
    PayoutToken public debtAsset;

    uint256 public debtRepaid;
    uint256 public recovered;
    uint256 public avanaFee;
    uint256 public minRecovery;
    PayoutToken[] internal _residueTokens;
    uint256[] internal _residueAmounts;
    mapping(address account => bool isFrozen) public frozen;
    address public hookTarget;
    bytes public hookData;

    uint256 public calls;
    address public lastCaller;
    bytes32 public lastParamsHash;
    uint256 public lastKf;
    uint256 public lastKeeperOut;
    uint256 public lastEscrowed;
    uint256 public lastShortfall;

    function setUp(
        ILock lock_,
        IPayoutEscrow escrow_,
        PayoutToken debtAsset_,
        address feeRecipient_
    ) external {
        require(address(lock) == address(0), "set");
        lock = lock_;
        escrow = escrow_;
        debtAsset = debtAsset_;
        feeRecipient = feeRecipient_;
    }

    /// @notice Points the mock at another debt asset (a GHO-debt liquidation in the same suite).
    function setDebtAsset(
        PayoutToken debtAsset_
    ) external {
        debtAsset = debtAsset_;
    }

    /// @notice LPVaultSwap's view of its escrow (`ILPVaultSwapViews.PAYOUT_ESCROW`).
    function PAYOUT_ESCROW() external view returns (address) {
        return address(escrow);
    }

    function setOutcome(
        uint256 debtRepaid_,
        uint256 recovered_,
        uint256 avanaFee_
    ) external {
        debtRepaid = debtRepaid_;
        recovered = recovered_;
        avanaFee = avanaFee_;
    }

    /// @notice Sets the recovery floor `minRec` of `SPEC-LIQ-005` the next calls test `R + shortfall` against.
    function setFloor(
        uint256 minRecovery_
    ) external {
        minRecovery = minRecovery_;
    }

    function addResidue(
        PayoutToken token,
        uint256 amount
    ) external {
        _residueTokens.push(token);
        _residueAmounts.push(amount);
    }

    function setFrozen(
        address account,
        bool isFrozen
    ) external {
        frozen[account] = isFrozen;
    }

    function setHook(
        address target,
        bytes calldata data
    ) external {
        hookTarget = target;
        hookData = data;
    }

    function liquidate(
        LiquidationParams calldata params
    ) external override returns (LiquidationResult memory result) {
        if (block.timestamp > params.deadline) revert ILPVaultSwapErrors.DeadlineExpired(params.deadline);
        if (frozen[msg.sender]) revert ILPVaultSwapErrors.AddressIsFrozen(msg.sender);
        lock.acquire();
        ++calls;
        lastCaller = msg.sender;
        lastParamsHash = keccak256(abi.encode(params));
        if (hookTarget != address(0)) _bubble(hookTarget, hookData);

        IERC20 asset = IERC20(address(debtAsset));
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), params.debtToCover);
        uint256 kf = asset.balanceOf(address(this)) - before;
        if (kf == 0 || kf > params.debtToCover) revert ILPVaultSwapErrors.FundingMismatch();
        uint256 d = debtRepaid < kf ? debtRepaid : kf;
        if (d != 0) asset.safeTransfer(SPOKE, d);
        if (recovered != 0) debtAsset.mint(address(this), recovered);
        // SPEC-LIQ-019: the floor gap is the caller's, pulled from msg.sender after the routes, within maxShortfall.
        uint256 shortfall = minRecovery > recovered ? minRecovery - recovered : 0;
        if (shortfall > params.maxShortfall) revert ILPVaultSwapErrors.RecoveryBelowFloor();
        if (shortfall != 0) asset.safeTransferFrom(msg.sender, address(this), shortfall);
        uint256 keeperOut = kf + recovered + shortfall - d - avanaFee;
        if (keeperOut < params.minPayout) revert ILPVaultSwapErrors.PayoutTooLow(keeperOut, params.minPayout);

        if (avanaFee != 0) _deliver(asset, feeRecipient, avanaFee);
        if (keeperOut != 0) asset.safeTransfer(msg.sender, keeperOut);
        for (uint256 i = 0; i < _residueTokens.length; ++i) {
            _residueTokens[i].mint(address(this), _residueAmounts[i]);
            _deliver(IERC20(address(_residueTokens[i])), msg.sender, _residueAmounts[i]);
        }
        lastKf = kf;
        lastKeeperOut = keeperOut;
        lastShortfall = shortfall;
        lock.release();

        result.debtAsset = address(asset);
        result.debtRepaid = d;
        result.callerFunds = kf;
        result.recovered = recovered;
        result.minOut = minRecovery;
        result.avanaFee = avanaFee;
        result.keeperOut = keeperOut;
        result.shortfall = shortfall;
    }

    function settlePending(
        uint256,
        uint256
    ) external pure override returns (uint256, uint256[] memory, uint256) {
        revert("not modelled");
    }

    /// @dev `REQ-SWAP-076`: a low-level transfer with `PAYOUT_TRANSFER_GAS`; on failure an exact approval and a deposit
    /// in the escrow credited to `to`.
    function _deliver(
        IERC20 token,
        address to,
        uint256 amount
    ) internal {
        (bool ok, bytes memory ret) =
            address(token).call{gas: PAYOUT_TRANSFER_GAS}(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) return;
        token.forceApprove(address(escrow), amount);
        escrow.deposit(address(token), to, amount);
        token.forceApprove(address(escrow), 0);
        lastEscrowed += amount;
    }

    function _bubble(
        address target,
        bytes memory data
    ) internal {
        (bool ok, bytes memory reason) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}
