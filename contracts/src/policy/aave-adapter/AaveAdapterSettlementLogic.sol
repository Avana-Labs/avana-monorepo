// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "../../custody/collateralization/ICollateralizationAdapter.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILock} from "../../lock/lock/ILock.sol";
import {PositionRef} from "../../types/PositionRef.sol";
import {IVaultTokenFactory} from "../../vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {AaveAdapterSteps} from "./AaveAdapterSteps.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {IAaveAdapterLogic} from "./IAaveAdapterLogic.sol";
import {AaveAdapterImmutables} from "./types/AaveAdapterImmutables.sol";
import {AdapterAccount} from "./types/AdapterAccount.sol";

/// @title AaveAdapterSettlementLogic
/// @notice Bodies of the steps LPVaultSwap asks the Adapter to run: `burnSeized` inside a liquidation or a pending
/// settlement, and `deleverageRepay` and `deleverageRelease` inside the Adapter's own repay-with-collateral session.
/// @dev Reached only by `delegatecall` from the AaveAdapter router (`IAaveAdapterLogic`). None takes or releases the
/// Lock (they are inner callees, REQ-LOCK-030) and none reads the MarketRegistry, the pause state, the address freeze, a
/// breaker or the RiskModule (REQ-ADAPTER-047).
/// @custom:spec REQ-ADAPTER-047, REQ-ADAPTER-070, REQ-ADAPTER-081, REQ-ADAPTER-086, REQ-ADAPTER-092, REQ-PROXY-075, REQ-LOCK-023, REQ-LOCK-030
// Each function carries the body of a selector declared in an IAaveAdapter piece that the router implements; this
// contract inherits no piece, since each piece also declares functions another logic contract serves.
// solhint-disable comprehensive-interface
// Every call made here runs under the Lock held by the Adapter or LPVaultSwap, which no callee can take again.
// forge-lint: disable-start(reentrancy-events)
// The router implements IAaveAdapterSettlement; this logic contract carries its bodies only (see above).
// forge-lint: disable-next-line(missing-inheritance)
contract AaveAdapterSettlementLogic is AaveAdapterSteps, IAaveAdapterLogic {
    /// @notice Fixes the implementation immutables; they must equal the router's.
    /// @param im The chain's dependencies.
    /// @custom:spec REQ-ADAPTER-004, REQ-ADAPTER-074
    constructor(
        AaveAdapterImmutables memory im
    ) AaveAdapterStorage(im) {}

    /// @inheritdoc IAaveAdapterLogic
    /// @custom:spec REQ-ADAPTER-004
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("AaveAdapterSettlementLogic"), _IMMUTABLES_HASH);
    }

    /// @notice Body of `burnSeized` (REQ-ADAPTER-070): LPVaultSwap holding the Lock burns seized units from its own
    /// balance; the vault token is checked against the immutable VaultTokenFactory and its own market immutable.
    /// @custom:spec REQ-ADAPTER-070, REQ-ADAPTER-005, REQ-PROXY-075, REQ-LOCK-023
    function burnSeized(
        uint256 marketId,
        address vaultToken,
        uint256 units
    ) external {
        _onlyDelegated();
        if (msg.sender != _LP_VAULT_SWAP || ILock(_LOCK).holder() != _LP_VAULT_SWAP) revert NotLPVaultSwap();
        if (
            !IVaultTokenFactory(_VAULT_TOKEN_FACTORY).isVaultToken(vaultToken)
                || IVaultToken(vaultToken).marketId() != marketId
        ) revert UnknownMarket(marketId);
        if (units == 0) revert ZeroAmount();
        IVaultToken(vaultToken).burn(_LP_VAULT_SWAP, units);
        emit SeizedUnitsBurned(marketId, vaultToken, units);
    }

    /// @notice Body of `deleverageRepay` (REQ-ADAPTER-081): LPVaultSwap's funds repay the session's reserve on the
    /// session's proxy; the unconsumed part returns to LPVaultSwap.
    /// @custom:spec REQ-ADAPTER-081, REQ-ADAPTER-092, REQ-PROXY-088, REQ-LOCK-023
    function deleverageRepay(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external returns (uint256 repaid) {
        _onlyDelegated();
        _onlySwapInSession();
        (address sProxy,,,, uint256 sReserve,, uint256 steps) = _session();
        if (sProxy == address(0) || sProxy != proxy || sReserve != debtReserveId || steps != 0) {
            revert NoDeleverageSession();
        }
        if (amount == 0) revert ZeroAmount();
        address spoke = _s().accountOf[proxy].spoke;
        address asset = IAaveV4Spoke(spoke).getReserve(debtReserveId).underlying;
        _markStep(STEP_REPAID);
        uint256 received = _pull(asset, _LP_VAULT_SWAP, proxy, amount);
        repaid = _repayStep(proxy, spoke, asset, debtReserveId, received, _LP_VAULT_SWAP);
    }

    /// @notice Body of `deleverageRelease` (REQ-ADAPTER-081): after the repay step, withdraws and burns the session's
    /// units and has Collateralization unwind them to LPVaultSwap at the borrower's own per-token minimums.
    /// @custom:spec REQ-ADAPTER-081, REQ-ADAPTER-092, REQ-PROXY-089, REQ-LOCK-023
    function deleverageRelease(
        address proxy,
        PositionRef calldata position,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts, bool closed) {
        _onlyDelegated();
        _onlySwapInSession();
        AdapterAccount memory account = _s().accountOf[proxy];
        _checkReleaseSession(proxy, account.vaultToken, position, units, minAmounts);
        _markStep(STEP_RELEASED);
        _withdrawAndBurn(proxy, account.spoke, account.vaultToken, _reserveIdOf(account.vaultToken), units);
        (amounts, closed) = ICollateralizationAdapter(_COLLATERALIZATION)
            .releaseForDeleverage(proxy, account.vaultToken, position.positionKey, units, minAmounts);
    }

    /// @dev `NotLPVaultSwap` unless LPVaultSwap calls while the Adapter itself holds the Lock (REQ-ADAPTER-081).
    function _onlySwapInSession() private view {
        if (msg.sender != _LP_VAULT_SWAP || ILock(_LOCK).holder() != address(this)) revert NotLPVaultSwap();
    }

    /// @dev `NoDeleverageSession` unless the open session names this proxy, position, units and minimums, its repay
    /// step ran and its release step has not, and the position is the market's integration.
    function _checkReleaseSession(
        address proxy,
        address vaultToken,
        PositionRef calldata position,
        uint128 units,
        uint256[] calldata minAmounts
    ) private view {
        (address sProxy,, bytes32 sKey, uint256 sUnits,, bytes32 sMins, uint256 steps) = _session();
        if (
            sProxy == address(0) || sProxy != proxy || sKey != position.positionKey || sUnits != units
                || sMins != keccak256(abi.encode(minAmounts)) || steps != STEP_REPAID
                || IVaultToken(vaultToken).integrationId() != position.integrationId
        ) revert NoDeleverageSession();
    }
}
// forge-lint: disable-end(reentrancy-events)
