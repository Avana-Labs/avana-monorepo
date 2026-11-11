// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IPositionProxy
/// @notice A borrower's Aave V4 account for one market: one immutable, logic-free contract per (wallet, CDP Spoke,
/// market), created with CREATE2 by the chain's ProxyManager on the wallet's first pledge to that market. It holds the
/// account's supplied vault-token collateral of exactly one collateral reserve and the debt of every debt reserve it
/// borrows on its Spoke, so every market has its own Aave account and health factor and no market's collateral backs
/// another market's debt (account isolation). A wallet using two markets has two proxies.
/// @dev Plain contract, not a proxy: no implementation slot, no initializer, no upgrade, no code replacement and no
/// storage. `ADAPTER`, `WALLET`, `SPOKE` and `MARKET_ID` are constructor immutables, so the binding is fixed in the
/// code at creation and is part of the CREATE2 address. The only state-changing function is `execute`, callable only
/// by the chain's AaveAdapter (a UUPS proxy whose address never changes; its logic upgrades through the timelock). All
/// account logic (supply, enable collateral, borrow, repay, withdraw, balance-delta checks, exact approvals reset to
/// 0, collateral cleanup) lives in the Adapter and reaches the Spoke as calls from this proxy
/// (`onBehalfOf = address(this)`). Exits therefore never depend on proxy code: a repay, withdrawal or liquidation runs
/// against the same immutable proxy whatever Adapter version is live, and Aave's `liquidationCall` needs no call into
/// the proxy at all. No `receive`, `fallback`, ERC-721 or ERC-1155 receiver, ERC-1271, `delegatecall`, ETH transfer
/// or sweep. Avana's flows leave no token in the proxy between Adapter calls: every token that reaches it inside an
/// Adapter call leaves it, or is supplied to the Spoke, before the Adapter's entry point returns, and every approval it
/// grants is exact and reset to 0 in the same call. A token anyone sends to the proxy directly stays there for good,
/// since there is no sweep (REQ-PROXY-013), and state placed at the predicted address before deployment (an
/// allowance, an Aave approval, a position) is reachable only through an address collision, which REQ-PROXY-055
/// assumes infeasible and the Adapter's first pledge checks for (an empty Spoke account).
/// @custom:spec REQ-PROXY-001, REQ-PROXY-002, REQ-PROXY-003, REQ-PROXY-004, REQ-PROXY-005, REQ-PROXY-006, REQ-PROXY-007, REQ-PROXY-008, REQ-PROXY-009, REQ-PROXY-010, REQ-PROXY-011, REQ-PROXY-012, REQ-PROXY-013, REQ-PROXY-014, REQ-PROXY-078, INV-012, INV-016, INV-017, Q-223, Q-375
interface IPositionProxy {
    /// @notice `execute` was called by an address other than the AaveAdapter, including the bound wallet.
    /// @custom:spec REQ-PROXY-040, REQ-PROXY-087, REQ-PROXY-088, REQ-PROXY-089, REQ-PROXY-091, Q-375
    error OnlyAdapter();

    /// @notice `execute` named a target that is this proxy, the zero address, the AaveAdapter, the ProxyManager that
    /// created the proxy, or an address without code.
    /// @param target The rejected target.
    /// @custom:spec REQ-PROXY-091, Q-375
    error InvalidTarget(address target);

    /// @notice The call made by `execute` reverted with empty revert data.
    /// @dev A callee that reverts with data has that data propagated unchanged instead.
    /// @param target The callee.
    /// @custom:spec REQ-PROXY-091, Q-375
    error CallFailed(address target);

    /// @notice The constructor got a zero `adapter`, `wallet` or `spoke`, or a zero `marketId`.
    /// @custom:spec REQ-PROXY-003, REQ-PROXY-092
    error ZeroAddress();

    /// @notice Calls `target` with `data` as this proxy, with no ETH.
    /// @dev `OnlyAdapter` unless `msg.sender == ADAPTER`; `InvalidTarget` if `target` is `address(this)`, zero,
    /// `ADAPTER`, the creating ProxyManager or holds no code. Performs `target.call(data)` and returns its return data; a revert propagates with the callee's revert
    /// data (`CallFailed(target)` when that data is empty). No check of the target, selector or arguments beyond these:
    /// the Adapter decides every call and checks every balance delta, so the proxy carries no logic that a later
    /// Adapter version could need to change.
    /// @param target The contract to call: the bound Spoke, the market's vault token or a debt asset.
    /// @param data ABI-encoded call.
    /// @return result The callee's return data.
    /// @custom:spec REQ-PROXY-040, REQ-PROXY-087, REQ-PROXY-088, REQ-PROXY-089, REQ-PROXY-091, Q-375
    function execute(
        address target,
        bytes calldata data
    ) external returns (bytes memory result);

    /// @notice Returns the chain's AaveAdapter, the only caller of `execute`.
    /// @return adapter Constructor immutable.
    /// @custom:spec REQ-PROXY-002, REQ-PROXY-090, Q-375
    function ADAPTER() external view returns (address adapter);

    /// @notice Returns the bound wallet.
    /// @return wallet Constructor immutable, non-zero.
    /// @custom:spec REQ-PROXY-002, REQ-PROXY-004, REQ-PROXY-090
    function WALLET() external view returns (address wallet);

    /// @notice Returns the bound CDP Spoke.
    /// @return spoke Constructor immutable, non-zero.
    /// @custom:spec REQ-PROXY-002, REQ-PROXY-004, REQ-PROXY-090
    function SPOKE() external view returns (address spoke);

    /// @notice Returns the bound market, a MarketRegistry market identifier listed on `SPOKE`.
    /// @return marketId Constructor immutable, non-zero.
    /// @custom:spec REQ-PROXY-002, REQ-PROXY-004, REQ-PROXY-090, Q-375
    function MARKET_ID() external view returns (uint256 marketId);
}
