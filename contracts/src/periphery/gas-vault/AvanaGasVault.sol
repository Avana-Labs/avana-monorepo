// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaGasVault} from "./IAvanaGasVault.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title AvanaGasVault
/// @notice Holds the native gas token and refills Avana's keeper signers through permissionless top-ups.
/// @dev The cap holds over any rolling `PERIOD` window, not per calendar period.
// The AccessManager check of `restricted` is the only external call before an event; it holds no funds and cannot reenter.
// forge-lint: disable-start(reentrancy-events)
contract AvanaGasVault is IAvanaGasVault, AccessManaged, ReentrancyGuardTransient {
    /// @inheritdoc IAvanaGasVault
    uint256 public constant override PERIOD = 24 hours;

    /// @inheritdoc IAvanaGasVault
    uint256 public constant override MAX_SENDS_PER_PERIOD = 4;

    /// @inheritdoc IAvanaGasVault
    uint256 public constant override MAX_SIGNERS_LIMIT = 8;

    /// @inheritdoc IAvanaGasVault
    uint256 public constant override TRANSFER_GAS = 100_000;

    /// @inheritdoc IAvanaGasVault
    address public immutable override TREASURY;

    /// @inheritdoc IAvanaGasVault
    address public immutable override GUARDIAN;

    /// @inheritdoc IAvanaGasVault
    uint256 public immutable override MAX_SIGNERS;

    /// @dev A listed signer's values and its position in `_signerList` plus one (0 = not listed). One slot.
    struct Signer {
        uint80 minBalance;
        uint80 targetBalance;
        uint80 periodCap;
        uint8 position;
    }

    uint256 private constant AMOUNT_BITS = 80;
    uint256 private constant AMOUNT_MASK = (1 << AMOUNT_BITS) - 1;

    /// @inheritdoc IAvanaGasVault
    bool public override paused;

    address[] private _signerList;
    mapping(address signer => Signer) private _signer;
    /// @dev Entries `(uint48 timestamp << 80) | uint80 amount`; kept on removal so a re-added signer keeps its window.
    mapping(address signer => uint128[MAX_SENDS_PER_PERIOD]) private _sends;

    /// @dev The guardian acts at once; any other caller needs the AccessManager's permission (and its delay).
    modifier onlyGuardianOrAuthorized() {
        if (msg.sender != GUARDIAN) _checkCanCall(msg.sender, msg.data);
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }

    /// @notice Fixes the treasury, the AccessManager, the guardian and the allowlist bound.
    /// @param treasury The `feeRecipient` treasury Safe, the only withdrawal destination.
    constructor(
        address treasury,
        address authority,
        address guardian,
        uint256 maxSigners
    ) AccessManaged(authority) {
        if (
            treasury == address(0) || authority == address(0) || guardian == address(0) || treasury == authority
                || treasury == guardian
        ) revert InvalidAddress();
        if (maxSigners == 0 || maxSigners > MAX_SIGNERS_LIMIT) revert InvalidMaxSigners(maxSigners);
        TREASURY = treasury;
        GUARDIAN = guardian;
        MAX_SIGNERS = maxSigners;
    }

    /// @inheritdoc IAvanaGasVault
    receive() external payable override {
        emit Funded(msg.sender, msg.value);
    }

    /// @inheritdoc IAvanaGasVault
    function fund() external payable override {
        emit Funded(msg.sender, msg.value);
    }

    /// @inheritdoc IAvanaGasVault
    function topUp(
        address signer
    ) external override nonReentrant whenNotPaused returns (uint256 amount) {
        Signer memory s = _signer[signer];
        if (s.position == 0) revert UnknownSigner(signer);
        uint256 balance = signer.balance;
        if (balance >= s.minBalance) revert NotBelowMinimum(signer, balance, s.minBalance);
        uint256 requested;
        uint256 capRoom;
        uint256 slot;
        (amount, requested, capRoom, slot) = _quote(signer, s, balance);
        if (amount == 0) revert NothingToSend(signer, requested, capRoom, address(this).balance);
        _record(signer, slot, amount);
        emit ToppedUp(signer, msg.sender, amount, requested);
        // The destination is a listed signer (checked above), never the caller, and the amount is capped by `_quote`.
        if (!_send(signer, amount)) revert SendFailed(signer, amount);
    }

    /// @inheritdoc IAvanaGasVault
    function topUpAll() external override nonReentrant whenNotPaused returns (uint256 count, uint256 total) {
        uint256 n = _signerList.length;
        // Bounded by `MAX_SIGNERS`; a failed transfer is skipped and its record restored, so no signer blocks others.
        // forge-lint: disable-start(costly-loop, reentrancy-events)
        for (uint256 i = 0; i < n; ++i) {
            address signer = _signerList[i];
            Signer memory s = _signer[signer];
            uint256 balance = signer.balance;
            if (balance >= s.minBalance) continue;
            (uint256 amount, uint256 requested,, uint256 slot) = _quote(signer, s, balance);
            if (amount == 0) continue;
            uint128 previous = _sends[signer][slot];
            _record(signer, slot, amount);
            if (!_send(signer, amount)) {
                // Nothing left the vault: the record is undone so the failed send does not use the cap.
                _sends[signer][slot] = previous;
                emit TopUpFailed(signer, amount);
                continue;
            }
            emit ToppedUp(signer, msg.sender, amount, requested);
            ++count;
            total += amount;
        }
        // forge-lint: disable-end(costly-loop, reentrancy-events)
    }

    /// @inheritdoc IAvanaGasVault
    function addSigner(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external override restricted {
        if (
            signer == address(0) || signer == address(this) || signer == TREASURY || signer == authority()
                || signer == GUARDIAN || _signer[signer].position != 0
        ) revert InvalidSigner(signer);
        if (_signerList.length >= MAX_SIGNERS) revert TooManySigners();
        _checkConfig(minBalance, targetBalance, periodCap, false);
        _signerList.push(signer);
        // Each value is ≤ 2^80 − 1 (`_checkConfig`) and the position ≤ MAX_SIGNERS ≤ 8, so no cast reverts.
        _signer[signer] = Signer({
            minBalance: SafeCast.toUint80(minBalance),
            targetBalance: SafeCast.toUint80(targetBalance),
            periodCap: SafeCast.toUint80(periodCap),
            position: SafeCast.toUint8(_signerList.length)
        });
        emit SignerAdded(signer, minBalance, targetBalance, periodCap);
    }

    /// @inheritdoc IAvanaGasVault
    function setSignerConfig(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external override restricted {
        if (_signer[signer].position == 0) revert UnknownSigner(signer);
        _checkConfig(minBalance, targetBalance, periodCap, false);
        _setConfig(signer, minBalance, targetBalance, periodCap);
    }

    /// @inheritdoc IAvanaGasVault
    function unpause() external override restricted {
        paused = false;
        emit PauseChanged(false, msg.sender);
    }

    /// @inheritdoc IAvanaGasVault
    function withdraw(
        uint256 amount
    ) external override nonReentrant restricted {
        uint256 held = address(this).balance;
        if (amount == 0 || amount > held) revert InvalidWithdrawal(amount, held);
        emit Withdrawn(amount);
        if (!_send(TREASURY, amount)) revert SendFailed(TREASURY, amount);
    }

    /// @inheritdoc IAvanaGasVault
    function tightenSigner(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external override onlyGuardianOrAuthorized {
        Signer memory s = _listed(signer);
        if (minBalance > s.minBalance || targetBalance > s.targetBalance || periodCap > s.periodCap) {
            revert NotTighter();
        }
        _checkConfig(minBalance, targetBalance, periodCap, true);
        _setConfig(signer, minBalance, targetBalance, periodCap);
    }

    /// @inheritdoc IAvanaGasVault
    function removeSigner(
        address signer
    ) external override onlyGuardianOrAuthorized {
        uint256 index = _listed(signer).position - 1;
        uint256 last = _signerList.length - 1;
        if (index != last) {
            address moved = _signerList[last];
            _signerList[index] = moved;
            _signer[moved].position = SafeCast.toUint8(index + 1);
        }
        _signerList.pop();
        delete _signer[signer];
        emit SignerRemoved(signer, msg.sender);
    }

    /// @inheritdoc IAvanaGasVault
    function pause() external override onlyGuardianOrAuthorized {
        paused = true;
        emit PauseChanged(true, msg.sender);
    }

    /// @inheritdoc IAvanaGasVault
    function signers() external view override returns (address[] memory) {
        return _signerList;
    }

    /// @inheritdoc IAvanaGasVault
    function isSigner(
        address account
    ) external view override returns (bool) {
        return _signer[account].position != 0;
    }

    /// @inheritdoc IAvanaGasVault
    function signerConfig(
        address signer
    ) external view override returns (SignerConfig memory config) {
        Signer memory s = _signer[signer];
        config = SignerConfig({minBalance: s.minBalance, targetBalance: s.targetBalance, periodCap: s.periodCap});
    }

    /// @inheritdoc IAvanaGasVault
    function sentInPeriod(
        address signer
    ) external view override returns (uint256 sent) {
        (sent,) = _window(signer);
    }

    /// @inheritdoc IAvanaGasVault
    function quoteTopUp(
        address signer
    ) external view override returns (uint256 amount, uint256 requested) {
        Signer memory s = _signer[signer];
        uint256 balance = signer.balance;
        if (s.position == 0 || balance >= s.minBalance) return (0, 0);
        (amount, requested,,) = _quote(signer, s, balance);
        if (paused) amount = 0;
    }

    /// @dev `amount = min(targetBalance − balance, cap room, vault balance)`; cap room is 0 when no slot is free.
    function _quote(
        address signer,
        Signer memory s,
        uint256 balance
    ) private view returns (uint256 amount, uint256 requested, uint256 capRoom, uint256 slot) {
        requested = s.targetBalance - balance;
        uint256 sent;
        (sent, slot) = _window(signer);
        capRoom = slot < MAX_SENDS_PER_PERIOD && sent < s.periodCap ? s.periodCap - sent : 0;
        amount = requested < capRoom ? requested : capRoom;
        uint256 held = address(this).balance;
        if (held < amount) amount = held;
    }

    /// @dev Sum of the sends in the last `PERIOD` and the first free slot (`MAX_SENDS_PER_PERIOD` if none).
    function _window(
        address signer
    ) private view returns (uint256 sent, uint256 free) {
        free = MAX_SENDS_PER_PERIOD;
        uint128[MAX_SENDS_PER_PERIOD] storage sends = _sends[signer];
        for (uint256 i = 0; i < MAX_SENDS_PER_PERIOD; ++i) {
            uint256 entry = sends[i];
            uint256 at = entry >> AMOUNT_BITS;
            if (entry != 0 && at + PERIOD > block.timestamp) {
                sent += entry & AMOUNT_MASK;
            } else if (free == MAX_SENDS_PER_PERIOD) {
                free = i;
            }
        }
    }

    /// @dev Records a send of `amount` (≤ 2^80 − 1, bounded by `periodCap`) at `block.timestamp` in `slot`.
    function _record(
        address signer,
        uint256 slot,
        uint256 amount
    ) private {
        _sends[signer][slot] = SafeCast.toUint128((uint256(SafeCast.toUint48(block.timestamp)) << AMOUNT_BITS) | amount);
    }

    /// @dev Forwards at most `TRANSFER_GAS` and copies no return data, so a hostile recipient only makes it fail.
    function _send(
        address to,
        uint256 amount
    ) private returns (bool ok) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            ok := call(TRANSFER_GAS, to, amount, 0, 0, 0, 0)
        }
    }

    function _setConfig(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) private {
        Signer storage s = _signer[signer];
        (s.minBalance, s.targetBalance, s.periodCap) =
        (SafeCast.toUint80(minBalance), SafeCast.toUint80(targetBalance), SafeCast.toUint80(periodCap));
        emit SignerConfigChanged(signer, msg.sender, minBalance, targetBalance, periodCap);
    }

    /// @dev `minBalance ≤ targetBalance`, values fit 80 bits, and (unless tightening) no zero `minBalance` or cap.
    function _checkConfig(
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap,
        bool tighten
    ) private pure {
        if (
            minBalance > targetBalance || targetBalance > AMOUNT_MASK || periodCap > AMOUNT_MASK
                || (!tighten && (minBalance == 0 || periodCap == 0))
        ) revert InvalidConfig(minBalance, targetBalance, periodCap);
    }

    function _listed(
        address signer
    ) private view returns (Signer memory s) {
        s = _signer[signer];
        if (s.position == 0) revert UnknownSigner(signer);
    }
}
// forge-lint: disable-end(reentrancy-events)
