// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title IVaultToken
/// @notice Collateral-only ERC-20 of one market (one chain, AMM protocol, pool and exact position shape = one vault
/// token = one CDP Spoke reserve); one base unit equals one position unit Collateralization credited in a position the
/// market's LPVault holds.
/// @dev Non-upgradeable with no owner, admin, role, setter, pause, blocklist or `selfdestruct`. ERC-20 semantics of
/// OpenZeppelin `ERC20` (balances, allowances, `Transfer` and `Approval` events, `ERC20InsufficientBalance` and
/// `ERC20InsufficientAllowance` errors); no `permit`, hooks, callbacks, flash minting, rebasing, transfer fees or
/// emissions. Transfer rule: every balance change of the market's token is one of five paths, and everything else
/// reverts, including every zero-amount `transfer` or `transferFrom` (on an allowed path too) and transfers by a
/// spender (`UnauthorizedTransfer(from, to)`):
/// (1) mint, `address(0)` to a registered proxy, by the AaveAdapter (pledge, re-credit); (2) supply, a registered
/// proxy to `hub()`, moved by the CDP Spoke as spender inside `Spoke.supply` (the Adapter sets the allowance through
/// `proxy.execute` and resets it to 0); (3) withdrawal, `hub()` to a registered proxy, because `Spoke.withdraw` calls
/// `hub.remove(assetId, amount, msg.sender)` and the caller is the proxy; (4) seizure, `hub()` to `lpVaultSwap()`, from
/// `liquidationCall` with `receiveShares = false`; (5) burn, a registered proxy or `lpVaultSwap()` to `address(0)`, by
/// the AaveAdapter. There is no Hub-to-Adapter path: the Adapter burns withdrawn units from the proxy in the same call.
/// The AaveAdapter is the only minter, burner and registry writer (`OnlyAdapter`). Total supply is at most the market's
/// credited total plus its pending-settlement units at the end of every transaction, with equality while every seizure
/// burn is settled in the same call. Between transactions vault tokens rest only in the Hub, except units LPVaultSwap
/// holds from a seizure that was never settled. Constructor arguments (passed by the VaultTokenFactory): `marketKey`,
/// `integrationId`, `integration` (the registered LPVault), `hub`, `spoke`, `marketId`, `lpOracle`, `adapter`,
/// `lpVaultSwap`, `collateralization`, `decimals` (`d` of `SPEC-UNIT-001`), `name` (the market's full description:
/// chain, AMM protocol, pair, fee tier, range and market ID) and `symbol` (`avLP-<marketId>`); the constructor refuses
/// a zero address (`ZeroAddress`, checked first) and a zero ID, key or market, decimals outside [6, 18], two equal
/// address bindings or a binding equal to the token's own address (`InvalidBinding`). `transfer` and `transferFrom`
/// check the amount and the path before the receiver and the allowance, so an off-path or zero-amount call reverts
/// `UnauthorizedTransfer` whatever the allowance and spends none. Units leave the Hub only to a registered proxy or to
/// LPVaultSwap, so a `liquidationCall` by anyone else reverts on the token transfer whenever it seizes at least one
/// unit; a dust liquidation whose seized amount rounds to zero shares moves no token, cannot be refused here and
/// repays debt for the borrower at the caller's expense. The registry bounds seizure only as far as the Adapter's
/// registrations do: an address the Adapter registered can receive units from the Hub through any Aave call that
/// pays it, which is why a proxy has no `liquidationCall` path (`REQ-PROXY-008`). This holds only under the standard
/// Aave V4 Spoke configuration the listing sets and the drift check enforces (`receiveSharesEnabled = false`,
/// `liquidationFee = 0`, `borrowable = false`, `drawCap = 0`, no reinvestment controller); a non-zero
/// `liquidationFee` pays the fee as Hub shares with no token transfer, which the token cannot refuse and which no
/// address can ever withdraw, so every vault-token reserve has `liquidationFee = 0` with no alternative. Drift trips a
/// breaker that stops new activity, never liquidation.
/// @custom:spec REQ-VTOKEN-001, REQ-VTOKEN-002, REQ-VTOKEN-005, REQ-VTOKEN-006, REQ-VTOKEN-007, REQ-VTOKEN-008, REQ-VTOKEN-009, REQ-VTOKEN-010, REQ-VTOKEN-011, REQ-VTOKEN-015, REQ-VTOKEN-016, REQ-VTOKEN-017, REQ-VTOKEN-018, REQ-VTOKEN-025, REQ-VTOKEN-026, REQ-VTOKEN-027, REQ-VTOKEN-028, REQ-VTOKEN-029, REQ-VTOKEN-031, REQ-VTOKEN-034, REQ-VTOKEN-038, REQ-VTOKEN-041, REQ-VTOKEN-046, REQ-VTOKEN-048, SPEC-UNIT-002, SPEC-UNIT-003, SPEC-UNIT-004, SPEC-UNIT-005, SPEC-UNIT-006, INV-001, INV-011, Q-224, Q-374
interface IVaultToken is IERC20Metadata {
    /// @notice A proxy was registered as a valid recipient of this market's token.
    /// @param proxy The registered proxy.
    /// @custom:spec REQ-VTOKEN-039
    event ProxyAdded(address indexed proxy);

    /// @notice `mint`, `burn` or `addValidProxy` was called by an address other than the AaveAdapter.
    /// @custom:spec REQ-VTOKEN-012, REQ-VTOKEN-014, REQ-VTOKEN-032, REQ-VTOKEN-039
    error OnlyAdapter();

    /// @notice `to` of a mint is not a registered proxy.
    /// @param to The rejected recipient.
    /// @custom:spec REQ-VTOKEN-012, REQ-VTOKEN-033
    error UnauthorizedRecipient(address to);

    /// @notice A transfer, or the source of a burn (`to == address(0)`), is off the five allowed paths.
    /// @param from The sender, or the holder of a burn.
    /// @param to The recipient, or `address(0)` for a burn.
    /// @custom:spec REQ-VTOKEN-006, REQ-VTOKEN-008, REQ-VTOKEN-030, REQ-VTOKEN-041
    error UnauthorizedTransfer(address from, address to);

    /// @notice `mint` to, `burn` from or `addValidProxy` of `address(0)`, or a zero address binding at construction.
    /// @custom:spec REQ-VTOKEN-012, REQ-VTOKEN-014, REQ-VTOKEN-039, REQ-VTOKEN-043, REQ-VTOKEN-046
    error ZeroAddress();

    /// @notice `addValidProxy` of one of the token's own bindings (`hub()`, `spoke()`, `adapter()`, `lpVaultSwap()`,
    /// `collateralization()`, `integration()`, `lpOracle()`) or of the token itself.
    /// @param account The refused address.
    /// @custom:spec REQ-VTOKEN-039, REQ-VTOKEN-042, REQ-VTOKEN-047
    error ReservedAddress(address account);

    /// @notice A constructor binding is invalid: `integrationId`, `marketKey` or `marketId` is 0, `decimals` lies
    /// outside [6, 18], the seven address bindings are not pairwise distinct, or one of them is the token's own address.
    /// @custom:spec REQ-VTOKEN-046
    error InvalidBinding();

    /// @notice Mints credited units.
    /// @dev The call reverts with `OnlyAdapter` unless `msg.sender == adapter()`, with `ZeroAddress` if
    /// `to == address(0)`, and with `UnauthorizedRecipient(to)` unless `to` is a registered proxy (neither the Hub, the
    /// Adapter nor LPVaultSwap is a mint destination). Avana's flows mint only inside a pledge or a re-credit, exactly
    /// the `credited` or `added` units Collateralization returns, to the depositor's registered proxy. Emits
    /// `Transfer(address(0), to, amount)`; a zero `amount` keeps these checks and changes no balance.
    /// @param to A registered proxy of this market.
    /// @param amount Base units, equal to credited position units.
    /// @custom:spec REQ-VTOKEN-012, REQ-VTOKEN-013, REQ-VTOKEN-015, REQ-VTOKEN-032, REQ-VTOKEN-033, REQ-VTOKEN-043, DEP-013, DEP-024, INV-009, Q-254
    function mint(
        address to,
        uint256 amount
    ) external;

    /// @notice Burns from any holder without an allowance.
    /// @dev The call reverts with `OnlyAdapter` unless `msg.sender == adapter()` and with `ZeroAddress` if
    /// `from == address(0)`, with `UnauthorizedTransfer(from, address(0))` unless `from` is a registered proxy or
    /// `lpVaultSwap()`, and with `ERC20InsufficientBalance` for an amount above the balance. Avana's flows burn only
    /// from a proxy that has just withdrawn the units (withdrawal, partial removal, repay with collateral) and from
    /// LPVaultSwap (`burnSeized`, seizure and pending settlement), so the Hub's balance can never be burned. Emits
    /// `Transfer(from, address(0), amount)`.
    /// @param from A registered proxy or LPVaultSwap.
    /// @param amount Base units to burn.
    /// @custom:spec REQ-VTOKEN-014, REQ-VTOKEN-015, REQ-VTOKEN-032, REQ-VTOKEN-042, REQ-VTOKEN-043, INV-010, Q-254, Q-255
    function burn(
        address from,
        uint256 amount
    ) external;

    /// @notice Registers a proxy as a valid recipient; append-only.
    /// @dev The call reverts with `OnlyAdapter` unless `msg.sender == adapter()`, with `ZeroAddress` if
    /// `proxy == address(0)`, and with `ReservedAddress(proxy)` if `proxy` is one of the token's address bindings or
    /// the token itself, so no Adapter can make the Hub, LPVaultSwap or itself a proxy (which would open a burn from
    /// the Hub, a transfer from LPVaultSwap to the Hub or a seizure to the Adapter). If the proxy is already valid it
    /// returns without a state change or event; otherwise it sets `isValidProxy[proxy]` and emits `ProxyAdded`. No
    /// function removes an entry. The Adapter calls it at a proxy's first pledge into the market.
    /// @param proxy The PositionProxy to register.
    /// @custom:spec REQ-VTOKEN-007, REQ-VTOKEN-039, REQ-VTOKEN-032, REQ-VTOKEN-047, DEP-005, INV-012
    function addValidProxy(
        address proxy
    ) external;

    /// @notice Returns whether `account` is a registered proxy of this market.
    /// @param account Address to check.
    /// @return valid True once `addValidProxy(account)` has run.
    /// @custom:spec REQ-VTOKEN-007, REQ-VTOKEN-040
    function isValidProxy(
        address account
    ) external view returns (bool valid);

    /// @notice Returns whether `account` may hold the token: the set any unit can reach on the allowed paths.
    /// @dev True for `hub()`, `lpVaultSwap()` and every registered proxy; false for the AaveAdapter, the LPVault,
    /// Collateralization, the CDP Spoke, the Hub's reinvestment controller, keepers, wallets and every other address.
    /// @param account Address to check.
    /// @return allowed True if `account` is an allowed holder.
    /// @custom:spec REQ-VTOKEN-006, REQ-VTOKEN-040
    function isAllowedRecipient(
        address account
    ) external view returns (bool allowed);

    /// @notice Returns whether a `transfer` or `transferFrom` from `from` to `to` is on an allowed path.
    /// @dev Returns `(to == hub() && isValidProxy(from)) || (from == hub() && (isValidProxy(to) || to ==
    /// lpVaultSwap()))`: supply, withdrawal and seizure. A transfer between two proxies, from LPVaultSwap to the Hub,
    /// from or to the Adapter, or from the Hub to the Hub returns false. The view ignores the amount: a transfer of 0
    /// on a path for which it returns true still reverts.
    /// @param from The sender.
    /// @param to The recipient.
    /// @return allowed True if the transfer is allowed.
    /// @custom:spec REQ-VTOKEN-006, REQ-VTOKEN-040, REQ-VTOKEN-041
    function isAllowedTransfer(
        address from,
        address to
    ) external view returns (bool allowed);

    /// @notice Returns the market key the token was deployed for (`IVaultTokenFactory.marketKeyOf`).
    /// @return key Constructor immutable.
    /// @custom:spec REQ-VTOKEN-003, REQ-VTOKEN-020
    function marketKey() external view returns (bytes32 key);

    /// @notice Returns the market's AMM integration identifier.
    /// @return id Constructor immutable.
    /// @custom:spec REQ-VTOKEN-003, REQ-AMM-CORE-001
    function integrationId() external view returns (uint32 id);

    /// @notice Returns the market's LPVault, the integration registered for `integrationId()` at deployment.
    /// @return lpVault Constructor immutable.
    /// @custom:spec REQ-VTOKEN-003, REQ-COLL-004
    function integration() external view returns (address lpVault);

    /// @notice Returns the Hub of the market's CDP Spoke (its home Hub), which holds the supplied tokens.
    /// @return hubAddress Constructor immutable.
    /// @custom:spec REQ-VTOKEN-003
    function hub() external view returns (address hubAddress);

    /// @notice Returns the CDP Spoke holding the token's reserve.
    /// @return spokeAddress Constructor immutable.
    /// @custom:spec REQ-VTOKEN-003
    function spoke() external view returns (address spokeAddress);

    /// @notice Returns the market's MarketRegistry `marketId`, non-zero.
    /// @dev Equals the ID the MarketRegistry assigned in the same timelock batch as the deployment; Collateralization
    /// reads it at pledge instead of any upgradeable lookup.
    /// @return id Constructor immutable.
    /// @custom:spec REQ-VTOKEN-003, REQ-VTOKEN-038
    function marketId() external view returns (uint256 id);

    /// @notice Returns the market's LPOracle fixed proxy address (the Aave price source of the reserve).
    /// @return oracle Constructor immutable.
    /// @custom:spec REQ-VTOKEN-003, REQ-VTOKEN-038
    function lpOracle() external view returns (address oracle);

    /// @notice Returns the AaveAdapter fixed proxy address, the only minter, burner and registry writer; never a holder.
    /// @return adapterAddress Constructor immutable.
    /// @custom:spec REQ-VTOKEN-003, REQ-VTOKEN-027
    function adapter() external view returns (address adapterAddress);

    /// @notice Returns the LPVaultSwap fixed proxy address.
    /// @return lpVaultSwapAddress Constructor immutable.
    /// @custom:spec REQ-VTOKEN-003
    function lpVaultSwap() external view returns (address lpVaultSwapAddress);

    /// @notice Returns Collateralization, the backing ledger the token is bound to.
    /// @return collateralizationAddress Constructor immutable.
    /// @custom:spec REQ-VTOKEN-003, REQ-COLL-003
    function collateralization() external view returns (address collateralizationAddress);
}
