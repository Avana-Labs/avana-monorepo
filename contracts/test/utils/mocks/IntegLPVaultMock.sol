// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClMarketConfig} from "../../../src/amm/types/ClMarketConfig.sol";
import {IntegrationCapabilities} from "../../../src/amm/types/IntegrationCapabilities.sol";
import {PoolKeying} from "../../../src/amm/types/PoolKeying.sol";
import {RiskStatus} from "../../../src/amm/types/RiskStatus.sol";
import {ILPVaultErrors} from "../../../src/custody/lp-vault/ILPVaultErrors.sol";
import {ILock} from "../../../src/lock/lock/ILock.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title IntegLPVaultMock
/// @notice One AMM integration's LPVault for the integration world, with any number of bound markets, each with its
/// own pool, tokens (2 to 8, any decimals), range, unwind composition and pool depth. It keeps the custody rules
/// Collateralization relies on (`CollLPVaultMock`: Collateralization-only value moves under a Lock member, a position
/// taken only from its owner and returned only to its depositor, principal of exactly the removed units paid to the
/// named recipient, fees only to the depositor) and answers the views the RiskModule and the Lens read
/// (`riskStatus`, `composition`, `clMarket`, `unitsOf`, `depositorOf`, `AMM_PROTOCOL`).
/// @dev Principal per removed unit of market `m` is `rate[m][i] / 1e18` raw units of token `i`, rounded down; the vault
/// holds a float of every token and pays from it. The storage of `CollLPVaultMock` comes first, slot for slot, so a
/// suite can etch this code over an LPVault the VaultTokenFactory already registered.
contract IntegLPVaultMock is ILPVaultErrors {
    uint256 public constant RATE_SCALE = 1e18;

    struct Position {
        address owner;
        address depositor;
        uint256 marketId;
        uint128 units;
        uint256 fees;
    }

    uint32 public immutable INTEGRATION_ID;
    address public immutable COLLATERALIZATION;
    address public immutable LOCK;
    bytes32 public immutable AMM_PROTOCOL;

    // ─── CollLPVaultMock's layout ───
    address public TIMELOCK;
    address public MARKET_REGISTRY;
    mapping(uint256 marketId => address[] tokens) internal _tokens;
    mapping(uint256 marketId => address pool) public poolOf;
    uint256[] internal _unusedRate;
    mapping(bytes32 key => Position) public positions;
    bool public poolLocked;

    // ─── Per market ───
    mapping(uint256 marketId => uint256[] rates) internal _rates;
    mapping(uint256 marketId => int24[2] ticks) internal _ticks;
    mapping(uint256 marketId => uint256 units) internal _depth;
    mapping(uint256 marketId => bool set) internal _depthSet;
    uint256 public depth;
    bool public depthAvailable;

    constructor(
        uint32 integrationId,
        address collateralization,
        address lock,
        bytes32 ammProtocol
    ) {
        INTEGRATION_ID = integrationId;
        COLLATERALIZATION = collateralization;
        LOCK = lock;
        AMM_PROTOCOL = ammProtocol;
    }

    // ─── Test controls ───

    function setCore(
        address timelock,
        address marketRegistry
    ) external {
        (TIMELOCK, MARKET_REGISTRY) = (timelock, marketRegistry);
    }

    /// @notice Binds `marketId` to `pool` on `[tickLower, tickUpper]` with its tokens and unwind rates.
    function bindMarket(
        uint256 marketId,
        address pool,
        address[] calldata tokens,
        uint256[] calldata rates,
        int24 tickLower,
        int24 tickUpper
    ) external {
        poolOf[marketId] = pool;
        _tokens[marketId] = tokens;
        _rates[marketId] = rates;
        _ticks[marketId] = [tickLower, tickUpper];
    }

    /// @notice Pool depth in vault-token units for every market without its own (outside LPs adding or removing).
    function setDepth(
        uint256 units,
        bool available
    ) external {
        (depth, depthAvailable) = (units, available);
    }

    function setMarketDepth(
        uint256 marketId,
        uint256 units
    ) external {
        (_depth[marketId], _depthSet[marketId]) = (units, true);
    }

    function mintPosition(
        bytes32 key,
        address owner,
        uint256 marketId,
        uint128 units
    ) external {
        positions[key] = Position(owner, address(0), marketId, units, 0);
    }

    /// @notice A third party's `increaseLiquidity` on a custodied position.
    function addUnits(
        bytes32 key,
        uint128 units
    ) external {
        positions[key].units += units;
    }

    /// @notice Fees accrue to a position: `amount` raw units of each of its market's tokens.
    function accrueFees(
        bytes32 key,
        uint256 amount
    ) external {
        positions[key].fees += amount;
    }

    function setPoolLocked(
        bool locked
    ) external {
        poolLocked = locked;
    }

    // ─── AMM integration surface ───

    function capabilities() external pure returns (IntegrationCapabilities memory caps) {
        caps.poolKeying = PoolKeying.Address;
        caps.shapeKind = ShapeKind.TickRange;
        caps.hasTwap = true;
    }

    function marketOf(
        uint256 marketId
    ) external view returns (address pool, bytes32 poolId, PositionShape memory shape, address[] memory tokens) {
        tokens = _tokens[marketId];
        if (tokens.length == 0) revert MarketBinding(marketId);
        (pool, poolId) = (poolOf[marketId], bytes32(0));
        shape = PositionShape(ShapeKind.TickRange, _ticks[marketId][0], _ticks[marketId][1]);
    }

    function checkReadSafe(
        uint256
    ) external view {
        if (poolLocked) revert PoolLocked();
    }

    function receivePosition(
        uint256 marketId,
        address owner,
        bytes32 key
    ) external returns (uint128 units) {
        _custodyCaller();
        if (poolLocked) revert PoolLocked();
        Position storage p = positions[key];
        if (owner == address(this) || p.owner != owner) revert NotTokenOwner();
        if (p.marketId != marketId) revert RangeMismatch(-1, 1);
        (p.owner, p.depositor) = (address(this), owner);
        units = p.units;
        if (units == 0) revert ZeroUnits();
    }

    function returnPosition(
        bytes32 key
    ) external returns (address depositor) {
        _custodyCaller();
        Position storage p = positions[key];
        depositor = p.depositor;
        if (depositor == address(0)) revert NotInCustody();
        (p.owner, p.depositor) = (depositor, address(0));
    }

    function topUpPosition(
        bytes32,
        address,
        bytes calldata
    ) external view returns (uint128) {
        _custodyCaller();
        revert TopUpNotSupported();
    }

    function unwind(
        bytes32 key,
        uint128 units,
        uint256[] calldata minAmounts,
        address recipient
    ) external returns (uint256[] memory amounts) {
        _custodyCaller();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        amounts = _remove(key, units, minAmounts, recipient);
    }

    function releaseToDepositor(
        bytes32 key,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts) {
        _custodyCaller();
        amounts = _remove(key, units, minAmounts, positions[key].depositor);
    }

    function collectFees(
        bytes32 key,
        address depositor
    ) external returns (uint256[] memory amounts) {
        _custodyCaller();
        Position storage p = positions[key];
        if (p.depositor == address(0)) revert NotInCustody();
        if (depositor != p.depositor) revert NotDepositor();
        address[] storage tokens = _tokens[p.marketId];
        amounts = new uint256[](tokens.length);
        uint256 fees = p.fees;
        p.fees = 0;
        for (uint256 i = 0; i < tokens.length; ++i) {
            amounts[i] = fees;
            if (fees != 0) ERC20(tokens[i]).transfer(depositor, fees);
        }
    }

    function unitsOf(
        bytes32 key
    ) external view returns (uint128) {
        Position storage p = positions[key];
        if (p.depositor == address(0)) revert NotInCustody();
        return p.units;
    }

    function marketOfPosition(
        bytes32 key
    ) external view returns (uint256) {
        Position storage p = positions[key];
        return p.depositor == address(0) ? 0 : p.marketId;
    }

    function depositorOf(
        bytes32 key
    ) external view returns (address) {
        return positions[key].depositor;
    }

    function ownerOf(
        bytes32 key
    ) external view returns (address) {
        return positions[key].owner;
    }

    // ─── Views of the RiskModule and the Lens ───

    function riskStatus(
        uint256 marketId,
        uint32
    ) external view returns (RiskStatus memory s) {
        (s.depthUnits, s.depthAvailable) = _depthSet[marketId] ? (_depth[marketId], true) : (depth, depthAvailable);
    }

    function composition(
        uint256 marketId,
        uint256 units,
        uint256[] calldata
    ) external view returns (uint256[] memory amounts, bool exact) {
        uint256[] storage r = _rates[marketId];
        amounts = new uint256[](r.length);
        for (uint256 i = 0; i < r.length; ++i) {
            amounts[i] = units * r[i] / RATE_SCALE;
        }
        exact = true;
    }

    function clMarket(
        uint256 marketId
    ) external view returns (ClMarketConfig memory c) {
        address[] storage t = _tokens[marketId];
        (c.pool, c.token0, c.token1) = (poolOf[marketId], t[0], t[1]);
        (c.fee, c.tickSpacing, c.tickLower, c.tickUpper) = (100, 1, _ticks[marketId][0], _ticks[marketId][1]);
    }

    // ─── Internals ───

    function _custodyCaller() internal view {
        if (msg.sender != COLLATERALIZATION) revert NotCollateralization();
        address holder = ILock(LOCK).holder();
        if (holder != ILock(LOCK).AAVE_ADAPTER() && holder != ILock(LOCK).LP_VAULT_SWAP()) revert LockNotHeld();
    }

    function _remove(
        bytes32 key,
        uint128 units,
        uint256[] calldata minAmounts,
        address recipient
    ) internal returns (uint256[] memory amounts) {
        if (poolLocked) revert PoolLocked();
        Position storage p = positions[key];
        if (p.depositor == address(0)) revert NotInCustody();
        p.units -= units;
        address[] storage tokens = _tokens[p.marketId];
        uint256[] storage r = _rates[p.marketId];
        if (minAmounts.length != tokens.length) revert LengthMismatch(tokens.length, minAmounts.length);
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            amounts[i] = uint256(units) * r[i] / RATE_SCALE;
            if (amounts[i] < minAmounts[i]) revert BelowMinimum(i, amounts[i], minAmounts[i]);
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amounts[i] != 0) ERC20(tokens[i]).transfer(recipient, amounts[i]);
        }
    }
}
