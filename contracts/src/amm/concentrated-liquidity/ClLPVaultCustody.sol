// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {ILock} from "../../lock/lock/ILock.sol";
import {IAmmIntegration} from "../IAmmIntegration.sol";
import {IClIntegration} from "../IClIntegration.sol";
import {ClLPVaultBase} from "./ClLPVaultBase.sol";
import {IClPositionManager} from "./IClPositionManager.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ClLPVaultCustody
/// @notice Custody of concentrated-liquidity NFT positions: pledge, return, removal, fees, strays and views.
/// @dev NFTs move only by `transferFrom`, so no receiver hook runs.
// Events report the position manager's return values, so they follow the call; emitters run only under the Lock.
// forge-lint: disable-start(reentrancy-events)
abstract contract ClLPVaultCustody is ClLPVaultBase {
    /// @inheritdoc IAmmIntegration
    /// @dev Custody entry is written before the pull.
    function receivePosition(
        uint256 marketId,
        address owner,
        bytes32 positionKey
    ) external override returns (uint128 units) {
        _onlyCustodyCaller();
        Market storage m = _market(marketId);
        _checkPosition(m, owner, positionKey);
        _depositorOf[positionKey] = owner;
        _marketOfPosition[positionKey] = marketId;
        IClPositionManager manager = _manager(positionKey);
        uint256 tokenId = _tokenId(positionKey);
        manager.transferFrom(owner, address(this), tokenId);
        if (manager.ownerOf(tokenId) != address(this)) revert NotTokenOwner();
        units = _liveUnits(m, positionKey);
        if (units == 0) revert ZeroUnits();
        emit PositionReceived(positionKey, marketId, owner, units);
    }

    /// @inheritdoc IAmmIntegration
    function validatePosition(
        uint256 marketId,
        address owner,
        bytes32 positionKey
    ) external view override returns (uint128 units) {
        Market storage m = _market(marketId);
        _checkPosition(m, owner, positionKey);
        units = _liveUnits(m, positionKey);
        if (units == 0) revert ZeroUnits();
    }

    /// @inheritdoc IAmmIntegration
    function returnPosition(
        bytes32 positionKey
    ) external override returns (address depositor) {
        _onlyCustodyCaller();
        (depositor,) = _custodied(positionKey);
        delete _depositorOf[positionKey];
        delete _marketOfPosition[positionKey];
        emit PositionReturned(positionKey, depositor);
        _manager(positionKey).transferFrom(address(this), depositor, _tokenId(positionKey));
    }

    /// @inheritdoc IAmmIntegration
    function topUpPosition(
        bytes32,
        address,
        bytes calldata
    ) external view override returns (uint128) {
        _onlyCustodyCaller();
        revert TopUpNotSupported();
    }

    /// @inheritdoc IAmmIntegration
    /// @dev Principal to `recipient`; any fee the removal pays out goes to the depositor of record.
    function unwind(
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts,
        address recipient
    ) external override returns (uint256[] memory amounts) {
        _onlyCustodyCaller();
        (address depositor, Market storage m) = _custodied(positionKey);
        _requireReadSafe(m);
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (minAmounts.length != TOKEN_COUNT) revert LengthMismatch(TOKEN_COUNT, minAmounts.length);
        amounts = _removePrincipal(
            m, positionKey, SafeCast.toUint128(_toLiquidity(m, units)), minAmounts, recipient, depositor
        );
        emit UnitsUnwound(positionKey, units, recipient, amounts);
    }

    /// @inheritdoc IAmmIntegration
    function releaseToDepositor(
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts
    ) external override returns (uint256[] memory amounts) {
        _onlyCustodyCaller();
        (address depositor, Market storage m) = _custodied(positionKey);
        _requireReadSafe(m);
        if (minAmounts.length != TOKEN_COUNT) revert LengthMismatch(TOKEN_COUNT, minAmounts.length);
        amounts = _removePrincipal(
            m, positionKey, SafeCast.toUint128(_toLiquidity(m, units)), minAmounts, depositor, depositor
        );
        emit UnitsReleased(positionKey, units, depositor, amounts);
    }

    /// @inheritdoc IAmmIntegration
    /// @dev Collateralization only, while the AaveAdapter (not LPVaultSwap) holds the Lock.
    function collectFees(
        bytes32 positionKey,
        address depositor
    ) external override returns (uint256[] memory amounts) {
        if (msg.sender != _COLLATERALIZATION) revert NotCollateralization();
        ILock lock = ILock(_LOCK);
        if (lock.holder() != lock.AAVE_ADAPTER()) revert LockNotHeld();
        (address recorded, Market storage m) = _custodied(positionKey);
        if (depositor != recorded) revert NotDepositor();
        (uint256 c0, uint256 c1) = _collectAll(m, positionKey, recorded);
        amounts = _pair(c0, c1);
        emit FeesCollected(positionKey, recorded, amounts);
    }

    /// @inheritdoc ILPVault
    /// @dev Stray: the LPVault owns the NFT and has no custody entry for it.
    function returnStray(
        bytes32 positionKey,
        address recipient
    ) external override {
        if (msg.sender != _TIMELOCK) revert NotTimelock();
        if (ILock(_LOCK).isLocked()) revert Locked();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (_depositorOf[positionKey] != address(0) || !_holds(positionKey)) revert NotStray();
        emit StrayReturned(positionKey, recipient);
        _manager(positionKey).transferFrom(address(this), recipient, _tokenId(positionKey));
    }

    /// @inheritdoc IClIntegration
    /// @dev Records nothing: a pushed NFT is a stray, never a record.
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        (bytes32 positionKey, bool known) = _positionKeyOf(msg.sender, tokenId);
        if (!known) revert UnsupportedNft();
        emit StrayReceived(positionKey, from, operator);
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IAmmIntegration
    function positionOwner(
        bytes32 positionKey
    ) external view override returns (address owner) {
        try _manager(positionKey).ownerOf(_tokenId(positionKey)) returns (address o) {
            owner = o;
        } catch {
            owner = address(0);
        }
    }

    /// @inheritdoc IAmmIntegration
    function depositorOf(
        bytes32 positionKey
    ) external view override returns (address) {
        _custodyView();
        return _depositorOf[positionKey];
    }

    /// @inheritdoc IAmmIntegration
    function marketOfPosition(
        bytes32 positionKey
    ) external view override returns (uint256) {
        _custodyView();
        return _marketOfPosition[positionKey];
    }

    /// @inheritdoc ILPVault
    function isInCustody(
        bytes32 positionKey
    ) external view override returns (bool) {
        _custodyView();
        return _depositorOf[positionKey] != address(0);
    }

    /// @inheritdoc IAmmIntegration
    /// @dev Under the Lock the pool lock is checked first, so no read runs inside a pool callback.
    function unitsOf(
        bytes32 positionKey
    ) external view override returns (uint128 units) {
        bool locked = ILock(_LOCK).isLocked();
        if (locked && msg.sender != _COLLATERALIZATION) revert Locked();
        (, Market storage m) = _custodied(positionKey);
        if (locked) _requireReadSafe(m);
        units = _liveUnits(m, positionKey);
    }

    /// @dev The position's live liquidity in vault-token units, floored.
    function _liveUnits(
        Market storage m,
        bytes32 positionKey
    ) internal view returns (uint128) {
        (,,, uint128 liquidity) = _readPosition(positionKey);
        return SafeCast.toUint128(_toUnits(m, liquidity));
    }

    /// @dev Whether the LPVault owns the NFT of a key; false for a token the position manager does not know.
    function _holds(
        bytes32 positionKey
    ) private view returns (bool) {
        try _manager(positionKey).ownerOf(_tokenId(positionKey)) returns (address o) {
            return o == address(this);
        } catch {
            return false;
        }
    }
}
// forge-lint: disable-end(reentrancy-events)
