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
/// @notice Custody of concentrated-liquidity NFT positions: pledge, return, exact-unit removal with a principal-capped
/// collect, fee collection for the depositor of record, stray NFTs, and the custody views.
/// @dev Every position-moving function requires `msg.sender == COLLATERALIZATION` and a held Lock; `returnStray` is
/// timelock-only with the Lock free. An NFT moves only by `transferFrom` (no receiver hook runs) and only to its
/// depositor of record or, as a stray, to the timelock's recipient. Every reported amount is a return value of the
/// position manager; no function reads a token balance. The LPVault never approves anyone on the position manager.
/// @custom:spec REQ-VAULT-003, REQ-VAULT-004, REQ-VAULT-093, REQ-VAULT-094, REQ-VAULT-095, REQ-VAULT-097, REQ-VAULT-098, REQ-VAULT-099, REQ-VAULT-154, REQ-AMM-V3-004, SPEC-BACK-008, INV-007, ATTACK-003, ATTACK-006, ATTACK-007, ATTACK-008, ATTACK-015
// The custody events report what the position manager's own call returned (units read after the pull, removed and
// collected amounts), so they follow that call. Every function that emits one runs only for Collateralization inside a
// Lock session; a pool token that re-enters during the payout reaches custody functions that refuse any caller but
// Collateralization and views that refuse while the Lock is held, so no log can be reordered or fabricated.
// forge-lint: disable-start(reentrancy-events)
abstract contract ClLPVaultCustody is ClLPVaultBase {
    /// @inheritdoc IAmmIntegration
    /// @dev Custody entry written before the pull (checks-effects-interactions); the pull is `transferFrom`, so no code
    /// of the owner or of the LPVault runs, and the units are read after custody. A stray the LPVault holds can never
    /// become a record: its owner is the LPVault, which is refused as `owner`.
    /// @custom:spec REQ-AMM-CORE-005, REQ-AMM-CORE-006, REQ-VAULT-147, REQ-VAULT-167, REQ-VAULT-008, REQ-VAULT-009, REQ-VAULT-011, REQ-VAULT-101, REQ-VAULT-173, REQ-AMM-CORE-016, REQ-AMM-V3-009, REQ-AMM-V3-010, INV-005, ATTACK-001, ATTACK-003, ATTACK-007
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
    /// @custom:spec REQ-AMM-CORE-005, REQ-AMM-CORE-006, REQ-RISK-031
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
    /// @dev The entry is deleted before the NFT leaves; the NFT carries all its live liquidity, donated liquidity
    /// included, and every owed fee.
    /// @custom:spec REQ-AMM-CORE-007, REQ-VAULT-148, REQ-VAULT-168, REQ-VAULT-072, REQ-VAULT-094, REQ-VAULT-158, INV-045
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
    /// @dev Anyone can add liquidity to an NFT position with the position manager's `increaseLiquidity`, and a
    /// re-credit credits it, so a concentrated-liquidity LPVault never tops up.
    /// @custom:spec REQ-AMM-CORE-011, REQ-COLL-037
    function topUpPosition(
        bytes32,
        address,
        bytes calldata
    ) external view override returns (uint128) {
        _onlyCustodyCaller();
        revert TopUpNotSupported();
    }

    /// @inheritdoc IAmmIntegration
    /// @dev `decreaseLiquidity` with the given minimums, then `collect` capped at exactly the amounts it returned
    /// (`SPEC-BACK-008`), skipped when both are 0, back to back inside one call under the Lock. Returns the position
    /// manager's amounts; the recipient measures what it received by balance delta.
    /// @custom:spec REQ-AMM-CORE-008, REQ-VAULT-149, REQ-VAULT-169, REQ-VAULT-057, REQ-VAULT-058, REQ-VAULT-067, REQ-VAULT-095, REQ-VAULT-158, REQ-VAULT-159, REQ-VAULT-164, SPEC-BACK-008, ATTACK-015
    function unwind(
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts,
        address recipient
    ) external override returns (uint256[] memory amounts) {
        _onlyCustodyCaller();
        (, Market storage m) = _custodied(positionKey);
        _requireUnlocked(m.cfg.pool);
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        amounts = _removePrincipal(positionKey, SafeCast.toUint128(_toLiquidity(m, units)), minAmounts, recipient);
        emit UnitsUnwound(positionKey, units, recipient, amounts);
    }

    /// @inheritdoc IAmmIntegration
    /// @custom:spec REQ-AMM-CORE-008, REQ-VAULT-161, REQ-VAULT-170, REQ-VAULT-099, REQ-VAULT-163, REQ-AMM-V3-011, SPEC-BACK-008
    function releaseToDepositor(
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts
    ) external override returns (uint256[] memory amounts) {
        _onlyCustodyCaller();
        (address depositor, Market storage m) = _custodied(positionKey);
        _requireUnlocked(m.cfg.pool);
        amounts = _removePrincipal(positionKey, SafeCast.toUint128(_toLiquidity(m, units)), minAmounts, depositor);
        emit UnitsReleased(positionKey, units, depositor, amounts);
    }

    /// @inheritdoc IAmmIntegration
    /// @dev Collateralization only, while the AaveAdapter holds the Lock (`LockNotHeld` for a free Lock or LPVaultSwap
    /// as holder). One `collect` with both caps at `type(uint128).max` to the depositor of record, and nothing else on
    /// the position manager. Reads no pool state: inside a pool callback the pool's own lock makes the collect revert.
    /// @custom:spec REQ-AMM-CORE-010, REQ-VAULT-064, REQ-VAULT-150, REQ-VAULT-065, REQ-VAULT-066, REQ-VAULT-120, REQ-VAULT-126, REQ-VAULT-172, FEE-001, FEE-002, FEE-006, INV-044
    function collectFees(
        bytes32 positionKey,
        address depositor
    ) external override returns (uint256[] memory amounts) {
        if (msg.sender != _COLLATERALIZATION) revert NotCollateralization();
        ILock lock = ILock(_LOCK);
        if (lock.holder() != lock.AAVE_ADAPTER()) revert LockNotHeld();
        (address recorded,) = _custodied(positionKey);
        if (depositor != recorded) revert NotDepositor();
        (uint256 c0, uint256 c1) = _manager(positionKey)
            .collect(
                IClPositionManager.CollectParams({
                    tokenId: _tokenId(positionKey),
                    recipient: recorded,
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        amounts = _pair(c0, c1);
        emit FeesCollected(positionKey, recorded, amounts);
    }

    /// @inheritdoc ILPVault
    /// @dev The stray condition is evaluated here, at execution: the LPVault owns the NFT and has no custody entry.
    /// A token the position manager does not know is not stray.
    /// @custom:spec REQ-VAULT-165, REQ-VAULT-079, REQ-VAULT-080, REQ-VAULT-081, REQ-VAULT-082, REQ-VAULT-083, REQ-VAULT-084, REQ-VAULT-122, REQ-VAULT-123, INV-007, ATTACK-006
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
    /// @dev Records nothing: a pushed NFT is a stray, never a record (`REQ-VAULT-093`).
    /// @custom:spec REQ-VAULT-078, REQ-VAULT-093, REQ-VAULT-124
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

    // ─── Custody views ───

    /// @inheritdoc IAmmIntegration
    /// @custom:spec REQ-AMM-CORE-005, REQ-RISK-031
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
    /// @custom:spec REQ-VAULT-151, REQ-VAULT-152, REQ-VAULT-160, REQ-AMM-CORE-009
    function depositorOf(
        bytes32 positionKey
    ) external view override returns (address) {
        _custodyView();
        return _depositorOf[positionKey];
    }

    /// @inheritdoc IAmmIntegration
    /// @custom:spec REQ-VAULT-151, REQ-VAULT-160, REQ-AMM-CORE-009
    function marketOfPosition(
        bytes32 positionKey
    ) external view override returns (uint256) {
        _custodyView();
        return _marketOfPosition[positionKey];
    }

    /// @inheritdoc ILPVault
    /// @custom:spec REQ-VAULT-151, REQ-VAULT-152, REQ-VAULT-160
    function isInCustody(
        bytes32 positionKey
    ) external view override returns (bool) {
        _custodyView();
        return _depositorOf[positionKey] != address(0);
    }

    /// @inheritdoc IAmmIntegration
    /// @dev Under the Lock (Collateralization's re-credit) the pool lock is checked first, so no liquidity read runs
    /// inside a pool callback.
    /// @custom:spec REQ-AMM-CORE-009, REQ-VAULT-162, REQ-VAULT-171, REQ-VAULT-151, REQ-VAULT-158, REQ-VAULT-160, REQ-AMM-V3-003, REQ-AMM-V3-010
    function unitsOf(
        bytes32 positionKey
    ) external view override returns (uint128 units) {
        bool locked = ILock(_LOCK).isLocked();
        if (locked && msg.sender != _COLLATERALIZATION) revert Locked();
        (, Market storage m) = _custodied(positionKey);
        if (locked) _requireUnlocked(m.cfg.pool);
        units = _liveUnits(m, positionKey);
    }

    // ─── Internal ───

    /// @dev The position's live liquidity in vault-token units, `⌊liquidity / 10^k⌋` (`SPEC-UNIT-002`).
    function _liveUnits(
        Market storage m,
        bytes32 positionKey
    ) private view returns (uint128) {
        (,,, uint128 liquidity) = _readPosition(positionKey);
        return SafeCast.toUint128(_toUnits(m, liquidity));
    }

    /// @dev `SPEC-BACK-008`: removes exactly `liquidity` (the liquidity of the units removed, `units * 10^k`,
    /// `SPEC-UNIT-002`) and collects exactly the principal the removal returned to `recipient`, so every owed fee stays
    /// with the NFT.
    function _removePrincipal(
        bytes32 positionKey,
        uint128 liquidity,
        uint256[] calldata minAmounts,
        address recipient
    ) private returns (uint256[] memory amounts) {
        if (minAmounts.length != TOKEN_COUNT) revert LengthMismatch(TOKEN_COUNT, minAmounts.length);
        IClPositionManager manager = _manager(positionKey);
        uint256 tokenId = _tokenId(positionKey);
        (uint256 a0, uint256 a1) = manager.decreaseLiquidity(
            IClPositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: minAmounts[0],
                amount1Min: minAmounts[1],
                deadline: block.timestamp
            })
        );
        if (a0 < minAmounts[0]) revert BelowMinimum(0, a0, minAmounts[0]);
        if (a1 < minAmounts[1]) revert BelowMinimum(1, a1, minAmounts[1]);
        if (a0 != 0 || a1 != 0) {
            // The collect is capped at exactly (a0, a1), which the position owes after the removal, so it collects
            // exactly them (SPEC-BACK-008); the reported amounts are the removal's.
            // forge-lint: disable-start(unused-return)
            manager.collect(
                IClPositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: recipient,
                    amount0Max: SafeCast.toUint128(a0),
                    amount1Max: SafeCast.toUint128(a1)
                })
            );
            // forge-lint: disable-end(unused-return)
        }
        amounts = _pair(a0, a1);
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
