// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaGasVault} from "./IAvanaGasVault.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title AvanaGasVault
/// @notice Holds the chain's native gas token and refills Avana's own keeper signers (2.23 `REQ-GASV-001`…). A top-up
/// is permissionless and benefits nobody but the allowlisted signer: the destination and the amount
/// `min(targetBalance − balance, periodCap − sentInPeriod, address(this).balance)` come from on-chain state alone.
/// Example: `minBalance = 0.3 ETH`, `targetBalance = 1 ETH`, `periodCap = 1 ETH`, signer at 0.2 ETH and nothing sent in
/// the last 24 h: `topUp` sends 0.8 ETH; a second call is refused (`NotBelowMinimum`) until the signer drops below
/// 0.3 ETH again, and then sends at most the 0.2 ETH left of the 24 h cap.
/// @dev The 24 h cap is exact over any window, not per calendar period: each signer keeps its last
/// `MAX_SENDS_PER_PERIOD` sends (time and amount, two per slot), `sentInPeriod` sums those in `(now − PERIOD, now]`, and a
/// send is allowed only into a slot whose entry is older. So the ETH sent to a signer in any `PERIOD` never exceeds the
/// `periodCap` in force at each send, and a stolen signer key costs at most its balance (≤ `targetBalance`) plus one
/// `periodCap` before `GUARDIAN` removes it. Immutable, with no role storage: privileged calls check
/// `msg.sender == TIMELOCK` or `GUARDIAN` (`REQ-ROLE-001`).
/// @custom:spec REQ-GASV-001, REQ-GASV-002, REQ-GASV-004, REQ-GASV-005, REQ-GASV-013
contract AvanaGasVault is IAvanaGasVault, ReentrancyGuardTransient {
    /// @inheritdoc IAvanaGasVault
    uint256 public constant override PERIOD = 24 hours;

    /// @inheritdoc IAvanaGasVault
    uint256 public constant override MAX_SENDS_PER_PERIOD = 4;

    /// @inheritdoc IAvanaGasVault
    uint256 public constant override MAX_SIGNERS_LIMIT = 8;

    /// @inheritdoc IAvanaGasVault
    address public immutable override TREASURY;

    /// @inheritdoc IAvanaGasVault
    address public immutable override TIMELOCK;

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
    /// @dev Gas forwarded with each ETH transfer, as for LPVaultSwap's payouts: ample for an EOA or a Safe's `receive`,
    /// and it bounds what a recipient's code can burn of the caller's gas (`topUpAll` at most 8 of them).
    uint256 private constant TRANSFER_GAS = 100_000;
    uint256 private constant AMOUNT_MASK = (1 << AMOUNT_BITS) - 1;

    /// @inheritdoc IAvanaGasVault
    bool public override paused;

    address[] private _signerList;
    mapping(address signer => Signer) private _signer;
    /// @dev Each entry `(uint48 timestamp << 80) | uint80 amount`; 0 is an empty entry. Kept on removal, so a signer
    /// removed and re-added inside 24 h keeps its window.
    mapping(address signer => uint128[MAX_SENDS_PER_PERIOD]) private _sends;

    modifier onlyTimelock() {
        if (msg.sender != TIMELOCK) revert NotTimelock();
        _;
    }

    modifier onlyGuardianOrTimelock() {
        if (msg.sender != GUARDIAN && msg.sender != TIMELOCK) revert NotGuardianOrTimelock();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }

    /// @notice Fixes the treasury, the timelock, the guardian and the allowlist bound.
    /// @dev Reverts `InvalidAddress` for a zero address or a `treasury` equal to `timelock` or `guardian`, and
    /// `InvalidMaxSigners` unless `1 ≤ maxSigners ≤ 8`. The deploy script also checks that `treasury` is the
    /// ParameterStore's `feeRecipient` and not `FUNDING_SAFE`.
    /// @param treasury The `feeRecipient` treasury Safe, the only withdrawal destination.
    /// @param timelock The chain's AvanaTimelock.
    /// @param guardian The chain's Emergency Guardian Safe.
    /// @param maxSigners Most signers on the allowlist.
    /// @custom:spec REQ-GASV-002
    constructor(
        address treasury,
        address timelock,
        address guardian,
        uint256 maxSigners
    ) {
        if (
            treasury == address(0) || timelock == address(0) || guardian == address(0) || treasury == timelock
                || treasury == guardian
        ) revert InvalidAddress();
        if (maxSigners == 0 || maxSigners > MAX_SIGNERS_LIMIT) revert InvalidMaxSigners(maxSigners);
        TREASURY = treasury;
        TIMELOCK = timelock;
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

    // ─── Top-ups ───

    /// @inheritdoc IAvanaGasVault
    /// @dev `signer` needs no zero check: an unlisted address reverts `UnknownSigner`, and `addSigner` never lists 0.
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
        // The loop is bounded by `MAX_SIGNERS ≤ 8`; each destination is a listed signer and each amount capped by
        // `_quote`; a signer whose transfer fails is skipped, so no signer can block the others; reentry is refused by
        // `nonReentrant`; the record is written before the transfer and restored (a storage write in the loop) only
        // when the transfer fails, and `ToppedUp` follows the transfer because a failed one emits `TopUpFailed` instead.
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

    // ─── TIMELOCK ───

    /// @inheritdoc IAvanaGasVault
    function addSigner(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external override onlyTimelock {
        if (
            signer == address(0) || signer == address(this) || signer == TREASURY || signer == TIMELOCK
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
    ) external override onlyTimelock {
        if (_signer[signer].position == 0) revert UnknownSigner(signer);
        _checkConfig(minBalance, targetBalance, periodCap, false);
        _setConfig(signer, minBalance, targetBalance, periodCap);
    }

    /// @inheritdoc IAvanaGasVault
    function unpause() external override onlyTimelock {
        paused = false;
        emit PauseChanged(false, msg.sender);
    }

    /// @inheritdoc IAvanaGasVault
    function withdraw(
        uint256 amount
    ) external override nonReentrant onlyTimelock {
        uint256 held = address(this).balance;
        if (amount == 0 || amount > held) revert InvalidWithdrawal(amount, held);
        emit Withdrawn(amount);
        if (!_send(TREASURY, amount)) revert SendFailed(TREASURY, amount);
    }

    // ─── GUARDIAN or TIMELOCK ───

    /// @inheritdoc IAvanaGasVault
    function tightenSigner(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external override onlyGuardianOrTimelock {
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
    ) external override onlyGuardianOrTimelock {
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
    function pause() external override onlyGuardianOrTimelock {
        paused = true;
        emit PauseChanged(true, msg.sender);
    }

    // ─── Views ───

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

    // ─── Internals ───

    /// @dev The top-up for a signer below its minimum: `requested = targetBalance − balance`, never 0 because every
    /// configuration keeps `minBalance ≤ targetBalance` (`_checkConfig`) and the callers pass only `balance < minBalance`;
    /// `capRoom = periodCap − sent` (0 when sent ≥ cap or no slot is free); `amount = min(requested, capRoom,
    /// address(this).balance)`.
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

    /// @dev Sum of the sends in `(now − PERIOD, now]` and the first slot free for a new send (`MAX_SENDS_PER_PERIOD`
    /// if none): a slot is free when empty or older than `PERIOD`.
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

    /// @dev Sends `amount` wei to `to` with empty calldata, forwarding at most `TRANSFER_GAS` and copying no return data
    /// (as LPVaultSwap's payouts): a reverting, gas-burning or return-bombing recipient only makes the transfer fail.
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

    /// @dev `minBalance ≤ targetBalance`, every value ≤ 2^80 − 1, and (unless tightening) `minBalance > 0` and
    /// `periodCap > 0`.
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
