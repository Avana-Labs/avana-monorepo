// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ICollateralization} from "../../legacy/ICollateralization.sol";
import {ILock} from "../../legacy/ILock.sol";
import {PositionRef} from "../../types/PositionTypes.sol";
import {IVaultTokenFactory} from "../../vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {AaveAdapterSteps} from "./AaveAdapterSteps.sol";
import {AaveAdapterStorage} from "./AaveAdapterStorage.sol";
import {IAaveAdapterLogic} from "./IAaveAdapterLogic.sol";
import {AaveAdapterImmutables, AdapterAccount} from "./types/AaveAdapterTypes.sol";

/// @title AaveAdapterSettlementLogic
/// @notice Bodies of the LPVaultSwap steps `burnSeized`, `deleverageRepay` and `deleverageRelease`.
/// @dev None takes the Lock or reads the MarketRegistry.
// The router implements the IAaveAdapter pieces; this contract only carries bodies.
// solhint-disable comprehensive-interface
// Every call here runs under a Lock held by the Adapter or LPVaultSwap.
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-next-line(missing-inheritance)
contract AaveAdapterSettlementLogic is AaveAdapterSteps, IAaveAdapterLogic {
    constructor(
        AaveAdapterImmutables memory im
    ) AaveAdapterStorage(im) {}

    /// @inheritdoc IAaveAdapterLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("AaveAdapterSettlementLogic"), _IMMUTABLES_HASH);
    }

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

    /// @dev Records `hfBefore` first, after LPVaultSwap's oracle pokes, so both health factors use the same prices.
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
        _setHfBefore(IAaveV4Spoke(spoke).getUserAccountData(proxy).healthFactor);
        _markStep(STEP_REPAID);
        uint256 received = _pull(asset, _LP_VAULT_SWAP, proxy, amount);
        repaid = _repayStep(proxy, spoke, asset, debtReserveId, received, _LP_VAULT_SWAP);
    }

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
        (amounts, closed) = ICollateralization(_COLLATERALIZATION)
            .releaseForDeleverage(proxy, account.vaultToken, position.positionKey, units, minAmounts);
    }

    /// @dev `NotLPVaultSwap` unless LPVaultSwap calls while the Adapter itself holds the Lock.
    function _onlySwapInSession() private view {
        if (msg.sender != _LP_VAULT_SWAP || ILock(_LOCK).holder() != address(this)) revert NotLPVaultSwap();
    }

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
