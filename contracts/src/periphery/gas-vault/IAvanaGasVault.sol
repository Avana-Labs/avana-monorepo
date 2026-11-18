// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaGasVault
/// @notice Per-chain vault of native gas for Avana's keeper signers; anyone may top up a signer below its minimum.
/// @dev `TIMELOCK` raises and withdraws; `GUARDIAN` (or `TIMELOCK`) removes, lowers and pauses.
interface IAvanaGasVault {
    /// @notice A signer's refill rule: top up below `minBalance`, to `targetBalance`, at most `periodCap` per `PERIOD`.
    struct SignerConfig {
        uint80 minBalance;
        uint80 targetBalance;
        uint80 periodCap;
    }

    /// @notice The only withdrawal destination: the chain's `feeRecipient` treasury Safe.
    function TREASURY() external view returns (address);

    /// @notice The chain's AvanaTimelock.
    function TIMELOCK() external view returns (address);

    /// @notice The chain's Emergency Guardian Safe: removes, lowers and pauses at once; cannot raise or withdraw.
    function GUARDIAN() external view returns (address);

    /// @notice Most signers on the allowlist, `1 ≤ MAX_SIGNERS ≤ MAX_SIGNERS_LIMIT`.
    function MAX_SIGNERS() external view returns (uint256);

    /// @notice Hard bound on `MAX_SIGNERS`, which bounds `topUpAll`'s gas.
    function MAX_SIGNERS_LIMIT() external view returns (uint256);

    /// @notice The rolling window of the cap.
    function PERIOD() external view returns (uint256);

    /// @notice Most top-ups recorded per signer in any `PERIOD`.
    function MAX_SENDS_PER_PERIOD() external view returns (uint256);

    /// @notice Most gas forwarded with each ETH transfer; bounds what a recipient's code can burn.
    function TRANSFER_GAS() external view returns (uint256);

    /// @notice Accepts ETH from anyone, as `fund` does.
    receive() external payable;

    /// @notice Adds ETH to the vault (as does a plain transfer).
    function fund() external payable;

    /// @notice Tops `signer` up toward its `targetBalance`; pays `signer`, never the caller.
    /// @dev Reverts `NotBelowMinimum` unless `signer.balance < minBalance`.
    function topUp(
        address signer
    ) external returns (uint256 amount);

    /// @notice Tops up every listed signer below its minimum, skipping failed transfers; reverts only `VaultPaused`.
    function topUpAll() external returns (uint256 count, uint256 total);

    /// @notice Adds an Avana keeper signer.
    function addSigner(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external;

    /// @notice Sets a listed signer's three values, in either direction.
    function setSignerConfig(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external;

    /// @notice Unpauses top-ups.
    function unpause() external;

    /// @notice Sends `amount` to `TREASURY`.
    function withdraw(
        uint256 amount
    ) external;

    /// @notice Lowers a listed signer's values; each new value must be at most the current one.
    function tightenSigner(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external;

    /// @notice Removes a listed signer; it receives nothing afterwards.
    function removeSigner(
        address signer
    ) external;

    /// @notice Pauses top-ups (funding and withdrawal stay open).
    function pause() external;

    /// @notice Whether top-ups are paused.
    function paused() external view returns (bool);

    /// @notice The allowlist, in storage order.
    function signers() external view returns (address[] memory);

    /// @notice Whether `account` is listed.
    function isSigner(
        address account
    ) external view returns (bool);

    /// @notice A listed signer's values (zeros if not listed).
    function signerConfig(
        address signer
    ) external view returns (SignerConfig memory);

    /// @notice ETH sent to `signer` in the last `PERIOD`.
    function sentInPeriod(
        address signer
    ) external view returns (uint256);

    /// @notice What `topUp(signer)` would send and request now; `(0, 0)` if not due or listed, amount 0 while paused.
    function quoteTopUp(
        address signer
    ) external view returns (uint256 amount, uint256 requested);

    /// @notice A constructor address is `address(0)`, or `TREASURY` equals `TIMELOCK` or `GUARDIAN`.
    error InvalidAddress();

    /// @notice The constructor's `maxSigners` is 0 or above `MAX_SIGNERS_LIMIT`.
    error InvalidMaxSigners(uint256 maxSigners);

    /// @notice The caller is not `TIMELOCK`.
    error NotTimelock();

    /// @notice The caller is neither `GUARDIAN` nor `TIMELOCK`.
    error NotGuardianOrTimelock();

    /// @notice `addSigner` named `address(0)`, the vault, `TREASURY`, `TIMELOCK`, `GUARDIAN` or a listed signer.
    error InvalidSigner(address signer);

    /// @notice The signer is not on the allowlist.
    error UnknownSigner(address signer);

    /// @notice The allowlist already holds `MAX_SIGNERS` signers.
    error TooManySigners();

    /// @notice Config breaks `minBalance ≤ targetBalance`, exceeds 80 bits or has a zero outside `tightenSigner`.
    error InvalidConfig(uint256 minBalance, uint256 targetBalance, uint256 periodCap);

    /// @notice `tightenSigner` would raise one of the three values.
    error NotTighter();

    /// @notice `topUp` named a signer whose balance is not below its `minBalance`.
    error NotBelowMinimum(address signer, uint256 balance, uint256 minBalance);

    /// @notice `topUp` is due but would send 0: the signer's 24 h cap is used up or the vault holds nothing.
    /// @param requested `targetBalance − balance`.
    /// @param capRoom What the 24 h cap still allows.
    error NothingToSend(address signer, uint256 requested, uint256 capRoom, uint256 held);

    /// @notice The ETH transfer to the signer or to `TREASURY` failed.
    error SendFailed(address to, uint256 amount);

    /// @notice A top-up was called while the vault is paused.
    error VaultPaused();

    /// @notice `withdraw` asked for 0 or for more than the vault holds.
    error InvalidWithdrawal(uint256 amount, uint256 held);

    /// @notice ETH was added through `fund` or a plain transfer.
    event Funded(address indexed from, uint256 amount);

    /// @notice A signer was topped up. `amount < requested` means the cap or the vault balance limited it.
    /// @param caller `msg.sender`, who receives nothing.
    /// @param requested `targetBalance − balance` before the send.
    event ToppedUp(address indexed signer, address indexed caller, uint256 amount, uint256 requested);

    /// @notice `topUpAll` skipped a signer whose ETH transfer failed; nothing was sent or recorded for it.
    event TopUpFailed(address indexed signer, uint256 amount);

    /// @notice A signer was added to the allowlist.
    /// @param periodCap Most ETH sent to it in any 24 h.
    event SignerAdded(address indexed signer, uint256 minBalance, uint256 targetBalance, uint256 periodCap);

    /// @notice A signer's configuration changed through `setSignerConfig` or `tightenSigner`.
    /// @param by `TIMELOCK` or `GUARDIAN`.
    event SignerConfigChanged(
        address indexed signer, address indexed by, uint256 minBalance, uint256 targetBalance, uint256 periodCap
    );

    /// @notice A signer was removed from the allowlist.
    /// @param by `TIMELOCK` or `GUARDIAN`.
    event SignerRemoved(address indexed signer, address indexed by);

    /// @notice Top-ups were paused or unpaused.
    /// @param by `TIMELOCK` or `GUARDIAN`.
    event PauseChanged(bool paused, address indexed by);

    /// @notice ETH was withdrawn to `TREASURY`.
    event Withdrawn(uint256 amount);
}
