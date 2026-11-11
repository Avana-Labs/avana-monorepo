// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IGhoFlashMinter
/// @notice Subset of the GHO flash minter interface (ERC-3156 lender) that the flash liquidation helper calls.
/// Declarations match `src/contracts/facilitators/flashMinter/interfaces/IGhoFlashMinter.sol` and OpenZeppelin's
/// `IERC3156FlashLender` as used by `GhoFlashMinter.sol` of aave/gho-core at commit
/// c6335a0bb9cba099960c5378b1ff0db190b8da8f, with identical selectors.
/// @dev Called by: the flash liquidation helper for GHO-debt liquidations on a chain whose GHO has a flash minter
/// (Ethereum). `flashLoan` mints `amount` GHO to the receiver, calls `receiver.onFlashLoan(msg.sender, GHO, amount,
/// fee, data)`, requires `keccak256("ERC3156FlashBorrower.onFlashLoan")` back, then pulls `amount + fee` from the
/// receiver with `transferFrom` and burns `amount`. The fee is 0 for a caller holding the ACLManager `FLASH_BORROWER`
/// role, else `percentMul(amount, fee bps)` (half up); `flashFee` computes it for `msg.sender`, so a quote the helper
/// requests itself is the fee its own `flashLoan` is charged in the same block.
interface IGhoFlashMinter {
    /// @notice Flash-mints `amount` of `token` (GHO only) to `receiver` and runs its ERC-3156 callback. Source:
    /// `IERC3156FlashLender.flashLoan`, `GhoFlashMinter.flashLoan` (gho-core c6335a0).
    /// @dev Called by: the flash liquidation helper, with itself as receiver.
    /// @param receiver The ERC-3156 borrower called back.
    /// @param token GHO; any other token reverts `FlashMinter: Unsupported currency`.
    /// @param amount The amount minted.
    /// @param data Passed unchanged to the callback.
    /// @return True when the loan was repaid.
    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);

    /// @notice The most `token` that can be flash-minted now: the minter's bucket capacity less its level, 0 for any
    /// token other than GHO. Source: `GhoFlashMinter.maxFlashLoan` (gho-core c6335a0).
    /// @dev Called by: the flash liquidation helper's `maxFlashLoan`.
    /// @param token The token.
    /// @return The maximum amount.
    function maxFlashLoan(
        address token
    ) external view returns (uint256);

    /// @notice The fee `msg.sender` is charged for `amount` of `token` (GHO only). Source: `GhoFlashMinter.flashFee`
    /// (gho-core c6335a0).
    /// @dev Called by: the flash liquidation helper's `flashPremium`, so `msg.sender` is the helper.
    /// @param token GHO.
    /// @param amount The amount.
    /// @return The fee, GHO base units.
    function flashFee(
        address token,
        uint256 amount
    ) external view returns (uint256);

    /// @notice The GHO token the minter mints. Source: `IGhoFlashMinter.GHO_TOKEN` (gho-core c6335a0).
    /// @dev Called by: the flash liquidation helper's constructor.
    /// @return The GHO token.
    function GHO_TOKEN() external view returns (address);
}
